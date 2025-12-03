//! Binary protocol codec - matches C specification exactly.
//!
//! Wire format:
//!   Byte 0:     Magic (0x4D = 'M')
//!   Byte 1:     Message type (ASCII char)
//!   Byte 2+:    Payload (type-specific, network byte order)
//!
//! All multi-byte integers are BIG-ENDIAN (network byte order).
//! Structs are packed (no padding between fields).

const std = @import("std");
const msg = @import("message_types.zig");
const codec = @import("codec.zig");

// ============================================================================
// Constants - Match C Protocol Spec
// ============================================================================

pub const MAGIC: u8 = 0x4D; // 'M'

// Message type bytes (ASCII chars)
pub const MSG_NEW_ORDER: u8 = 'N'; // 0x4E
pub const MSG_CANCEL: u8 = 'C'; // 0x43
pub const MSG_FLUSH: u8 = 'F'; // 0x46
pub const MSG_ACK: u8 = 'A'; // 0x41
pub const MSG_CANCEL_ACK: u8 = 'X'; // 0x58
pub const MSG_TRADE: u8 = 'T'; // 0x54
pub const MSG_TOP_OF_BOOK: u8 = 'B'; // 0x42

// Wire sizes (from C spec) - includes magic + type
pub const NEW_ORDER_WIRE_SIZE: usize = 27; // magic(1) + type(1) + user_id(4) + symbol(8) + price(4) + qty(4) + side(1) + order_id(4)
pub const CANCEL_WIRE_SIZE: usize = 10; // magic(1) + type(1) + user_id(4) + order_id(4)
pub const FLUSH_WIRE_SIZE: usize = 2; // magic(1) + type(1)
pub const ACK_WIRE_SIZE: usize = 18; // magic(1) + type(1) + symbol(8) + user_id(4) + order_id(4)
pub const CANCEL_ACK_WIRE_SIZE: usize = 18; // Same as ACK
pub const TRADE_WIRE_SIZE: usize = 34; // magic(1) + type(1) + symbol(8) + buy_uid(4) + buy_oid(4) + sell_uid(4) + sell_oid(4) + price(4) + qty(4)
pub const TOP_OF_BOOK_WIRE_SIZE: usize = 20; // magic(1) + type(1) + symbol(8) + side(1) + price(4) + qty(4) + pad(1)

// ============================================================================
// Input Message Encoding
// ============================================================================

/// Encode input message to binary format
pub fn encode(message: *const msg.InputMsg, buf: []u8) codec.CodecError!usize {
    return switch (message.msg_type) {
        .new_order => encodeNewOrder(&message.data.new_order, buf),
        .cancel => encodeCancel(&message.data.cancel, buf),
        .flush => encodeFlush(buf),
    };
}

fn encodeNewOrder(order: *const msg.NewOrderMsg, buf: []u8) codec.CodecError!usize {
    if (buf.len < NEW_ORDER_WIRE_SIZE) return codec.CodecError.BufferTooSmall;

    var pos: usize = 0;

    // Header
    buf[pos] = MAGIC;
    pos += 1;
    buf[pos] = MSG_NEW_ORDER;
    pos += 1;

    // user_id (network byte order)
    writeU32Big(buf[pos..][0..4], order.user_id);
    pos += 4;

    // symbol (8 bytes, null-padded)
    @memcpy(buf[pos..][0..msg.MAX_SYMBOL_LENGTH], &order.symbol);
    pos += msg.MAX_SYMBOL_LENGTH;

    // price
    writeU32Big(buf[pos..][0..4], order.price);
    pos += 4;

    // quantity
    writeU32Big(buf[pos..][0..4], order.quantity);
    pos += 4;

    // side
    buf[pos] = @intFromEnum(order.side);
    pos += 1;

    // user_order_id
    writeU32Big(buf[pos..][0..4], order.user_order_id);
    pos += 4;

    return pos;
}

