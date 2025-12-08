//! Pre-allocated memory pools for zero-allocation hot path.
//!
//! Design (Power of Ten Rule 3):
//! - No dynamic allocation after initialization
//! - Fixed-size pools allocated at startup
//! - Free list stack for O(1) acquire/release
//! - All memory usage bounded and predictable
//!
//! Free List Implementation:
//! The free list is a stack of available indices. Acquire pops from top,
//! release pushes to top. This gives O(1) operations with no fragmentation.
//!
//! Initial allocation order: indices are pushed in reverse order during init,
//! so the first acquire() returns index 0, then 1, etc. This provides optimal
//! cache locality during the initial burst of orders.
//!
//! Thread Safety:
//! - This implementation is NOT thread-safe
//! - For multi-threaded use, wrap in mutex or use separate pools per thread
//! - SPSC access pattern (single producer, single consumer) is safe

const std = @import("std");
const Order = @import("order.zig").Order;
const ORDER_ALIGNMENT = @import("order.zig").ORDER_ALIGNMENT;
const CACHE_LINE_SIZE = @import("order.zig").CACHE_LINE_SIZE;

// ============================================================================
// Configuration
// ============================================================================

/// Default pool capacity: 64K orders × 64 bytes = 4 MB
/// Adjustable at runtime via OrderPool.init()
pub const DEFAULT_ORDER_POOL_CAPACITY: u32 = 65536;

/// Type alias for order indices (enables future expansion to u64 if needed)
pub const OrderIndex = u32;

/// Maximum supported pool capacity (16M orders = 1 GB of order storage)
pub const MAX_POOL_CAPACITY: u32 = 16_777_216;

// ============================================================================
// Order Pool
// ============================================================================

