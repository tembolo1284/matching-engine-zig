//! Output Buffer - Message Collection
//!
//! Collects output messages generated during order processing.
//! Fixed-size buffer with no dynamic allocation (Rule 3).

const std = @import("std");
const msg = @import("../protocol/message_types.zig");

pub const MAX_OUTPUT_MESSAGES: u32 = 8192;

pub const OutputBuffer = struct {
    messages: [MAX_OUTPUT_MESSAGES]msg.OutputMsg,
    count: u32,

    const Self = @This();

    pub fn init() Self {
        const self = Self{
            .messages = undefined,
            .count = 0,
        };
        std.debug.assert(self.count == 0);
        return self;
    }

    pub fn reset(self: *Self) void {
        self.count = 0;
        std.debug.assert(self.count == 0);
    }

    pub fn hasSpace(self: *const Self, needed: u32) bool {
        std.debug.assert(self.count <= MAX_OUTPUT_MESSAGES);
        return (self.count + needed) <= MAX_OUTPUT_MESSAGES;
    }

    pub fn len(self: *const Self) u32 {
        return self.count;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.count == 0;
    }

    pub fn isFull(self: *const Self) bool {
        return self.count >= MAX_OUTPUT_MESSAGES;
    }

    pub fn add(self: *Self, message: *const msg.OutputMsg) void {
        std.debug.assert(msg.OutputMsgType.isValid(@intFromEnum(message.type)));
        std.debug.assert(self.count <= MAX_OUTPUT_MESSAGES);

        if (self.count < MAX_OUTPUT_MESSAGES) {
            self.messages[self.count] = message.*;
            self.count += 1;
        }
    }

    pub fn addAck(self: *Self, symbol: []const u8, user_id: u32, user_order_id: u32) void {
        const ack = msg.makeAckMsg(symbol, user_id, user_order_id);
        self.add(&ack);
    }

    pub fn addCancelAck(self: *Self, symbol: []const u8, user_id: u32, user_order_id: u32) void {
        const cancel_ack = msg.makeCancelAckMsg(symbol, user_id, user_order_id);
        self.add(&cancel_ack);
    }

    pub fn addTrade(
        self: *Self,
        symbol: []const u8,
        user_id_buy: u32,
        user_order_id_buy: u32,
        user_id_sell: u32,
        user_order_id_sell: u32,
        price: u32,
        quantity: u32,
    ) void {
        const trade = msg.makeTradeMsg(
            symbol,
            user_id_buy,
            user_order_id_buy,
            user_id_sell,
            user_order_id_sell,
            price,
            quantity,
        );
        self.add(&trade);
    }

    pub fn addTradeWithClients(
        self: *Self,
        symbol: []const u8,
        user_id_buy: u32,
        user_order_id_buy: u32,
        buy_client_id: u32,
        user_id_sell: u32,
        user_order_id_sell: u32,
        sell_client_id: u32,
        price: u32,
        quantity: u32,
    ) void {
        var trade = msg.makeTradeMsg(
            symbol,
            user_id_buy,
            user_order_id_buy,
            user_id_sell,
            user_order_id_sell,
            price,
            quantity,
        );
        trade.data.trade.buy_client_id = buy_client_id;
        trade.data.trade.sell_client_id = sell_client_id;
        self.add(&trade);
    }

    pub fn addTopOfBook(self: *Self, symbol: []const u8, side: msg.Side, price: u32, quantity: u32) void {
        const tob = msg.makeTopOfBookMsg(symbol, side, price, quantity);
        self.add(&tob);
    }

    pub fn addTopOfBookEliminated(self: *Self, symbol: []const u8, side: msg.Side) void {
        const tob = msg.makeTopOfBookEliminatedMsg(symbol, side);
        self.add(&tob);
    }

    pub fn slice(self: *const Self) []const msg.OutputMsg {
        return self.messages[0..self.count];
    }

    pub fn sliceMut(self: *Self) []msg.OutputMsg {
        return self.messages[0..self.count];
    }

    pub fn get(self: *const Self, index: u32) *const msg.OutputMsg {
        std.debug.assert(index < self.count);
        return &self.messages[index];
    }

    pub fn iterator(self: *const Self) Iterator {
        return Iterator{
            .buffer = self,
            .index = 0,
        };
    }

    pub const Iterator = struct {
        buffer: *const OutputBuffer,
        index: u32,

        pub fn next(self: *Iterator) ?*const msg.OutputMsg {
            if (self.index >= self.buffer.count) {
                return null;
            }
            const result = &self.buffer.messages[self.index];
            self.index += 1;
            return result;
        }

        pub fn reset(self: *Iterator) void {
            self.index = 0;
        }
    };
};

