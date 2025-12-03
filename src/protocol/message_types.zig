//! Message type definitions for the matching engine protocol.

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

pub const MAX_SYMBOL_LENGTH = 8;
pub const Symbol = [MAX_SYMBOL_LENGTH]u8;

pub const EMPTY_SYMBOL: Symbol = [_]u8{0} ** MAX_SYMBOL_LENGTH;

pub fn makeSymbol(str: []const u8) Symbol {
    var sym: Symbol = [_]u8{0} ** MAX_SYMBOL_LENGTH;
    const len = @min(str.len, MAX_SYMBOL_LENGTH);
    @memcpy(sym[0..len], str[0..len]);
    return sym;
}

pub fn symbolEqual(a: Symbol, b: Symbol) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn symbolSlice(sym: *const Symbol) []const u8 {
    for (sym, 0..) |c, i| {
        if (c == 0) return sym[0..i];
    }
    return sym[0..MAX_SYMBOL_LENGTH];
}

pub fn symbolIsEmpty(sym: *const Symbol) bool {
    return sym[0] == 0;
}

// ============================================================================
// Enums
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
    cancel_ack = 'X',
    reject = 'R',
};

// ============================================================================
// Input Messages
// ============================================================================

/// New order message
pub const NewOrderMsg = struct {
    user_id: u32,
    symbol: Symbol,
    price: u32,
    quantity: u32,
    side: Side,
    user_order_id: u32,
};

/// Cancel order message
pub const CancelMsg = struct {
    user_id: u32,
    user_order_id: u32,
    symbol: Symbol = EMPTY_SYMBOL,
};

/// Flush message
pub const FlushMsg = struct {
    _reserved: u32 = 0,
};

/// Input message union
pub const InputMsg = struct {
    msg_type: InputMsgType,
    data: union {
        new_order: NewOrderMsg,
        cancel: CancelMsg,
        flush: FlushMsg,
    },
};

// ============================================================================
// Output Messages
// ============================================================================

pub const AckMsg = struct {
    user_id: u32,
    user_order_id: u32,
};

pub const TradeMsg = struct {
    buy_user_id: u32,
    buy_order_id: u32,
    sell_user_id: u32,
    sell_order_id: u32,
    price: u32,
    quantity: u32,
};

pub const TopOfBookMsg = struct {
    side: Side,
    price: u32,
    quantity: u32,
};

pub const CancelAckMsg = struct {
    user_id: u32,
    user_order_id: u32,
};

pub const RejectMsg = struct {
    user_id: u32,
    user_order_id: u32,
    reason: RejectReason,
};

pub const RejectReason = enum(u8) {
    unknown_symbol = 1,
    invalid_quantity = 2,
    invalid_price = 3,
    order_not_found = 4,
    duplicate_order_id = 5,
    pool_exhausted = 6,
};

/// Output message with symbol at top level
pub const OutputMsg = struct {
    msg_type: OutputMsgType,
    client_id: u32,
    symbol: Symbol,
    data: union {
        ack: AckMsg,
        trade: TradeMsg,
        top_of_book: TopOfBookMsg,
        cancel_ack: CancelAckMsg,
        reject: RejectMsg,
    },

    const Self = @This();

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
            .client_id = 0,
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