/// Pre-allocated pool of orders.
///
/// All orders come from this pool - zero malloc in hot path.
/// Uses a free list stack for O(1) acquire/release.
///
/// Memory layout:
/// ```
///   orders:    [capacity]Order  - The actual order storage (64-byte aligned)
///   free_list: [capacity]u32    - Stack of available indices (64-byte aligned)
///   debug_map: [capacity]bool   - Debug-only: tracks allocated slots
/// ```
///
/// Memory footprint per capacity:
/// - 1K orders:   ~68 KB  (64 + 4 bytes per order)
/// - 64K orders:  ~4.25 MB
/// - 128K orders: ~8.5 MB
/// - 1M orders:   ~68 MB
pub const OrderPool = struct {
    /// Pre-allocated orders (cache-line aligned for optimal access)
    orders: []align(ORDER_ALIGNMENT) Order,

    /// Free list implemented as a stack (cache-line aligned).
    /// free_list[0..free_count] contains indices of available slots.
    /// Acquire pops from top (free_count-1), release pushes to top.
    free_list: []align(CACHE_LINE_SIZE) OrderIndex,

    /// Number of free slots available.
    /// Invariant: 0 <= free_count <= capacity
    free_count: u32,

    /// Pool capacity (immutable after init)
    capacity: u32,

    /// Debug mode: bitmap tracking which slots are currently allocated.
    /// Used for double-free detection. Only allocated in debug builds.
    debug_allocated: ?[]bool,

    // === Statistics ===

    /// Total successful acquisitions since init/reset
    total_allocations: u64 = 0,

    /// Peak concurrent usage (high water mark)
    peak_usage: u32 = 0,

    /// Total failed acquisition attempts (pool exhausted)
    allocation_failures: u64 = 0,

    /// Total releases since init/reset
    total_releases: u64 = 0,

    /// Backing allocator (only used at init/deinit, never in hot path)
    allocator: std.mem.Allocator,

    const Self = @This();

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Initialize pool with given capacity.
    ///
    /// All memory is allocated upfront. After init completes, no further
    /// allocations occur until deinit.
    ///
    /// Memory allocated: capacity × (64 + 4 + 1*) bytes
    ///   * debug bitmap only in debug/safe builds
    ///
    /// Returns error.InvalidCapacity if capacity is 0.
    /// Returns error.CapacityTooLarge if capacity exceeds MAX_POOL_CAPACITY.
    /// Returns error.OutOfMemory if allocation fails.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
        // Validate capacity
        if (capacity == 0) return error.InvalidCapacity;
        if (capacity > MAX_POOL_CAPACITY) return error.CapacityTooLarge;

        // Allocate order storage with cache-line alignment
        const orders = try allocator.alignedAlloc(Order, ORDER_ALIGNMENT, capacity);
        errdefer allocator.free(orders);

        // Allocate free list with cache-line alignment for hot path access
        const free_list = try allocator.alignedAlloc(OrderIndex, CACHE_LINE_SIZE, capacity);
        errdefer allocator.free(free_list);

        // Initialize free list in reverse order so first acquire() returns index 0.
        // This provides optimal cache locality during initial order burst.
        // After init: free_list = [capacity-1, capacity-2, ..., 1, 0]
        // First pop returns 0, second returns 1, etc.
        for (free_list, 0..) |*slot, i| {
            slot.* = @intCast(capacity - 1 - i);
        }

        // Debug mode: allocate tracking bitmap
        const debug_allocated = if (std.debug.runtime_safety) blk: {
            const bitmap = try allocator.alloc(bool, capacity);
            @memset(bitmap, false);
            break :blk bitmap;
        } else null;

        const pool = Self{
            .orders = orders,
            .free_list = free_list,
            .free_count = capacity,
            .capacity = capacity,
            .debug_allocated = debug_allocated,
            .allocator = allocator,
        };

        // Post-condition: pool is valid and full
        std.debug.assert(pool.isValid());
        std.debug.assert(pool.isFull());

        return pool;
    }

    /// Release all pool memory.
    ///
    /// Warning: Any outstanding order pointers become invalid after deinit.
    /// In debug builds, warns if there are unreleased orders (likely leak).
    pub fn deinit(self: *Self) void {
        std.debug.assert(self.isValid());

        // Debug: warn if there are unreleased orders
        if (std.debug.runtime_safety) {
            const in_use = self.getUsage();
            if (in_use > 0) {
                std.log.warn("OrderPool.deinit: {d} orders still in use (potential leak)", .{in_use});
            }
        }

        if (self.debug_allocated) |bitmap| {
            self.allocator.free(bitmap);
        }
        self.allocator.free(self.free_list);
        self.allocator.free(self.orders);

        // Poison the struct to catch use-after-free
        self.* = undefined;
    }

    /// Reset pool to initial state without deallocating memory.
    ///
    /// Returns all orders to the free list. Use this for book flush operations
    /// instead of deinit+init to avoid reallocation.
    ///
    /// Warning: Any outstanding order pointers become invalid after reset.
    /// Caller must ensure no references to pool orders exist.
    ///
    /// Statistics are preserved (not reset) to maintain lifetime metrics.
    pub fn reset(self: *Self) void {
        std.debug.assert(self.isValid());

        // Reinitialize free list (reverse order for sequential allocation)
        for (self.free_list, 0..) |*slot, i| {
            slot.* = @intCast(self.capacity - 1 - i);
        }
        self.free_count = self.capacity;

        // Reset debug bitmap
        if (self.debug_allocated) |bitmap| {
            @memset(bitmap, false);
        }

        // Note: Statistics intentionally NOT reset
        // - total_allocations, total_releases: lifetime counts
        // - peak_usage: lifetime high water mark
        // - allocation_failures: lifetime failure count

        std.debug.assert(self.isFull());
    }

    // ========================================================================
    // Pool Invariants
    // ========================================================================

    /// Check all pool invariants. Used in debug assertions.
    fn isValid(self: *const Self) bool {
        if (self.free_count > self.capacity) return false;
        if (self.orders.len != self.capacity) return false;
        if (self.free_list.len != self.capacity) return false;
        return true;
    }

    // ========================================================================
    // Acquisition and Release (Hot Path)
    // ========================================================================

    /// Acquire an order slot from the pool.
    ///
    /// Returns null if pool is exhausted (all orders in use).
    /// The returned order is uninitialized - caller must set all fields.
    ///
    /// Complexity: O(1)
    /// Allocations: None (hot path safe)
    pub fn acquire(self: *Self) ?*Order {
        std.debug.assert(self.isValid());

        if (self.free_count == 0) {
            self.allocation_failures += 1;
            return null;
        }

        // Pop from free list stack
        self.free_count -= 1;
        const idx = self.free_list[self.free_count];

        // Bounds check (should always pass if pool is valid)
        std.debug.assert(idx < self.capacity);

        // Debug: mark as allocated and check for double-allocation
        if (self.debug_allocated) |bitmap| {
            std.debug.assert(!bitmap[idx]); // Double-allocation = logic error
            bitmap[idx] = true;
        }

        // Update statistics
        self.total_allocations += 1;
        const usage = self.getUsage();
        self.peak_usage = @max(self.peak_usage, usage);

        return &self.orders[idx];
    }

    /// Release an order back to the pool.
    ///
    /// The order must have been acquired from THIS pool.
    /// Double-free is detected and panics in debug builds.
    ///
    /// Complexity: O(1)
    /// Allocations: None (hot path safe)
    pub fn release(self: *Self, order: *Order) void {
        std.debug.assert(self.isValid());

        const idx = self.orderToIndex(order);

        // Debug: verify not already free (double-free detection)
        if (self.debug_allocated) |bitmap| {
            if (!bitmap[idx]) {
                std.debug.panic(
                    "OrderPool.release: double-free detected for index {d}",
                    .{idx},
                );
            }
            bitmap[idx] = false;
        }

        // Verify we're not overflowing the free list
        std.debug.assert(self.free_count < self.capacity);

        // Push to free list stack
        self.free_list[self.free_count] = idx;
        self.free_count += 1;
        self.total_releases += 1;

        // Post-condition
        std.debug.assert(self.free_count <= self.capacity);
    }

    /// Convert order pointer to pool index.
    /// Panics if order is not from this pool.
    fn orderToIndex(self: *const Self, order: *Order) OrderIndex {
        const base = @intFromPtr(self.orders.ptr);
        const ptr = @intFromPtr(order);

        // Verify pointer is within pool bounds
        if (ptr < base) {
            std.debug.panic("OrderPool: order pointer {x} below pool base {x}", .{ ptr, base });
        }

        const byte_offset = ptr - base;

        // Verify alignment (order must be at a valid slot boundary)
        if (byte_offset % @sizeOf(Order) != 0) {
            std.debug.panic("OrderPool: order pointer {x} misaligned", .{ptr});
        }

        const idx: OrderIndex = @intCast(byte_offset / @sizeOf(Order));

        // Verify index is valid
        if (idx >= self.capacity) {
            std.debug.panic("OrderPool: order index {d} >= capacity {d}", .{ idx, self.capacity });
        }

        return idx;
    }

    // ========================================================================
    // Queries
    // ========================================================================

    /// Get number of orders currently in use.
    pub fn getUsage(self: *const Self) u32 {
        std.debug.assert(self.free_count <= self.capacity);
        return self.capacity - self.free_count;
    }

    /// Get number of free slots available.
    pub fn getAvailable(self: *const Self) u32 {
        return self.free_count;
    }

    /// Check if pool has no available slots (all orders in use).
    pub fn isEmpty(self: *const Self) bool {
        return self.free_count == 0;
    }

    /// Check if pool has all slots available (no orders in use).
    pub fn isFull(self: *const Self) bool {
        return self.free_count == self.capacity;
    }

    /// Get utilization as percentage (0-100).
    pub fn getUtilization(self: *const Self) u32 {
        if (self.capacity == 0) return 0;
        return (self.getUsage() * 100) / self.capacity;
    }

    /// Get total memory footprint in bytes.
    pub fn getMemoryFootprint(self: *const Self) usize {
        var total: usize = self.capacity * @sizeOf(Order);
        total += self.capacity * @sizeOf(OrderIndex);
        if (self.debug_allocated != null) {
            total += self.capacity * @sizeOf(bool);
        }
        return total;
    }
};

