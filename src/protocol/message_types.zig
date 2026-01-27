//! Message Type Definitions
//!
//! Core message structures for the matching engine protocol.
//! All structures are designed for minimal padding and optimal cache behavior.
//!
//! Design principles:
//! - Explicit padding for portability
//! - Comptime assertions verify all sizes
//! - Helper functions include assertions (Rule 5)
//! - u8 enums for space efficiency

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

pub const MAX_SYMBOL_LENGTH = 16;

// ============================================================================
// Enumerations
// ============================================================================

/// Side: Buy or Sell
pub const Side = enum(u8) {
    buy = 'B',
    sell = 'S',

    pub fn isValid(value: u8) bool {
        return value == 'B' or value == 'S';
    }

    pub fn fromByte(value: u8) ?Side {
        return switch (value) {
            'B' => .buy,
            'S' => .sell,
            else => null,
        };
    }
};

/// Order type
pub const OrderType = enum(u8) {
    market = 0,
    limit = 1,
};

/// Input message types
pub const InputMsgType = enum(u8) {
    new_order = 0,
    cancel = 1,
    flush = 2,

    pub fn isValid(value: u8) bool {
        return value <= 2;
    }
};

/// Output message types
pub const OutputMsgType = enum(u8) {
    ack = 0,
    cancel_ack = 1,
    trade = 2,
    top_of_book = 3,

    pub fn isValid(value: u8) bool {
        return value <= 3;
    }
};

// ============================================================================
// Symbol Type
// ============================================================================

/// Fixed-size symbol array with helper methods
pub const Symbol = [MAX_SYMBOL_LENGTH]u8;

/// Copy symbol with bounds checking (Rule 2: bounded loop)
pub fn copySymbol(dest: *Symbol, src: []const u8) void {
    std.debug.assert(src.len > 0); // Rule 5: precondition

    const copy_len = @min(src.len, MAX_SYMBOL_LENGTH - 1);
    @memcpy(dest[0..copy_len], src[0..copy_len]);

    // Null-terminate and zero-pad remaining
    for (dest[copy_len..]) |*byte| {
        byte.* = 0;
    }

    std.debug.assert(dest[copy_len] == 0); // Rule 5: postcondition
}

/// Copy symbol to smaller buffer (for TOB's 15-byte symbol)
pub fn copySymbolToSlice(dest: []u8, src: []const u8) void {
    std.debug.assert(dest.len > 0); // Rule 5: precondition
    std.debug.assert(src.len > 0);

    const copy_len = @min(src.len, dest.len - 1);
    @memcpy(dest[0..copy_len], src[0..copy_len]);

    // Null-terminate and zero-pad
    for (dest[copy_len..]) |*byte| {
        byte.* = 0;
    }

    std.debug.assert(dest[copy_len] == 0); // Rule 5: postcondition
}

/// Get symbol as slice (up to null terminator)
pub fn symbolSlice(symbol: *const Symbol) []const u8 {
    for (symbol, 0..) |byte, i| {
        if (byte == 0) {
            return symbol[0..i];
        }
    }
    return symbol[0..];
}

// ============================================================================
// Input Message Structures
// ============================================================================

/// New Order Message (36 bytes)
///
/// Layout:
///   0-3:   user_id
///   4-7:   user_order_id
///   8-11:  price
///   12-15: quantity
///   16:    side (u8)
///   17-19: padding
///   20-35: symbol[16]
pub const NewOrderMsg = extern struct {
    user_id: u32,
    user_order_id: u32,
    price: u32, // 0 = market order
    quantity: u32,
    side: Side,
    _pad: [3]u8 = .{ 0, 0, 0 },
    symbol: Symbol,

    comptime {
        std.debug.assert(@sizeOf(NewOrderMsg) == 36);
        std.debug.assert(@offsetOf(NewOrderMsg, "symbol") == 20);
    }
};

/// Cancel Message (24 bytes)
///
/// Layout:
///   0-3:   user_id
///   4-7:   user_order_id
///   8-23:  symbol[16]
pub const CancelMsg = extern struct {
    user_id: u32,
    user_order_id: u32,
    symbol: Symbol,

    comptime {
        std.debug.assert(@sizeOf(CancelMsg) == 24);
    }
};

/// Flush Message (1 byte) - empty signal
pub const FlushMsg = extern struct {
    _unused: u8 = 0,

    comptime {
        std.debug.assert(@sizeOf(FlushMsg) == 1);
    }
};

/// Input Message Data Union (36 bytes)
pub const InputMsgData = extern union {
    new_order: NewOrderMsg, // 36 bytes
    cancel: CancelMsg, // 24 bytes
    flush: FlushMsg, // 1 byte
};

