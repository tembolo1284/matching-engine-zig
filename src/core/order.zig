//! Order structure - 64-byte cache-line aligned.
//! 
//! Design decisions (from Power of Ten + HFT principles):
//! - Aligned to 64-byte cache line to prevent false sharing
//! - No symbol field - order book is single-symbol
//! - Hot fields (accessed during matching) packed first
//! - Uses RDTSC timestamp for time priority on x86_64

const std = @import("std");
const msg = @import("../protocol/message_types.zig");

// ============================================================================
// Timestamp Implementation
// ============================================================================

/// Get current timestamp using RDTSC on x86_64, fallback elsewhere.
/// For strict ordering, RDTSC is sufficient - we only need monotonicity.
pub inline fn getCurrentTimestamp() u64 {
    const builtin = @import("builtin");
    
    if (comptime builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux) {
        // RDTSC: ~5-10 cycles, no syscall overhead
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        asm volatile ("rdtsc"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
        );
        return (@as(u64, hi) << 32) | lo;
    } else {
        // Fallback: clock_gettime equivalent
        return @intCast(@as(u128, @bitCast(std.time.Instant.now().timestamp)));
    }
}

// ============================================================================
// Order Structure
// ============================================================================

/// Order structure - exactly 64 bytes (one cache line).
///
/// Memory layout:
///   Bytes 0-19:  Hot path fields (accessed during matching)
///   Bytes 20-31: Metadata
///   Bytes 32-39: Timestamp
///   Bytes 40-55: Linked list pointers
///   Bytes 56-63: Padding
pub const Order = extern struct {
    // === HOT PATH FIELDS === (bytes 0-19)
    user_id: u32,           // 0-3
    user_order_id: u32,     // 4-7
    price: u32,             // 8-11: 0 = market order
    quantity: u32,          // 12-15: Original quantity
    remaining_qty: u32,     // 16-19: Remaining unfilled

    // === METADATA === (bytes 20-31)
    side: msg.Side,         // 20
    order_type: msg.OrderType, // 21
    _pad1: [2]u8 = undefined, // 22-23
    client_id: u32,         // 24-27: 0 for UDP, >0 for TCP
    _pad2: u32 = undefined, // 28-31: Align timestamp

    // === TIME PRIORITY === (bytes 32-39)
    timestamp: u64,         // 32-39

    // === LINKED LIST POINTERS === (bytes 40-55)
    next: ?*Order,          // 40-47
    prev: ?*Order,          // 48-55

    // === PADDING === (bytes 56-63)
    _padding: [8]u8 = undefined,

    const Self = @This();

    // Compile-time verification
    comptime {
        std.debug.assert(@sizeOf(Self) == 64);
        // Verify field offsets match C layout
        std.debug.assert(@offsetOf(Self, "user_id") == 0);
        std.debug.assert(@offsetOf(Self, "price") == 8);
        std.debug.assert(@offsetOf(Self, "remaining_qty") == 16);
        std.debug.assert(@offsetOf(Self, "side") == 20);
        std.debug.assert(@offsetOf(Self, "timestamp") == 32);
        std.debug.assert(@offsetOf(Self, "next") == 40);
        std.debug.assert(@offsetOf(Self, "prev") == 48);
    }

    /// Initialize order from new order message
    pub fn init(order_msg: *const msg.NewOrderMsg, ts: u64) Self {
        std.debug.assert(order_msg.quantity > 0);
        
        return .{
            .user_id = order_msg.user_id,
            .user_order_id = order_msg.user_order_id,
            .price = order_msg.price,
            .quantity = order_msg.quantity,
            .remaining_qty = order_msg.quantity,
            .side = order_msg.side,
            .order_type = if (order_msg.price == 0) .market else .limit,
            .client_id = 0,
            .timestamp = ts,
            .next = null,
            .prev = null,
        };
    }

    /// Check if order is fully filled
    pub inline fn isFilled(self: *const Self) bool {
        return self.remaining_qty == 0;
    }

    /// Fill order by quantity, returns amount actually filled
    pub inline fn fill(self: *Self, qty: u32) u32 {
        std.debug.assert(qty > 0);
        std.debug.assert(self.remaining_qty >= qty);
        
        const filled = @min(qty, self.remaining_qty);
        self.remaining_qty -= filled;
        return filled;
    }

    /// Get order priority for comparison (price-time priority).
    /// Lower value = higher priority.
    /// For bids: higher price is better (negate).
    /// For asks: lower price is better.
    pub inline fn getPriority(self: *const Self, is_bid: bool) i64 {
        if (is_bid) {
            // Bids: higher price = higher priority (negate for min-ordering)
            return -@as(i64, @intCast(self.price));
        } else {
            // Asks: lower price = higher priority
            return @as(i64, @intCast(self.price));
        }
    }

    /// Check if this order's price crosses the given price.
    /// For buys: our price >= their price means we're willing to pay enough.
    /// For sells: our price <= their price means we're willing to sell low enough.
    pub inline fn pricesCross(self: *const Self, resting_price: u32) bool {
        return switch (self.side) {
            .buy => self.price >= resting_price or self.price == 0, // Market orders cross any price
            .sell => self.price <= resting_price or self.price == 0,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Order size and alignment" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Order));
}

test "Order init and fill" {
    const new_order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 100,
        .side = .buy,
        .symbol = msg.makeSymbol("IBM"),
    };
    
    var order = Order.init(&new_order, 12345);
    
    try std.testing.expectEqual(@as(u32, 1), order.user_id);
    try std.testing.expectEqual(@as(u32, 100), order.remaining_qty);
    try std.testing.expect(!order.isFilled());
    
    const filled = order.fill(30);
    try std.testing.expectEqual(@as(u32, 30), filled);
    try std.testing.expectEqual(@as(u32, 70), order.remaining_qty);
    
    _ = order.fill(70);
    try std.testing.expect(order.isFilled());
}