// ============================================================================
// Memory Pools Container
// ============================================================================

/// Container for all memory pools used by the matching engine.
/// Provides single point of initialization and cleanup.
///
/// Heap-allocated to avoid large stack frames.
pub const MemoryPools = struct {
    order_pool: OrderPool,

    const Self = @This();

    /// Initialize all pools with default capacities.
    /// Returns heap-allocated MemoryPools.
    pub fn init(allocator: std.mem.Allocator) !*Self {
        return initWithCapacity(allocator, DEFAULT_ORDER_POOL_CAPACITY);
    }

    /// Initialize all pools with custom capacities.
    /// Returns heap-allocated MemoryPools.
    pub fn initWithCapacity(allocator: std.mem.Allocator, order_capacity: u32) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .order_pool = try OrderPool.init(allocator, order_capacity),
        };

        return self;
    }

    /// Release all pool memory.
    pub fn deinit(self: *Self) void {
        const allocator = self.order_pool.allocator;
        self.order_pool.deinit();
        allocator.destroy(self);
    }

    /// Reset all pools to initial state without reallocation.
    /// See OrderPool.reset() for details.
    pub fn reset(self: *Self) void {
        self.order_pool.reset();
    }

    /// Get aggregate statistics for all pools.
    pub fn getStats(self: *const Self) MemoryPoolStats {
        return .{
            .order_allocations = self.order_pool.total_allocations,
            .order_releases = self.order_pool.total_releases,
            .order_peak_usage = self.order_pool.peak_usage,
            .order_failures = self.order_pool.allocation_failures,
            .order_current_usage = self.order_pool.getUsage(),
            .order_capacity = self.order_pool.capacity,
            .total_memory_bytes = self.order_pool.getMemoryFootprint(),
        };
    }
};