fn encodeCancel(cancel: *const msg.CancelMsg, buf: []u8) codec.CodecError!usize {
    if (buf.len < CANCEL_WIRE_SIZE) return codec.CodecError.BufferTooSmall;

    var pos: usize = 0;

    buf[pos] = MAGIC;
    pos += 1;
    buf[pos] = MSG_CANCEL;
    pos += 1;

    writeU32Big(buf[pos..][0..4], cancel.user_id);
    pos += 4;

    writeU32Big(buf[pos..][0..4], cancel.user_order_id);
    pos += 4;

    return pos;
}

fn encodeFlush(buf: []u8) codec.CodecError!usize {
    if (buf.len < FLUSH_WIRE_SIZE) return codec.CodecError.BufferTooSmall;

    buf[0] = MAGIC;
    buf[1] = MSG_FLUSH;

    return FLUSH_WIRE_SIZE;
}

// ============================================================================
// Input Message Decoding
// ============================================================================

/// Decode input message from binary format
pub fn decode(data: []const u8) codec.CodecError!codec.DecodeResult {
    if (data.len < 2) return codec.CodecError.IncompleteMessage;
    if (data[0] != MAGIC) return codec.CodecError.InvalidMagic;

    const msg_type = data[1];

    var result: codec.DecodeResult = undefined;

    switch (msg_type) {
        MSG_NEW_ORDER => {
            if (data.len < NEW_ORDER_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            result.message = decodeNewOrder(data);
            result.bytes_consumed = NEW_ORDER_WIRE_SIZE;
        },
        MSG_CANCEL => {
            if (data.len < CANCEL_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            result.message = decodeCancel(data);
            result.bytes_consumed = CANCEL_WIRE_SIZE;
        },
        MSG_FLUSH => {
            result.message = .{
                .msg_type = .flush,
                .data = .{ .flush = .{} },
            };
            result.bytes_consumed = FLUSH_WIRE_SIZE;
        },
        else => return codec.CodecError.UnknownMessageType,
    }

    return result;
}

fn decodeNewOrder(data: []const u8) msg.InputMsg {
    var pos: usize = 2; // Skip magic + type

    const user_id = readU32Big(data[pos..][0..4]);
    pos += 4;

    var symbol: msg.Symbol = undefined;
    @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
    pos += msg.MAX_SYMBOL_LENGTH;

    const price = readU32Big(data[pos..][0..4]);
    pos += 4;

    const quantity = readU32Big(data[pos..][0..4]);
    pos += 4;

    const side: msg.Side = @enumFromInt(data[pos]);
    pos += 1;

    const user_order_id = readU32Big(data[pos..][0..4]);

    return .{
        .msg_type = .new_order,
        .data = .{ .new_order = .{
            .user_id = user_id,
            .symbol = symbol,
            .price = price,
            .quantity = quantity,
            .side = side,
            .user_order_id = user_order_id,
        } },
    };
}

fn decodeCancel(data: []const u8) msg.InputMsg {
    var pos: usize = 2; // Skip magic + type

    const user_id = readU32Big(data[pos..][0..4]);
    pos += 4;

    const user_order_id = readU32Big(data[pos..][0..4]);

    return .{
        .msg_type = .cancel,
        .data = .{ .cancel = .{
            .user_id = user_id,
            .user_order_id = user_order_id,
        } },
    };
}

// ============================================================================
// Output Message Encoding
// ============================================================================

/// Encode output message to binary format
pub fn encodeOutput(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    return switch (message.msg_type) {
        .ack => encodeAck(message, buf),
        .trade => encodeTrade(message, buf),
        .top_of_book => encodeTopOfBook(message, buf),
        .cancel_ack => encodeCancelAck(message, buf),
        .reject => encodeReject(message, buf),
    };
}

fn encodeAck(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    if (buf.len < ACK_WIRE_SIZE) return codec.CodecError.BufferTooSmall;

    var pos: usize = 0;

    buf[pos] = MAGIC;
    pos += 1;
    buf[pos] = MSG_ACK;
    pos += 1;

    @memcpy(buf[pos..][0..msg.MAX_SYMBOL_LENGTH], &message.symbol);
    pos += msg.MAX_SYMBOL_LENGTH;

    writeU32Big(buf[pos..][0..4], message.data.ack.user_id);
    pos += 4;

    writeU32Big(buf[pos..][0..4], message.data.ack.user_order_id);
    pos += 4;

    return pos;
}

fn encodeTrade(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    if (buf.len < TRADE_WIRE_SIZE) return codec.CodecError.BufferTooSmall;

    const t = &message.data.trade;
    var pos: usize = 0;

    buf[pos] = MAGIC;
    pos += 1;
    buf[pos] = MSG_TRADE;
    pos += 1;

    @memcpy(buf[pos..][0..msg.MAX_SYMBOL_LENGTH], &message.symbol);
    pos += msg.MAX_SYMBOL_LENGTH;

    writeU32Big(buf[pos..][0..4], t.buy_user_id);
    pos += 4;
    writeU32Big(buf[pos..][0..4], t.buy_order_id);
    pos += 4;
    writeU32Big(buf[pos..][0..4], t.sell_user_id);
    pos += 4;
    writeU32Big(buf[pos..][0..4], t.sell_order_id);
    pos += 4;
    writeU32Big(buf[pos..][0..4], t.price);
    pos += 4;
    writeU32Big(buf[pos..][0..4], t.quantity);
    pos += 4;

    return pos;
}

fn encodeTopOfBook(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    if (buf.len < TOP_OF_BOOK_WIRE_SIZE) return codec.CodecError.BufferTooSmall;

    const tob = &message.data.top_of_book;
    var pos: usize = 0;

    buf[pos] = MAGIC;
    pos += 1;
    buf[pos] = MSG_TOP_OF_BOOK;
    pos += 1;

    @memcpy(buf[pos..][0..msg.MAX_SYMBOL_LENGTH], &message.symbol);
    pos += msg.MAX_SYMBOL_LENGTH;

    buf[pos] = @intFromEnum(tob.side);
    pos += 1;

    writeU32Big(buf[pos..][0..4], tob.price);
    pos += 4;

    writeU32Big(buf[pos..][0..4], tob.quantity);
    pos += 4;

    return pos;
}

fn encodeCancelAck(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    if (buf.len < CANCEL_ACK_WIRE_SIZE) return codec.CodecError.BufferTooSmall;

    var pos: usize = 0;

    buf[pos] = MAGIC;
    pos += 1;
    buf[pos] = MSG_CANCEL_ACK;
    pos += 1;

    @memcpy(buf[pos..][0..msg.MAX_SYMBOL_LENGTH], &message.symbol);
    pos += msg.MAX_SYMBOL_LENGTH;

    writeU32Big(buf[pos..][0..4], message.data.cancel_ack.user_id);
    pos += 4;

    writeU32Big(buf[pos..][0..4], message.data.cancel_ack.user_order_id);
    pos += 4;

    return pos;
}

fn encodeReject(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    // Reject not in original C spec - use similar format to Ack
    if (buf.len < 19) return codec.CodecError.BufferTooSmall;

    var pos: usize = 0;

    buf[pos] = MAGIC;
    pos += 1;
    buf[pos] = 'R';
    pos += 1;

    @memcpy(buf[pos..][0..msg.MAX_SYMBOL_LENGTH], &message.symbol);
    pos += msg.MAX_SYMBOL_LENGTH;

    writeU32Big(buf[pos..][0..4], message.data.reject.user_id);
    pos += 4;

    writeU32Big(buf[pos..][0..4], message.data.reject.user_order_id);
    pos += 4;

    buf[pos] = @intFromEnum(message.data.reject.reason);
    pos += 1;

    return pos;
}

// ============================================================================
// Output Message Decoding (for UDP responses)
// ============================================================================

/// Decode output message from binary format
pub fn decodeOutput(data: []const u8) codec.CodecError!codec.OutputDecodeResult {
    if (data.len < 2) return codec.CodecError.IncompleteMessage;
    if (data[0] != MAGIC) return codec.CodecError.InvalidMagic;

    const msg_type = data[1];
    var result: codec.OutputDecodeResult = undefined;

    switch (msg_type) {
        MSG_ACK => {
            if (data.len < ACK_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            var pos: usize = 2;

            var symbol: msg.Symbol = undefined;
            @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
            pos += msg.MAX_SYMBOL_LENGTH;

            result.message = msg.OutputMsg.makeAck(
                readU32Big(data[pos..][0..4]),
                readU32Big(data[pos + 4 ..][0..4]),
                symbol,
                0,
            );
            result.bytes_consumed = ACK_WIRE_SIZE;
        },
        MSG_TRADE => {
            if (data.len < TRADE_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            var pos: usize = 2;

            var symbol: msg.Symbol = undefined;
            @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
            pos += msg.MAX_SYMBOL_LENGTH;

            result.message = msg.OutputMsg.makeTrade(
                readU32Big(data[pos..][0..4]),
                readU32Big(data[pos + 4 ..][0..4]),
                readU32Big(data[pos + 8 ..][0..4]),
                readU32Big(data[pos + 12 ..][0..4]),
                readU32Big(data[pos + 16 ..][0..4]),
                readU32Big(data[pos + 20 ..][0..4]),
                symbol,
                0,
            );
            result.bytes_consumed = TRADE_WIRE_SIZE;
        },
        MSG_TOP_OF_BOOK => {
            if (data.len < TOP_OF_BOOK_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            var pos: usize = 2;

            var symbol: msg.Symbol = undefined;
            @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
            pos += msg.MAX_SYMBOL_LENGTH;

            const side: msg.Side = @enumFromInt(data[pos]);
            pos += 1;

            result.message = msg.OutputMsg.makeTopOfBook(
                symbol,
                side,
                readU32Big(data[pos..][0..4]),
                readU32Big(data[pos + 4 ..][0..4]),
            );
            result.bytes_consumed = TOP_OF_BOOK_WIRE_SIZE;
        },
        MSG_CANCEL_ACK => {
            if (data.len < CANCEL_ACK_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            var pos: usize = 2;

            var symbol: msg.Symbol = undefined;
            @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
            pos += msg.MAX_SYMBOL_LENGTH;

            result.message = msg.OutputMsg.makeCancelAck(
                readU32Big(data[pos..][0..4]),
                readU32Big(data[pos + 4 ..][0..4]),
                symbol,
                0,
            );
            result.bytes_consumed = CANCEL_ACK_WIRE_SIZE;
        },
        else => return codec.CodecError.UnknownMessageType,
    }

    return result;
}

// ============================================================================
// Big-Endian (Network Byte Order) Helpers
// ============================================================================

inline fn readU32Big(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

inline fn writeU32Big(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .big);
}

inline fn readU16Big(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

inline fn writeU16Big(bytes: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, bytes, value, .big);
}

// ============================================================================
// Tests
// ============================================================================

test "binary roundtrip - new order" {
    const order = msg.NewOrderMsg{
        .user_id = 42,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 100,
        .side = .buy,
        .symbol = msg.makeSymbol("IBM"),
    };

    const input = msg.InputMsg{
        .msg_type = .new_order,
        .data = .{ .new_order = order },
    };

    var buf: [256]u8 = undefined;
    const encoded_len = try encode(&input, &buf);

    try std.testing.expectEqual(@as(usize, NEW_ORDER_WIRE_SIZE), encoded_len);
    try std.testing.expectEqual(@as(u8, MAGIC), buf[0]);
    try std.testing.expectEqual(@as(u8, MSG_NEW_ORDER), buf[1]);

    const result = try decode(&buf);
    try std.testing.expectEqual(msg.InputMsgType.new_order, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 42), result.message.data.new_order.user_id);
    try std.testing.expectEqual(@as(u32, 5000), result.message.data.new_order.price);
}

test "binary network byte order" {
    // Test that we're encoding in big-endian
    var buf: [4]u8 = undefined;
    writeU32Big(&buf, 0x12345678);

    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x56), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x78), buf[3]);
}