// ============================================================================
// Tests
// ============================================================================

test "output buffer init" {
    const buf = OutputBuffer.init();
    try std.testing.expectEqual(@as(u32, 0), buf.count);
    try std.testing.expect(buf.isEmpty());
    try std.testing.expect(!buf.isFull());
    try std.testing.expect(buf.hasSpace(100));
}

test "output buffer add and retrieve" {
    var buf = OutputBuffer.init();

    buf.addAck("IBM", 1, 100);
    buf.addAck("AAPL", 2, 200);

    try std.testing.expectEqual(@as(u32, 2), buf.len());
    try std.testing.expect(!buf.isEmpty());

    const first = buf.get(0);
    try std.testing.expectEqual(msg.OutputMsgType.ack, first.type);
    try std.testing.expectEqual(@as(u32, 1), first.data.ack.user_id);
    try std.testing.expectEqual(@as(u32, 100), first.data.ack.user_order_id);
}

test "output buffer reset" {
    var buf = OutputBuffer.init();

    buf.addAck("IBM", 1, 100);
    buf.addAck("AAPL", 2, 200);
    try std.testing.expectEqual(@as(u32, 2), buf.len());

    buf.reset();
    try std.testing.expectEqual(@as(u32, 0), buf.len());
    try std.testing.expect(buf.isEmpty());
}

test "output buffer trade with clients" {
    var buf = OutputBuffer.init();

    buf.addTradeWithClients("IBM", 1, 100, 10, 2, 200, 20, 150, 500);

    try std.testing.expectEqual(@as(u32, 1), buf.len());

    const trade = buf.get(0);
    try std.testing.expectEqual(msg.OutputMsgType.trade, trade.type);
    try std.testing.expectEqual(@as(u32, 10), trade.data.trade.buy_client_id);
    try std.testing.expectEqual(@as(u32, 20), trade.data.trade.sell_client_id);
}

test "output buffer iterator" {
    var buf = OutputBuffer.init();

    buf.addAck("IBM", 1, 100);
    buf.addCancelAck("AAPL", 2, 200);
    buf.addTopOfBook("GOOG", .buy, 150, 1000);

    var iter = buf.iterator();
    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(u32, 3), count);
}

test "output buffer slice" {
    var buf = OutputBuffer.init();

    buf.addAck("IBM", 1, 100);
    buf.addAck("AAPL", 2, 200);

    const s = buf.slice();
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqual(msg.OutputMsgType.ack, s[0].type);
    try std.testing.expectEqual(msg.OutputMsgType.ack, s[1].type);
}

test "output buffer has space" {
    var buf = OutputBuffer.init();

    try std.testing.expect(buf.hasSpace(MAX_OUTPUT_MESSAGES));
    try std.testing.expect(buf.hasSpace(MAX_OUTPUT_MESSAGES - 1));

    var i: u32 = 0;
    while (i < MAX_OUTPUT_MESSAGES - 10) : (i += 1) {
        buf.addAck("IBM", 1, i);
    }

    try std.testing.expect(buf.hasSpace(10));
    try std.testing.expect(!buf.hasSpace(11));
}
