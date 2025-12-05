//! Message type definitions for the matching engine protocol.
//!
//! This module defines the canonical message types used throughout the system:
//! - Input messages: Orders, cancels, flushes from clients
//! - Output messages: Acks, trades, rejects to clients
//!
//! Wire format compatibility:
//! - Binary codec uses these types directly
//! - CSV codec parses to/from these types
//! - FIX codec maps FIX tags to these types
//!
//! Design principles:
//! - Fixed-size types for predictable memory layout
//! - No heap allocation
//! - Cache-friendly field ordering
//! - Explicit padding where needed

const std = @import("std");

// ============================================================================
// Symbol Type
// ============================================================================

/// Maximum symbol length (e.g., "AAPL", "MSFT").
pub const MAX_SYMBOL_LENGTH: usize = 8;

/// Fixed-size symbol type, null-padded.
pub const Symbol = [MAX_SYMBOL_LENGTH]u8;

/// Empty symbol constant.
pub const EMPTY_SYMBOL: Symbol = [_]u8{0} ** MAX_SYMBOL_LENGTH;

/// Create symbol from string slice.
/// Truncates if longer than MAX_SYMBOL_LENGTH.
pub fn makeSymbol(str: []const u8) Symbol {
    var sym: Symbol = EMPTY_SYMBOL;
    const len = @min(str.len, MAX_SYMBOL_LENGTH);
    @memcpy(sym[0..len], str[0..len]);
    return sym;
}

/// Check if two symbols are equal.
pub fn symbolEqual(a: *const Symbol, b: *const Symbol) bool {
    return std.mem.eql(u8, a, b);
}

/// Get symbol as slice (up to first null or full length).
pub fn symbolSlice(sym: *const Symbol) []const u8 {
    for (sym, 0..) |c, i| {
        if (c == 0) return sym[0..i];
    }
    return sym[0..MAX_SYMBOL_LENGTH];
}

/// Check if symbol is empty (first byte is null).
pub fn symbolIsEmpty(sym: *const Symbol) bool {
    return sym[0] == 0;
}

