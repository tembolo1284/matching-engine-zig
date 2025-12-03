//! Pre-allocated memory pools for zero-allocation hot path.
//!
//! Design (Power of Ten Rule 3):
//! - No dynamic allocation after initialization
//! - Fixed-size pools allocated at startup
//! - Free list for O(1) acquire/release

const std = @import("std");
const Order = @import("order.zig").Order;

// ============================================================================
// Configuration
// ============================================================================

pub const MAX_ORDERS_IN_POOL = 131072; // 128K orders

// ============================================================================
// Order Pool
// ============================================================================

/// Pre-allocated pool of orders.
/// All orders come from this pool - zero malloc in hot path.
pub const OrderPool = struct {
    /// Pre-allocated orders (cache-line aligned)
    orders: []align(64) Order,
    
    /// Free list indices
    free_list: []u32,
    
    /// Current free count (negative-safe for atomic ops)
    free_count: i32,
    
    /// Statistics
    total_allocations: u32 = 0,
    peak_usage: u32 = 0,
    allocation_failures: u32 = 0,
    
    /// Backing allocator (only used at init/deinit)
    allocator: std.mem.Allocator,
    
    /// Capacity
    capacity: u32,

    const Self = @This();

    /// Initialize pool with given capacity
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
        const orders = try allocator.alignedAlloc(Order, 64, capacity);
        const free_list = try allocator.alloc(u32, capacity);
        
        // Initialize free list with all indices
        for (free_list, 0..) |*slot, i| {
            slot.* = @intCast(i);
        }
        
        return .{
            .orders = orders,
            .free_list = free_list,
            .free_count = @intCast(capacity),
            .allocator = allocator,
            .capacity = capacity,
        };
    }

    /// Release pool memory
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.orders);
        self.allocator.free(self.free_list);
        self.* = undefined;
    }

    /// Acquire an order from the pool
    pub fn acquire(self: *Self) ?*Order {
        if (self.free_count <= 0) {
            self.allocation_failures += 1;
            return null;
        }
        
        self.free_count -= 1;
        const idx = self.free_list[@intCast(self.free_count)];
        self.total_allocations += 1;
        
        // Track peak usage
        const usage = self.capacity - @as(u32, @intCast(self.free_count));
        self.peak_usage = @max(self.peak_usage, usage);
        
        return &self.orders[idx];
    }

    /// Release an order back to the pool
    pub fn release(self: *Self, order: *Order) void {
        const base = @intFromPtr(self.orders.ptr);
        const ptr = @intFromPtr(order);
        
        std.debug.assert(ptr >= base);
        const offset = ptr - base;
        const idx: u32 = @intCast(offset / @sizeOf(Order));
        std.debug.assert(idx < self.capacity);
        
        self.free_list[@intCast(self.free_count)] = idx;
        self.free_count += 1;
    }

    /// Get current usage count
    pub fn getUsage(self: *const Self) u32 {
        return self.capacity - @as(u32, @intCast(@max(0, self.free_count)));
    }

    /// Check if pool is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.free_count <= 0;
    }
};

// ============================================================================
// Memory Pools Container
// ============================================================================

/// Container for all memory pools
pub const MemoryPools = struct {
    order_pool: OrderPool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .order_pool = try OrderPool.init(allocator, MAX_ORDERS_IN_POOL),
        };
    }

    pub fn deinit(self: *Self) void {
        self.order_pool.deinit();
    }
};

/// Statistics for memory pools
pub const MemoryPoolStats = struct {
    order_allocations: u32,
    order_peak_usage: u32,
    order_failures: u32,
    order_current_usage: u32,
    total_memory_bytes: usize,
};

pub fn getPoolStats(pools: *const MemoryPools) MemoryPoolStats {
    return .{
        .order_allocations = pools.order_pool.total_allocations,
        .order_peak_usage = pools.order_pool.peak_usage,
        .order_failures = pools.order_pool.allocation_failures,
        .order_current_usage = pools.order_pool.getUsage(),
        .total_memory_bytes = pools.order_pool.capacity * @sizeOf(Order),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "OrderPool basic operations" {
    var pool = try OrderPool.init(std.testing.allocator, 100);
    defer pool.deinit();
    
    // Acquire some orders
    const o1 = pool.acquire() orelse return error.PoolExhausted;
    const o2 = pool.acquire() orelse return error.PoolExhausted;
    
    try std.testing.expectEqual(@as(u32, 2), pool.getUsage());
    
    // Release one
    pool.release(o1);
    try std.testing.expectEqual(@as(u32, 1), pool.getUsage());
    
    // Acquire again (should get same slot)
    const o3 = pool.acquire() orelse return error.PoolExhausted;
    _ = o3;
    try std.testing.expectEqual(@as(u32, 2), pool.getUsage());
    
    pool.release(o2);
}

test "OrderPool exhaustion" {
    var pool = try OrderPool.init(std.testing.allocator, 2);
    defer pool.deinit();
    
    _ = pool.acquire();
    _ = pool.acquire();
    
    // Third should fail
    try std.testing.expect(pool.acquire() == null);
    try std.testing.expectEqual(@as(u32, 1), pool.allocation_failures);
}
