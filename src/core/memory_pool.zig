//! Pre-allocated memory pools for zero-allocation hot path.
//!
//! Design (Power of Ten Rule 3):
//! - No dynamic allocation after initialization
//! - Fixed-size pools allocated at startup
//! - Free list for O(1) acquire/release
//! - All memory usage bounded and predictable
//!
//! Thread Safety:
//! - This implementation is NOT thread-safe
//! - For multi-threaded use, wrap in mutex or use separate pools per thread
//! - SPSC access pattern (single producer, single consumer) is safe
const std = @import("std");
const Order = @import("order.zig").Order;
const ORDER_ALIGNMENT = @import("order.zig").ORDER_ALIGNMENT;
// ============================================================================
// Configuration
// ============================================================================
/// Default pool capacity: 128K orders × 64 bytes = 8 MB
/// Adjustable at runtime via OrderPool.init()
pub const DEFAULT_ORDER_POOL_CAPACITY: u32 = 65536;
/// Type alias for order indices (enables future expansion to u64 if needed)
pub const OrderIndex = u32;
/// Maximum supported pool capacity
pub const MAX_POOL_CAPACITY: u32 = 16_777_216; // 16M orders = 1 GB
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
///   orders:    [capacity]Order  - The actual order storage (cache-aligned)
///   free_list: [capacity]u32    - Stack of available indices
///   debug_map: [capacity]bool   - Debug-only: tracks allocated slots
/// ```
pub const OrderPool = struct {
    /// Pre-allocated orders (cache-line aligned)
    orders: []align(ORDER_ALIGNMENT) Order,
    /// Free list implemented as a stack.
    /// free_list[0..free_count] contains indices of available slots.
    /// Acquire pops from top, release pushes to top.
    free_list: []OrderIndex,
    /// Number of free slots available.
    /// Invariant: 0 <= free_count <= capacity
    free_count: u32,
    /// Pool capacity (immutable after init)
    capacity: u32,
    /// Debug mode: bitmap tracking which slots are currently allocated.
    /// Used for double-free detection. Only allocated in debug builds.
    debug_allocated: ?[]bool,
    // === Statistics ===
    /// Total successful acquisitions since init
    total_allocations: u64 = 0,
    /// Peak concurrent usage (high water mark)
    peak_usage: u32 = 0,
    /// Total failed acquisition attempts (pool exhausted)
    allocation_failures: u64 = 0,
    /// Total releases
    total_releases: u64 = 0,
    /// Backing allocator (only used at init/deinit)
    allocator: std.mem.Allocator,
    const Self = @This();
    // ========================================================================
    // Lifecycle
    // ========================================================================
    /// Initialize pool with given capacity.
    ///
    /// Memory allocated: capacity × (64 + 4 + 1*) bytes
    ///   * debug bitmap only in debug builds
    ///
    /// Example: 128K orders ≈ 8.5 MB total
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
        // Validate capacity
        if (capacity == 0) return error.InvalidCapacity;
        if (capacity > MAX_POOL_CAPACITY) return error.CapacityTooLarge;
        // Allocate order storage with cache-line alignment
        const orders = try allocator.alignedAlloc(Order, ORDER_ALIGNMENT, capacity);
        errdefer allocator.free(orders);
        // Allocate free list
        const free_list = try allocator.alloc(OrderIndex, capacity);
        errdefer allocator.free(free_list);
        // Initialize free list with all indices (0 to capacity-1)
        for (free_list, 0..) |*slot, i| {
            slot.* = @intCast(i);
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
        // Post-condition: pool is valid
        std.debug.assert(pool.isValid());
        return pool;
    }
    /// Release all pool memory.
    /// After deinit, the pool is in an undefined state.
    pub fn deinit(self: *Self) void {
        std.debug.assert(self.isValid());
        // Debug: warn if there are unreleased orders
        if (std.debug.runtime_safety) {
            const in_use = self.getUsage();
            if (in_use > 0) {
                std.log.warn("OrderPool.deinit: {} orders still in use (leak)", .{in_use});
            }
        }
        if (self.debug_allocated) |bitmap| {
            self.allocator.free(bitmap);
        }
        self.allocator.free(self.free_list);
        self.allocator.free(self.orders);
        self.* = undefined;
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
    // Acquisition and Release
    // ========================================================================
    /// Acquire an order slot from the pool.
    ///
    /// Returns null if pool is exhausted.
    /// The returned order is uninitialized - caller must set all fields.
    ///
    /// Complexity: O(1)
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
        // Debug: mark as allocated
        if (self.debug_allocated) |bitmap| {
            // Double-allocation detection (should never happen with valid pool)
            std.debug.assert(!bitmap[idx]);
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
    /// Double-free is detected in debug builds.
    ///
    /// Complexity: O(1)
    pub fn release(self: *Self, order: *Order) void {
        std.debug.assert(self.isValid());
        const idx = self.orderToIndex(order);
        // Debug: verify not already free (double-free detection)
        if (self.debug_allocated) |bitmap| {
            if (!bitmap[idx]) {
                std.debug.panic(
                    "OrderPool.release: double-free detected for index {}",
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
        std.debug.assert(ptr >= base);
        const byte_offset = ptr - base;
        // Verify alignment
        std.debug.assert(byte_offset % @sizeOf(Order) == 0);
        const idx: OrderIndex = @intCast(byte_offset / @sizeOf(Order));
        // Verify index is valid
        std.debug.assert(idx < self.capacity);
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
    /// Check if pool has no available slots.
    pub fn isEmpty(self: *const Self) bool {
        return self.free_count == 0;
    }
    /// Check if pool has all slots available.
    pub fn isFull(self: *const Self) bool {
        return self.free_count == self.capacity;
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
pub const MemoryPools = struct {
    order_pool: OrderPool,
    const Self = @This();
    /// Initialize all pools with default capacities (heap-allocated).
    pub fn init(allocator: std.mem.Allocator) !*Self {
        return initWithCapacity(allocator, DEFAULT_ORDER_POOL_CAPACITY);
    }
    /// Initialize all pools with custom capacities (heap-allocated).
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
test "Invalid pool capacity" {
    // Zero capacity should fail
    try std.testing.expectError(error.InvalidCapacity, OrderPool.init(std.testing.allocator, 0));
    // Excessive capacity should fail
    try std.testing.expectError(error.CapacityTooLarge, OrderPool.init(std.testing.allocator, MAX_POOL_CAPACITY + 1));
}