/// Hash symbol for use in hash maps.
pub fn symbolHash(sym: *const Symbol) u64 {
    // FNV-1a hash
    var hash: u64 = 0xcbf29ce484222325;
    for (sym) |byte| {
        if (byte == 0) break;
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

/// Compare symbols for ordering (lexicographic).
pub fn symbolCompare(a: *const Symbol, b: *const Symbol) std.math.Order {
    return std.mem.order(u8, a, b);
}

// ============================================================================
// Enums
// ============================================================================

/// Order side (buy or sell).
pub const Side = enum(u8) {
    buy = 'B',
    sell = 'S',

    /// Get opposite side.
    pub fn opposite(self: Side) Side {
        return switch (self) {
            .buy => .sell,
            .sell => .buy,
        };
    }

    /// Check if this side would cross with the other at given prices.
    /// Buy crosses if buy_price >= sell_price.
    /// Sell crosses if sell_price <= buy_price.
    pub fn wouldCross(self: Side, this_price: u32, other_price: u32) bool {
        return switch (self) {
            .buy => this_price >= other_price,
            .sell => this_price <= other_price,
        };
    }

    /// Format for display.
    pub fn format(
        self: Side,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeByte(@intFromEnum(self));
    }
};

/// Order type.
pub const OrderType = enum(u8) {
    /// Market order: execute immediately at best available price.
    market = 'M',
    /// Limit order: execute at specified price or better.
    limit = 'L',
};

/// Input message type.
pub const InputMsgType = enum(u8) {
    /// New order submission.
    new_order = 'N',
    /// Cancel existing order.
    cancel = 'C',
    /// Flush/reset (testing only).
    flush = 'F',
};

/// Output message type.
pub const OutputMsgType = enum(u8) {
    /// Order acknowledged (accepted).
    ack = 'A',
    /// Trade execution.
    trade = 'T',
    /// Top of book update (market data).
    top_of_book = 'B',
    /// Cancel acknowledged.
    cancel_ack = 'X',
    /// Order rejected.
    reject = 'R',
};

/// Rejection reason codes.
pub const RejectReason = enum(u8) {
    /// Symbol not recognized.
    unknown_symbol = 1,
    /// Quantity is zero or exceeds limits.
    invalid_quantity = 2,
    /// Price is zero (for limit orders) or exceeds limits.
    invalid_price = 3,
    /// Order ID not found (for cancel).
    order_not_found = 4,
    /// Duplicate user order ID.
    duplicate_order_id = 5,
    /// Order pool exhausted.
    pool_exhausted = 6,
    /// User not authorized.
    unauthorized = 7,
    /// System overloaded.
    throttled = 8,
    /// Order book full (too many price levels).
    book_full = 9,

    /// Get human-readable description.
    pub fn description(self: RejectReason) []const u8 {
        return switch (self) {
            .unknown_symbol => "Unknown symbol",
            .invalid_quantity => "Invalid quantity",
            .invalid_price => "Invalid price",
            .order_not_found => "Order not found",
            .duplicate_order_id => "Duplicate order ID",
            .pool_exhausted => "Order pool exhausted",
            .unauthorized => "Unauthorized",
            .throttled => "Rate limit exceeded",
            .book_full => "Order book full",
        };
    }
};

// ============================================================================
// Input Messages
// ============================================================================

/// New order submission.
pub const NewOrderMsg = extern struct {
    /// User identifier.
    user_id: u32,
    /// User's order identifier (must be unique per user).
    user_order_id: u32,
    /// Limit price (0 for market orders).
    price: u32,
    /// Order quantity.
    quantity: u32,
    /// Trading symbol.
    symbol: Symbol,
    /// Buy or sell.
    side: Side,
    /// Padding for alignment.
    _pad: [3]u8 = undefined,

    const Self = @This();

    comptime {
        // Verify size for wire compatibility
        std.debug.assert(@sizeOf(Self) == 28);
    }

    /// Check if order is valid.
    pub fn isValid(self: *const Self) bool {
        if (self.user_id == 0) return false;
        if (self.quantity == 0) return false;
        if (symbolIsEmpty(&self.symbol)) return false;
        return true;
    }

    /// Check if this is a market order.
    pub fn isMarketOrder(self: *const Self) bool {
        return self.price == 0;
    }
};

/// Cancel order request.
pub const CancelMsg = extern struct {
    /// User identifier.
    user_id: u32,
    /// User's order identifier to cancel.
    user_order_id: u32,
    /// Optional symbol hint (for routing optimization).
    symbol: Symbol = EMPTY_SYMBOL,

    const Self = @This();

    comptime {
        std.debug.assert(@sizeOf(Self) == 16);
    }

    /// Check if symbol hint is provided.
    pub fn hasSymbolHint(self: *const Self) bool {
        return !symbolIsEmpty(&self.symbol);
    }
};

/// Flush/reset message (testing only).
pub const FlushMsg = extern struct {
    /// Reserved for future use.
    _reserved: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(FlushMsg) == 4);
    }
};

/// Input message (tagged union).
pub const InputMsg = struct {
    msg_type: InputMsgType,
    data: InputMsgData,

    pub const InputMsgData = union {
        new_order: NewOrderMsg,
        cancel: CancelMsg,
        flush: FlushMsg,
    };

    const Self = @This();

    /// Create new order message.
    pub fn newOrder(order: NewOrderMsg) Self {
        return .{
            .msg_type = .new_order,
            .data = .{ .new_order = order },
        };
    }

    /// Create cancel message.
    pub fn cancel(user_id: u32, user_order_id: u32) Self {
        return .{
            .msg_type = .cancel,
            .data = .{ .cancel = .{
                .user_id = user_id,
                .user_order_id = user_order_id,
            } },
        };
    }

    /// Create cancel message with symbol hint.
    pub fn cancelWithSymbol(user_id: u32, user_order_id: u32, symbol: Symbol) Self {
        return .{
            .msg_type = .cancel,
            .data = .{ .cancel = .{
                .user_id = user_id,
                .user_order_id = user_order_id,
                .symbol = symbol,
            } },
        };
    }

    /// Create flush message.
    pub fn flush() Self {
        return .{
            .msg_type = .flush,
            .data = .{ .flush = .{} },
        };
    }

    /// Get symbol (if applicable).
    pub fn getSymbol(self: *const Self) ?*const Symbol {
        return switch (self.msg_type) {
            .new_order => &self.data.new_order.symbol,
            .cancel => if (self.data.cancel.hasSymbolHint())
                &self.data.cancel.symbol
            else
                null,
            .flush => null,
        };
    }

    /// Get user ID.
    pub fn getUserId(self: *const Self) u32 {
        return switch (self.msg_type) {
            .new_order => self.data.new_order.user_id,
            .cancel => self.data.cancel.user_id,
            .flush => 0,
        };
    }
};

// ============================================================================
// Output Messages
// ============================================================================