/// Statistics snapshot for memory pools.
pub const MemoryPoolStats = struct {
    order_allocations: u64,
    order_releases: u64,
    order_peak_usage: u32,
    order_failures: u64,
    order_current_usage: u32,
    order_capacity: u32,
    total_memory_bytes: usize,

    /// Calculate allocation success rate (0.0 to 1.0).
    pub fn getSuccessRate(self: MemoryPoolStats) f64 {
        const total = self.order_allocations + self.order_failures;
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(self.order_allocations)) / @as(f64, @floatFromInt(total));
    }

    /// Check for potential issues.
    pub fn hasWarnings(self: MemoryPoolStats) bool {
        // Warn if peak usage exceeded 90% of capacity
        const threshold = self.order_capacity * 9 / 10;
        return self.order_peak_usage > threshold or self.order_failures > 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OrderPool basic operations" {
    var pool = try OrderPool.init(std.testing.allocator, 100);
    defer pool.deinit();

    try std.testing.expectEqual(@as(u32, 100), pool.capacity);
    try std.testing.expectEqual(@as(u32, 0), pool.getUsage());
    try std.testing.expect(pool.isFull());

    // Acquire some orders
    const o1 = pool.acquire() orelse return error.PoolExhausted;
    const o2 = pool.acquire() orelse return error.PoolExhausted;

    try std.testing.expectEqual(@as(u32, 2), pool.getUsage());
    try std.testing.expectEqual(@as(u32, 98), pool.getAvailable());
    try std.testing.expect(!pool.isEmpty());
    try std.testing.expect(!pool.isFull());

    // Release one
    pool.release(o1);
    try std.testing.expectEqual(@as(u32, 1), pool.getUsage());

    // Acquire again - should succeed
    const o3 = pool.acquire() orelse return error.PoolExhausted;
    try std.testing.expectEqual(@as(u32, 2), pool.getUsage());

    // Cleanup
    pool.release(o2);
    pool.release(o3);
    try std.testing.expectEqual(@as(u32, 0), pool.getUsage());
    try std.testing.expect(pool.isFull());
}