/// Input Message - Tagged Union (40 bytes)
///
/// Layout:
///   0:     type (u8)
///   1-3:   padding
///   4-39:  union (36 bytes)
pub const InputMsg = extern struct {
    type: InputMsgType,
    _pad: [3]u8 = .{ 0, 0, 0 },
    data: InputMsgData,

    comptime {
        std.debug.assert(@sizeOf(InputMsg) == 40);
        std.debug.assert(@offsetOf(InputMsg, "data") == 4);
    }

    /// Get symbol from input message (null for flush)
    pub fn getSymbol(self: *const InputMsg) ?[]const u8 {
        return switch (self.type) {
            .new_order => symbolSlice(&self.data.new_order.symbol),
            .cancel => symbolSlice(&self.data.cancel.symbol),
            .flush => null,
        };
    }

    /// Get user_id from input message (0 for flush)
    pub fn getUserId(self: *const InputMsg) u32 {
        return switch (self.type) {
            .new_order => self.data.new_order.user_id,
            .cancel => self.data.cancel.user_id,
            .flush => 0,
        };
    }
};

// ============================================================================
// Output Message Structures
// ============================================================================

/// Acknowledgment Message (24 bytes)
pub const AckMsg = extern struct {
    user_id: u32,
    user_order_id: u32,
    symbol: Symbol,

    comptime {
        std.debug.assert(@sizeOf(AckMsg) == 24);
    }
};

/// Cancel Acknowledgment Message (24 bytes)
pub const CancelAckMsg = extern struct {
    user_id: u32,
    user_order_id: u32,
    symbol: Symbol,

    comptime {
        std.debug.assert(@sizeOf(CancelAckMsg) == 24);
    }
};

/// Trade Message (48 bytes)
///
/// Layout:
///   0-3:   user_id_buy
///   4-7:   user_order_id_buy
///   8-11:  user_id_sell
///   12-15: user_order_id_sell
///   16-19: price
///   20-23: quantity
///   24-27: buy_client_id
///   28-31: sell_client_id
///   32-47: symbol[16]
pub const TradeMsg = extern struct {
    user_id_buy: u32,
    user_order_id_buy: u32,
    user_id_sell: u32,
    user_order_id_sell: u32,
    price: u32,
    quantity: u32,
    buy_client_id: u32,
    sell_client_id: u32,
    symbol: Symbol,

    comptime {
        std.debug.assert(@sizeOf(TradeMsg) == 48);
        std.debug.assert(@offsetOf(TradeMsg, "symbol") == 32);
    }
};

/// Top of Book Message (24 bytes)
///
/// Layout:
///   0-3:   price (0 = eliminated)
///   4-7:   total_quantity (0 = eliminated)
///   8:     side
///   9-23:  symbol[15]
pub const TopOfBookMsg = extern struct {
    price: u32, // 0 means eliminated
    total_quantity: u32, // 0 means eliminated
    side: Side,
    symbol: [15]u8, // 15 chars to fit 24 bytes total

    comptime {
        std.debug.assert(@sizeOf(TopOfBookMsg) == 24);
    }

    pub fn isEliminated(self: *const TopOfBookMsg) bool {
        return self.price == 0 and self.total_quantity == 0;
    }
};

/// Output Message Data Union (48 bytes)
pub const OutputMsgData = extern union {
    ack: AckMsg, // 24 bytes
    cancel_ack: CancelAckMsg, // 24 bytes
    trade: TradeMsg, // 48 bytes
    top_of_book: TopOfBookMsg, // 24 bytes
};

/// Output Message - Tagged Union (52 bytes)
///
/// Layout:
///   0:     type (u8)
///   1-3:   padding
///   4-51:  union (48 bytes)
pub const OutputMsg = extern struct {
    type: OutputMsgType,
    _pad: [3]u8 = .{ 0, 0, 0 },
    data: OutputMsgData,

    comptime {
        std.debug.assert(@sizeOf(OutputMsg) == 52);
        std.debug.assert(@offsetOf(OutputMsg, "data") == 4);
    }
};

// ============================================================================
// Message Factory Functions (with Rule 5 assertions)
// ============================================================================

/// Create new order input message
pub fn makeNewOrderMsg(msg: *const NewOrderMsg) InputMsg {
    std.debug.assert(msg.side == .buy or msg.side == .sell); // Rule 5
    std.debug.assert(msg.quantity > 0); // Rule 5

    var result: InputMsg = undefined;
    @memset(std.mem.asBytes(&result), 0); // Clear padding
    result.type = .new_order;
    result._pad = .{ 0, 0, 0 };
    result.data.new_order = msg.*;

    std.debug.assert(result.type == .new_order); // Rule 5: postcondition
    return result;
}

/// Create cancel input message
pub fn makeCancelMsg(msg: *const CancelMsg) InputMsg {
    std.debug.assert(msg.user_id != 0); // Rule 5

    var result: InputMsg = undefined;
    @memset(std.mem.asBytes(&result), 0);
    result.type = .cancel;
    result._pad = .{ 0, 0, 0 };
    result.data.cancel = msg.*;

    std.debug.assert(result.type == .cancel); // Rule 5
    return result;
}

/// Create flush input message
pub fn makeFlushMsg() InputMsg {
    var result: InputMsg = undefined;
    @memset(std.mem.asBytes(&result), 0);
    result.type = .flush;
    result._pad = .{ 0, 0, 0 };
    result.data.flush._unused = 0;

    std.debug.assert(result.type == .flush); // Rule 5
    return result;
}