/// Order acknowledgment.
pub const AckMsg = extern struct {
    user_id: u32,
    user_order_id: u32,

    comptime {
        std.debug.assert(@sizeOf(AckMsg) == 8);
    }
};

/// Trade execution report.
pub const TradeMsg = extern struct {
    /// Buyer's user ID.
    buy_user_id: u32,
    /// Buyer's order ID.
    buy_order_id: u32,
    /// Seller's user ID.
    sell_user_id: u32,
    /// Seller's order ID.
    sell_order_id: u32,
    /// Execution price.
    price: u32,
    /// Execution quantity.
    quantity: u32,

    comptime {
        std.debug.assert(@sizeOf(TradeMsg) == 24);
    }

    /// Get total trade value (price * quantity).
    /// Returns null on overflow.
    pub fn getValue(self: *const TradeMsg) ?u64 {
        const result = @as(u64, self.price) * @as(u64, self.quantity);
        return result;
    }
};

/// Top of book update (market data).
pub const TopOfBookMsg = extern struct {
    /// Side being updated.
    side: Side,
    /// Padding.
    _pad: [3]u8 = undefined,
    /// Best price (0 if empty).
    price: u32,
    /// Total quantity at best price.
    quantity: u32,

    comptime {
        std.debug.assert(@sizeOf(TopOfBookMsg) == 12);
    }

    /// Check if this side of book is empty.
    pub fn isEmpty(self: *const TopOfBookMsg) bool {
        return self.price == 0 and self.quantity == 0;
    }
};

/// Cancel acknowledgment.
pub const CancelAckMsg = extern struct {
    user_id: u32,
    user_order_id: u32,

    comptime {
        std.debug.assert(@sizeOf(CancelAckMsg) == 8);
    }
};

/// Order rejection.
pub const RejectMsg = extern struct {
    user_id: u32,
    user_order_id: u32,
    reason: RejectReason,
    _pad: [3]u8 = undefined,

    comptime {
        std.debug.assert(@sizeOf(RejectMsg) == 12);
    }
};