test "OrderPool sequential allocation" {
    // Verify first allocations come from sequential indices (cache friendly)
    var pool = try OrderPool.init(std.testing.allocator, 100);
    defer pool.deinit();

    const o0 = pool.acquire() orelse return error.PoolExhausted;
    const o1 = pool.acquire() orelse return error.PoolExhausted;
    const o2 = pool.acquire() orelse return error.PoolExhausted;

    // First three orders should be at indices 0, 1, 2 (sequential)
    const base = @intFromPtr(pool.orders.ptr);
    const idx0 = (@intFromPtr(o0) - base) / @sizeOf(Order);
    const idx1 = (@intFromPtr(o1) - base) / @sizeOf(Order);
    const idx2 = (@intFromPtr(o2) - base) / @sizeOf(Order);

    try std.testing.expectEqual(@as(usize, 0), idx0);
    try std.testing.expectEqual(@as(usize, 1), idx1);
    try std.testing.expectEqual(@as(usize, 2), idx2);

    pool.release(o0);
    pool.release(o1);
    pool.release(o2);
}

test "OrderPool exhaustion" {
    var pool = try OrderPool.init(std.testing.allocator, 3);
    defer pool.deinit();

    const o1 = pool.acquire();
    const o2 = pool.acquire();
    const o3 = pool.acquire();

    try std.testing.expect(o1 != null);
    try std.testing.expect(o2 != null);
    try std.testing.expect(o3 != null);
    try std.testing.expect(pool.isEmpty());

    // Fourth should fail
    try std.testing.expect(pool.acquire() == null);
    try std.testing.expectEqual(@as(u64, 1), pool.allocation_failures);

    // Release one and try again
    pool.release(o1.?);
    const o4 = pool.acquire();
    try std.testing.expect(o4 != null);

    // Cleanup
    pool.release(o2.?);
    pool.release(o3.?);
    pool.release(o4.?);
}

test "OrderPool reset" {
    var pool = try OrderPool.init(std.testing.allocator, 10);
    defer pool.deinit();

    // Acquire some orders
    var orders: [5]*Order = undefined;
    for (&orders) |*slot| {
        slot.* = pool.acquire() orelse return error.PoolExhausted;
    }

    try std.testing.expectEqual(@as(u32, 5), pool.getUsage());
    try std.testing.expectEqual(@as(u64, 5), pool.total_allocations);

    // Reset pool
    pool.reset();

    // All slots should be available
    try std.testing.expect(pool.isFull());
    try std.testing.expectEqual(@as(u32, 0), pool.getUsage());

    // Statistics should be preserved
    try std.testing.expectEqual(@as(u64, 5), pool.total_allocations);

    // Should be able to acquire again, starting from index 0
    const new_o0 = pool.acquire() orelse return error.PoolExhausted;
    const base = @intFromPtr(pool.orders.ptr);
    const idx = (@intFromPtr(new_o0) - base) / @sizeOf(Order);
    try std.testing.expectEqual(@as(usize, 0), idx);

    pool.release(new_o0);
}

test "OrderPool statistics" {
    var pool = try OrderPool.init(std.testing.allocator, 10);
    defer pool.deinit();

    // Acquire 5 orders
    var orders: [5]*Order = undefined;
    for (&orders) |*slot| {
        slot.* = pool.acquire() orelse return error.PoolExhausted;
    }

    try std.testing.expectEqual(@as(u64, 5), pool.total_allocations);
    try std.testing.expectEqual(@as(u32, 5), pool.peak_usage);

    // Release 3
    for (orders[0..3]) |o| {
        pool.release(o);
    }

    try std.testing.expectEqual(@as(u64, 3), pool.total_releases);
    try std.testing.expectEqual(@as(u32, 5), pool.peak_usage); // Peak unchanged

    // Acquire 4 more (total in use: 2 + 4 = 6)
    for (0..4) |_| {
        _ = pool.acquire();
    }

    try std.testing.expectEqual(@as(u32, 6), pool.peak_usage); // New peak

    // Cleanup remaining
    pool.release(orders[3]);
    pool.release(orders[4]);
}