/// Create acknowledgment output message
pub fn makeAckMsg(symbol: []const u8, user_id: u32, user_order_id: u32) OutputMsg {
    std.debug.assert(symbol.len > 0); // Rule 5
    std.debug.assert(symbol[0] != 0); // Rule 5: non-empty symbol

    var msg: OutputMsg = undefined;
    @memset(std.mem.asBytes(&msg), 0);
    msg.type = .ack;
    msg._pad = .{ 0, 0, 0 };
    msg.data.ack.user_id = user_id;
    msg.data.ack.user_order_id = user_order_id;
    copySymbol(&msg.data.ack.symbol, symbol);

    std.debug.assert(msg.type == .ack); // Rule 5
    return msg;
}

/// Create cancel acknowledgment output message
pub fn makeCancelAckMsg(symbol: []const u8, user_id: u32, user_order_id: u32) OutputMsg {
    std.debug.assert(symbol.len > 0); // Rule 5
    std.debug.assert(symbol[0] != 0); // Rule 5

    var msg: OutputMsg = undefined;
    @memset(std.mem.asBytes(&msg), 0);
    msg.type = .cancel_ack;
    msg._pad = .{ 0, 0, 0 };
    msg.data.cancel_ack.user_id = user_id;
    msg.data.cancel_ack.user_order_id = user_order_id;
    copySymbol(&msg.data.cancel_ack.symbol, symbol);

    std.debug.assert(msg.type == .cancel_ack); // Rule 5
    return msg;
}

/// Create trade output message
pub fn makeTradeMsg(
    symbol: []const u8,
    user_id_buy: u32,
    user_order_id_buy: u32,
    user_id_sell: u32,
    user_order_id_sell: u32,
    price: u32,
    quantity: u32,
) OutputMsg {
    std.debug.assert(symbol.len > 0); // Rule 5
    std.debug.assert(quantity > 0); // Rule 5

    var msg: OutputMsg = undefined;
    @memset(std.mem.asBytes(&msg), 0);
    msg.type = .trade;
    msg._pad = .{ 0, 0, 0 };
    msg.data.trade.user_id_buy = user_id_buy;
    msg.data.trade.user_order_id_buy = user_order_id_buy;
    msg.data.trade.user_id_sell = user_id_sell;
    msg.data.trade.user_order_id_sell = user_order_id_sell;
    msg.data.trade.price = price;
    msg.data.trade.quantity = quantity;
    msg.data.trade.buy_client_id = 0; // Set by caller if needed
    msg.data.trade.sell_client_id = 0;
    copySymbol(&msg.data.trade.symbol, symbol);

    std.debug.assert(msg.type == .trade); // Rule 5
    return msg;
}

/// Create top-of-book output message
pub fn makeTopOfBookMsg(symbol: []const u8, side: Side, price: u32, total_quantity: u32) OutputMsg {
    std.debug.assert(symbol.len > 0); // Rule 5
    std.debug.assert(side == .buy or side == .sell); // Rule 5

    var msg: OutputMsg = undefined;
    @memset(std.mem.asBytes(&msg), 0);
    msg.type = .top_of_book;
    msg._pad = .{ 0, 0, 0 };
    msg.data.top_of_book.price = price;
    msg.data.top_of_book.total_quantity = total_quantity;
    msg.data.top_of_book.side = side;
    copySymbolToSlice(&msg.data.top_of_book.symbol, symbol);

    std.debug.assert(msg.type == .top_of_book); // Rule 5
    return msg;
}

/// Create top-of-book eliminated message
pub fn makeTopOfBookEliminatedMsg(symbol: []const u8, side: Side) OutputMsg {
    return makeTopOfBookMsg(symbol, side, 0, 0);
}

// ============================================================================
// Tests
// ============================================================================

test "struct sizes match C implementation" {
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(NewOrderMsg));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(CancelMsg));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(FlushMsg));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(InputMsg));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(AckMsg));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(CancelAckMsg));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(TradeMsg));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(TopOfBookMsg));
    try std.testing.expectEqual(@as(usize, 52), @sizeOf(OutputMsg));
}

test "symbol copy" {
    var sym: Symbol = undefined;
    copySymbol(&sym, "IBM");
    try std.testing.expectEqualStrings("IBM", symbolSlice(&sym));

    // Test truncation
    copySymbol(&sym, "VERYLONGSYMBOLNAME");
    try std.testing.expectEqual(@as(usize, 15), symbolSlice(&sym).len);
}

test "make ack message" {
    const msg = makeAckMsg("AAPL", 1, 100);
    try std.testing.expectEqual(OutputMsgType.ack, msg.type);
    try std.testing.expectEqual(@as(u32, 1), msg.data.ack.user_id);
    try std.testing.expectEqual(@as(u32, 100), msg.data.ack.user_order_id);
    try std.testing.expectEqualStrings("AAPL", symbolSlice(&msg.data.ack.symbol));
}

test "top of book eliminated" {
    const msg = makeTopOfBookEliminatedMsg("IBM", .buy);
    try std.testing.expect(msg.data.top_of_book.isEliminated());
}