/// Output message (tagged union).
pub const OutputMsg = struct {
    /// Message type tag.
    msg_type: OutputMsgType,
    /// Destination client ID (0 = broadcast).
    client_id: u32,
    /// Trading symbol.
    symbol: Symbol,
    /// Message payload.
    data: OutputMsgData,

    pub const OutputMsgData = union {
        ack: AckMsg,
        trade: TradeMsg,
        top_of_book: TopOfBookMsg,
        cancel_ack: CancelAckMsg,
        reject: RejectMsg,
    };

    const Self = @This();

    // === Factory Methods ===

    pub fn makeAck(user_id: u32, user_order_id: u32, symbol: Symbol, client_id: u32) Self {
        return .{
            .msg_type = .ack,
            .client_id = client_id,
            .symbol = symbol,
            .data = .{ .ack = .{
                .user_id = user_id,
                .user_order_id = user_order_id,
            } },
        };
    }

    pub fn makeTrade(
        buy_uid: u32,
        buy_oid: u32,
        sell_uid: u32,
        sell_oid: u32,
        price: u32,
        quantity: u32,
        symbol: Symbol,
        client_id: u32,
    ) Self {
        return .{
            .msg_type = .trade,
            .client_id = client_id,
            .symbol = symbol,
            .data = .{ .trade = .{
                .buy_user_id = buy_uid,
                .buy_order_id = buy_oid,
                .sell_user_id = sell_uid,
                .sell_order_id = sell_oid,
                .price = price,
                .quantity = quantity,
            } },
        };
    }

    pub fn makeTopOfBook(symbol: Symbol, side: Side, price: u32, qty: u32) Self {
        return .{
            .msg_type = .top_of_book,
            .client_id = 0, // Always broadcast
            .symbol = symbol,
            .data = .{ .top_of_book = .{
                .side = side,
                .price = price,
                .quantity = qty,
            } },
        };
    }

    pub fn makeCancelAck(user_id: u32, user_order_id: u32, symbol: Symbol, client_id: u32) Self {
        return .{
            .msg_type = .cancel_ack,
            .client_id = client_id,
            .symbol = symbol,
            .data = .{ .cancel_ack = .{
                .user_id = user_id,
                .user_order_id = user_order_id,
            } },
        };
    }

    pub fn makeReject(
        user_id: u32,
        user_order_id: u32,
        reason: RejectReason,
        symbol: Symbol,
        client_id: u32,
    ) Self {
        return .{
            .msg_type = .reject,
            .client_id = client_id,
            .symbol = symbol,
            .data = .{ .reject = .{
                .user_id = user_id,
                .user_order_id = user_order_id,
                .reason = reason,
            } },
        };
    }

    // === Accessors ===

    /// Get user ID from message (if applicable).
    pub fn getUserId(self: *const Self) u32 {
        return switch (self.msg_type) {
            .ack => self.data.ack.user_id,
            .trade => self.data.trade.buy_user_id, // Primary party
            .top_of_book => 0,
            .cancel_ack => self.data.cancel_ack.user_id,
            .reject => self.data.reject.user_id,
        };
    }

    /// Check if message is an error/rejection.
    pub fn isError(self: *const Self) bool {
        return self.msg_type == .reject;
    }

    /// Check if message should be broadcast (vs unicast).
    pub fn isBroadcast(self: *const Self) bool {
        return self.msg_type == .top_of_book or self.client_id == 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Symbol operations" {
    const sym1 = makeSymbol("AAPL");
    const sym2 = makeSymbol("AAPL");
    const sym3 = makeSymbol("MSFT");

    try std.testing.expect(symbolEqual(&sym1, &sym2));
    try std.testing.expect(!symbolEqual(&sym1, &sym3));
    try std.testing.expectEqualStrings("AAPL", symbolSlice(&sym1));

    try std.testing.expect(!symbolIsEmpty(&sym1));
    try std.testing.expect(symbolIsEmpty(&EMPTY_SYMBOL));
}

test "Symbol truncation" {
    const long_sym = makeSymbol("VERYLONGSYMBOL");
    try std.testing.expectEqualStrings("VERYLONG", symbolSlice(&long_sym));
}

test "Side operations" {
    try std.testing.expectEqual(Side.sell, Side.buy.opposite());
    try std.testing.expectEqual(Side.buy, Side.sell.opposite());

    // Buy at 100 crosses sell at 100
    try std.testing.expect(Side.buy.wouldCross(100, 100));
    // Buy at 100 crosses sell at 99
    try std.testing.expect(Side.buy.wouldCross(100, 99));
    // Buy at 100 doesn't cross sell at 101
    try std.testing.expect(!Side.buy.wouldCross(100, 101));
}

test "NewOrderMsg validation" {
    const valid = NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 50,
        .symbol = makeSymbol("IBM"),
        .side = .buy,
    };
    try std.testing.expect(valid.isValid());
    try std.testing.expect(!valid.isMarketOrder());

    const market = NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 0,
        .quantity = 50,
        .symbol = makeSymbol("IBM"),
        .side = .buy,
    };
    try std.testing.expect(market.isMarketOrder());

    const invalid_qty = NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 0, // Invalid
        .symbol = makeSymbol("IBM"),
        .side = .buy,
    };
    try std.testing.expect(!invalid_qty.isValid());
}

test "InputMsg factories" {
    const order = InputMsg.newOrder(.{
        .user_id = 1,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 50,
        .symbol = makeSymbol("IBM"),
        .side = .buy,
    });
    try std.testing.expectEqual(InputMsgType.new_order, order.msg_type);
    try std.testing.expectEqual(@as(u32, 1), order.getUserId());

    const cancel = InputMsg.cancel(1, 100);
    try std.testing.expectEqual(InputMsgType.cancel, cancel.msg_type);

    const flush_msg = InputMsg.flush();
    try std.testing.expectEqual(InputMsgType.flush, flush_msg.msg_type);
}

test "OutputMsg factories" {
    const ack = OutputMsg.makeAck(1, 100, makeSymbol("IBM"), 42);
    try std.testing.expectEqual(OutputMsgType.ack, ack.msg_type);
    try std.testing.expectEqual(@as(u32, 42), ack.client_id);
    try std.testing.expect(!ack.isError());

    const reject = OutputMsg.makeReject(1, 100, .invalid_price, makeSymbol("IBM"), 42);
    try std.testing.expect(reject.isError());

    const tob = OutputMsg.makeTopOfBook(makeSymbol("IBM"), .buy, 100, 500);
    try std.testing.expect(tob.isBroadcast());
}

test "RejectReason descriptions" {
    try std.testing.expectEqualStrings("Order book full", RejectReason.book_full.description());
    try std.testing.expectEqualStrings("Order pool exhausted", RejectReason.pool_exhausted.description());
}

test "Struct sizes" {
    // Verify wire format compatibility
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(NewOrderMsg));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CancelMsg));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(AckMsg));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(TradeMsg));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(TopOfBookMsg));
}