test "OrderPool utilization" {
    var pool = try OrderPool.init(std.testing.allocator, 100);
    defer pool.deinit();

    try std.testing.expectEqual(@as(u32, 0), pool.getUtilization());

    var orders: [50]*Order = undefined;
    for (&orders) |*slot| {
        slot.* = pool.acquire() orelse return error.PoolExhausted;
    }

    try std.testing.expectEqual(@as(u32, 50), pool.getUtilization());

    for (&orders) |o| {
        pool.release(o);
    }
}

test "OrderPool memory footprint" {
    var pool = try OrderPool.init(std.testing.allocator, 1000);
    defer pool.deinit();

    const footprint = pool.getMemoryFootprint();

    // At minimum: 1000 orders × 64 bytes + 1000 indices × 4 bytes = 68,000 bytes
    try std.testing.expect(footprint >= 68_000);

    // Debug bitmap adds 1000 bytes in debug mode
    if (std.debug.runtime_safety) {
        try std.testing.expect(footprint >= 69_000);
    }
}

test "MemoryPools container" {
    const pools = try MemoryPools.init(std.testing.allocator);
    defer pools.deinit();

    const stats = pools.getStats();
    try std.testing.expectEqual(@as(u32, DEFAULT_ORDER_POOL_CAPACITY), stats.order_capacity);
    try std.testing.expectEqual(@as(u32, 0), stats.order_current_usage);
    try std.testing.expect(!stats.hasWarnings());
}

test "MemoryPools custom capacity" {
    const pools = try MemoryPools.initWithCapacity(std.testing.allocator, 500);
    defer pools.deinit();

    const stats = pools.getStats();
    try std.testing.expectEqual(@as(u32, 500), stats.order_capacity);
}

test "MemoryPools reset" {
    const pools = try MemoryPools.initWithCapacity(std.testing.allocator, 100);
    defer pools.deinit();

    // Use some orders
    _ = pools.order_pool.acquire();
    _ = pools.order_pool.acquire();
    try std.testing.expectEqual(@as(u32, 2), pools.order_pool.getUsage());

    // Reset
    pools.reset();
    try std.testing.expectEqual(@as(u32, 0), pools.order_pool.getUsage());
    try std.testing.expect(pools.order_pool.isFull());
}

test "Invalid pool capacity" {
    // Zero capacity should fail
    try std.testing.expectError(error.InvalidCapacity, OrderPool.init(std.testing.allocator, 0));

    // Excessive capacity should fail
    try std.testing.expectError(error.CapacityTooLarge, OrderPool.init(std.testing.allocator, MAX_POOL_CAPACITY + 1));
}

test "MemoryPoolStats success rate" {
    var pool = try OrderPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    // Acquire all
    const o1 = pool.acquire();
    const o2 = pool.acquire();
    _ = pool.acquire(); // Fails

    try std.testing.expectEqual(@as(u64, 2), pool.total_allocations);
    try std.testing.expectEqual(@as(u64, 1), pool.allocation_failures);

    const stats = MemoryPoolStats{
        .order_allocations = pool.total_allocations,
        .order_releases = pool.total_releases,
        .order_peak_usage = pool.peak_usage,
        .order_failures = pool.allocation_failures,
        .order_current_usage = pool.getUsage(),
        .order_capacity = pool.capacity,
        .total_memory_bytes = pool.getMemoryFootprint(),
    };

    // Success rate: 2/3 ≈ 0.666
    const rate = stats.getSuccessRate();
    try std.testing.expect(rate > 0.6 and rate < 0.7);

    // Should have warnings due to failure
    try std.testing.expect(stats.hasWarnings());

    pool.release(o1.?);
    pool.release(o2.?);
}
