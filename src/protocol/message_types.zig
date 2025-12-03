//! Message type definitions for the matching engine protocol.
//! All structures are cache-line aware and use explicit padding.
//! Matches C protocol specification with network byte order.

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

pub const MAX_SYMBOL_LENGTH = 8;
pub const Symbol = [MAX_SYMBOL_LENGTH]u8;

/// Empty symbol constant
pub const EMPTY_SYMBOL: Symbol = [_]u8{0} ** MAX_SYMBOL_LENGTH;

/// Create symbol from string slice
pub fn makeSymbol(str: []const u8) Symbol {
    var sym: Symbol = [_]u8{0} ** MAX_SYMBOL_LENGTH;
    const len = @min(str.len, MAX_SYMBOL_LENGTH);
    @memcpy(sym[0..len], str[0..len]);
    return sym;
}

/// Compare two symbols for equality
pub fn symbolEqual(a: Symbol, b: Symbol) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Get symbol as slice (stops at null terminator)
pub fn symbolSlice(sym: *const Symbol) []const u8 {
    for (sym, 0..) |c, i| {
        if (c == 0) return sym[0..i];
    }
    return sym[0..MAX_SYMBOL_LENGTH];
}

/// Check if symbol is empty
pub fn symbolIsEmpty(sym: *const Symbol) bool {
    return sym[0] == 0;
}

// ============================================================================
// Enums (uint8_t for space efficiency)
// ============================================================================

pub const Side = enum(u8) {
    buy = 'B',
    sell = 'S',

    pub fn opposite(self: Side) Side {
        return switch (self) {
            .buy => .sell,
            .sell => .buy,
        };
    }
};

pub const OrderType = enum(u8) {
    market = 'M',
    limit = 'L',
};

pub const InputMsgType = enum(u8) {
    new_order = 'N',
    cancel = 'C',
    flush = 'F',
};

pub const OutputMsgType = enum(u8) {
    ack = 'A',
    trade = 'T',
    top_of_book = 'B',
    cancel_ack = 'X',  // Binary uses 'X', CSV uses 'C'
    reject = 'R',
};

// ============================================================================
// Input Messages
// ============================================================================

/// New order message - matches C binary_new_order_t (27 bytes payload)
pub const NewOrderMsg = extern struct {
    user_id: u32,           // 0-3
    symbol: Symbol,         // 4-11
    price: u32,             // 12-15: 0 = market order
    quantity: u32,          // 16-19
    side: Side,             // 20
    user_order_id: u32,     // 21-24 (note: not aligned, packed struct)
    _pad: [3]u8 = undefined, // 25-27

    comptime {
        std.debug.assert(@sizeOf(@This()) == 28);
    }
};

/// Cancel order message - matches C binary_cancel_order_t
pub const CancelMsg = extern struct {
    user_id: u32,           // 0-3
    user_order_id: u32,     // 4-7
    symbol: Symbol = EMPTY_SYMBOL, // 8-15 (optional, for routing)

    comptime {
        std.debug.assert(@sizeOf(@This()) == 16);
    }
};

/// Flush message
pub const FlushMsg = extern struct {
    _reserved: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 4);
    }
};

/// Input message union
pub const InputMsg = extern struct {
    msg_type: InputMsgType, // 0
    _pad: [3]u8 = undefined, // 1-3
    data: extern union {    // 4+
        new_order: NewOrderMsg,
        cancel: CancelMsg,
        flush: FlushMsg,
    },

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
    }
};

// ============================================================================
// Output Messages
// ============================================================================

/// Acknowledgement message
pub const AckMsg = extern struct {
    user_id: u32,
    user_order_id: u32,
};

/// Trade message
pub const TradeMsg = extern struct {
    buy_user_id: u32,
    buy_order_id: u32,
    sell_user_id: u32,
    sell_order_id: u32,
    price: u32,
    quantity: u32,
};

/// Top of book message
pub const TopOfBookMsg = extern struct {
    side: Side,
    _pad: [3]u8 = undefined,
    price: u32,             // 0 if no orders
    quantity: u32,          // 0 if no orders
};

/// Cancel acknowledgement message
pub const CancelAckMsg = extern struct {
    user_id: u32,
    user_order_id: u32,
};

/// Reject message
pub const RejectMsg = extern struct {
    user_id: u32,
    user_order_id: u32,
    reason: RejectReason,
    _pad: [3]u8 = undefined,
};

pub const RejectReason = enum(u8) {
    unknown_symbol = 1,
    invalid_quantity = 2,
    invalid_price = 3,
    order_not_found = 4,
    duplicate_order_id = 5,
    pool_exhausted = 6,
};

/// Output message with symbol at top level for routing and output formatting
pub const OutputMsg = struct {
    msg_type: OutputMsgType,
    client_id: u32,          // For TCP routing (0 = broadcast, high bit = UDP)
    symbol: Symbol,          // Symbol for output formatting
    data: union {
        ack: AckMsg,
        trade: TradeMsg,
        top_of_book: TopOfBookMsg,
        cancel_ack: CancelAckMsg,
        reject: RejectMsg,
    },

    const Self = @This();

    // Factory methods - all take symbol

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
            .client_id = 0, // Broadcast
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

    pub fn makeReject(user_id: u32, user_order_id: u32, reason: RejectReason, symbol: Symbol, client_id: u32) Self {
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
};
