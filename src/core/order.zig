//! Order Structure - Cache-Line Aligned
//!
//! Design principles (Power of Ten + cache optimization):
//! - Aligned to 64-byte cache line to prevent false sharing
//! - No symbol field - order book is single-symbol, symbol stored in book
//! - Hot fields (accessed during matching) packed together
//! - Uses u64 timestamp for time priority
//! - Tracks remaining_qty separately for partial fills
//!
//! Memory layout (64 bytes total, fits in one cache line):
//!   Bytes 0-3:   user_id
//!   Bytes 4-7:   user_order_id
//!   Bytes 8-11:  price
//!   Bytes 12-15: quantity
//!   Bytes 16-19: remaining_qty
//!   Bytes 20:    side (u8)
//!   Bytes 21:    type (u8)
//!   Bytes 22-23: padding
//!   Bytes 24-27: client_id
//!   Bytes 28-31: padding
//!   Bytes 32-39: timestamp
//!   Bytes 40-47: next pointer
//!   Bytes 48-55: prev pointer
//!   Bytes 56-63: padding

const std = @import("std");
const msg = @import("../protocol/message_types.zig");

// ============================================================================
// Timestamp Implementation
// ============================================================================

/// Get current timestamp for order priority
///
/// Uses RDTSCP on x86-64 for minimal latency (~5-10 cycles).
/// Falls back to clock_gettime on other architectures (~20-50ns).
pub fn getCurrentTimestamp() u64 {
    const arch = @import("builtin").cpu.arch;

    if (arch == .x86_64) {
        return rdtscp();
    } else {
        // Fallback: use standard timestamp
        return @intCast(std.time.nanoTimestamp());
    }
}

/// Read CPU timestamp counter with serialization (x86-64 only)
inline fn rdtscp() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtscp"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .ecx = true }
    );
    return (@as(u64, hi) << 32) | lo;
}

// ============================================================================
// Order Structure
// ============================================================================

/// Order type enum
pub const OrderType = enum(u8) {
    market = 0,
    limit = 1,
};

/// Order structure - exactly 64 bytes (one cache line)
pub const Order = extern struct {
    // === Hot fields - accessed during matching (bytes 0-19) ===
    user_id: u32,
    user_order_id: u32,
    price: u32,
    quantity: u32,
    remaining_qty: u32,

    // === Order metadata (bytes 20-31) ===
    side: msg.Side,
    order_type: OrderType,
    _pad1: [2]u8,
    client_id: u32,
    _pad2: u32,

    // === Time priority (bytes 32-39) ===
    timestamp: u64,

    // === Linked list pointers (bytes 40-55) ===
    next: ?*Order,
    prev: ?*Order,

    // === Explicit padding to cache line (bytes 56-63) ===
    _pad3: [8]u8,

    const Self = @This();

    comptime {
        std.debug.assert(@sizeOf(Order) == 64);
        std.debug.assert(@offsetOf(Order, "user_id") == 0);
        std.debug.assert(@offsetOf(Order, "timestamp") == 32);
        std.debug.assert(@offsetOf(Order, "next") == 40);
        std.debug.assert(@offsetOf(Order, "prev") == 48);
    }

    pub fn init(self: *Self, order_msg: *const msg.NewOrderMsg, timestamp: u64) void {
        std.debug.assert(order_msg.quantity > 0);
        std.debug.assert(order_msg.side == .buy or order_msg.side == .sell);

        self.user_id = order_msg.user_id;
        self.user_order_id = order_msg.user_order_id;
        self.price = order_msg.price;
        self.quantity = order_msg.quantity;
        self.remaining_qty = order_msg.quantity;
        self.side = order_msg.side;
        self.order_type = if (order_msg.price == 0) .market else .limit;
        self._pad1 = .{ 0, 0 };
        self.client_id = 0;
        self._pad2 = 0;
        self.timestamp = timestamp;
        self.next = null;
        self.prev = null;
        self._pad3 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };

        std.debug.assert(self.remaining_qty == self.quantity);
    }

    pub fn isFilled(self: *const Self) bool {
        std.debug.assert(self.remaining_qty <= self.quantity);
        return self.remaining_qty == 0;
    }

    pub fn fill(self: *Self, qty: u32) u32 {
        std.debug.assert(qty > 0);
        std.debug.assert(self.remaining_qty >= qty);

        const filled = @min(qty, self.remaining_qty);
        self.remaining_qty -= filled;
        return filled;
    }

    pub fn getPriority(self: *const Self, is_bid: bool) i64 {
        if (is_bid) {
            return -@as(i64, @intCast(self.price));
        } else {
            return @as(i64, @intCast(self.price));
        }
    }

    pub fn reset(self: *Self) void {
        self.* = std.mem.zeroes(Order);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "order size is exactly 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Order));
}

test "order field offsets match C layout" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Order, "user_id"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Order, "user_order_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Order, "price"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Order, "quantity"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Order, "remaining_qty"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(Order, "side"));
    try std.testing.expectEqual(@as(usize, 21), @offsetOf(Order, "order_type"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Order, "client_id"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Order, "timestamp"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Order, "next"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Order, "prev"));
}

test "order init from new order message" {
    var order: Order = undefined;
    var new_order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 150,
        .quantity = 1000,
        .side = .buy,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&new_order.symbol, "IBM");

    order.init(&new_order, 12345);

    try std.testing.expectEqual(@as(u32, 1), order.user_id);
    try std.testing.expectEqual(@as(u32, 100), order.user_order_id);
    try std.testing.expectEqual(@as(u32, 150), order.price);
    try std.testing.expectEqual(@as(u32, 1000), order.quantity);
    try std.testing.expectEqual(@as(u32, 1000), order.remaining_qty);
    try std.testing.expectEqual(msg.Side.buy, order.side);
    try std.testing.expectEqual(OrderType.limit, order.order_type);
    try std.testing.expectEqual(@as(u64, 12345), order.timestamp);
    try std.testing.expect(!order.isFilled());
}

test "order fill" {
    var order: Order = undefined;
    var new_order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 150,
        .quantity = 1000,
        .side = .buy,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&new_order.symbol, "IBM");

    order.init(&new_order, 12345);

    const filled1 = order.fill(400);
    try std.testing.expectEqual(@as(u32, 400), filled1);
    try std.testing.expectEqual(@as(u32, 600), order.remaining_qty);
    try std.testing.expect(!order.isFilled());

    const filled2 = order.fill(600);
    try std.testing.expectEqual(@as(u32, 600), filled2);
    try std.testing.expectEqual(@as(u32, 0), order.remaining_qty);
    try std.testing.expect(order.isFilled());
}

test "market order has zero price" {
    var order: Order = undefined;
    var new_order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 0,
        .quantity = 1000,
        .side = .sell,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&new_order.symbol, "AAPL");

    order.init(&new_order, 12345);

    try std.testing.expectEqual(OrderType.market, order.order_type);
    try std.testing.expectEqual(@as(u32, 0), order.price);
}

test "timestamp generation" {
    const ts1 = getCurrentTimestamp();
    const ts2 = getCurrentTimestamp();
    try std.testing.expect(ts2 >= ts1);
}
