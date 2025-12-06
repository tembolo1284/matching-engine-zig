//! Binary protocol codec - matches C specification exactly.
//!
//! Wire format:
//! ```
//!   Byte 0:     Magic (0x4D = 'M')
//!   Byte 1:     Message type (ASCII char)
//!   Byte 2+:    Payload (type-specific, network byte order)
//! ```
//!
//! All multi-byte integers are BIG-ENDIAN (network byte order).
//! Structs are packed (no padding between fields).
//!
//! Message sizes (including 2-byte header):
//! - New Order:   27 bytes
//! - Cancel:      10 bytes
//! - Flush:        2 bytes
//! - Ack:         18 bytes
//! - Cancel Ack:  18 bytes
//! - Trade:       34 bytes
//! - Top of Book: 20 bytes
//! - Reject:      19 bytes

const std = @import("std");
const msg = @import("message_types.zig");
const codec = @import("codec.zig");

// ============================================================================
// Protocol Constants
// ============================================================================

/// Magic byte identifying binary protocol.
pub const MAGIC: u8 = 0x4D; // 'M'

/// Header size (magic + type).
pub const HEADER_SIZE: usize = 2;

// === Message Type Bytes ===
pub const MSG_NEW_ORDER: u8 = 'N'; // 0x4E
pub const MSG_CANCEL: u8 = 'C'; // 0x43
pub const MSG_FLUSH: u8 = 'F'; // 0x46
pub const MSG_ACK: u8 = 'A'; // 0x41
pub const MSG_CANCEL_ACK: u8 = 'X'; // 0x58
pub const MSG_TRADE: u8 = 'T'; // 0x54
pub const MSG_TOP_OF_BOOK: u8 = 'B'; // 0x42
pub const MSG_REJECT: u8 = 'R'; // 0x52

// === Wire Sizes (total including header) ===
/// New Order: magic(1) + type(1) + user_id(4) + symbol(8) + price(4) + qty(4) + side(1) + order_id(4) = 27
pub const NEW_ORDER_WIRE_SIZE: usize = 27;

/// Cancel: magic(1) + type(1) + user_id(4) + symbol(8) + order_id(4) = 18
pub const CANCEL_WIRE_SIZE: usize = 18;

/// Flush: magic(1) + type(1) = 2
pub const FLUSH_WIRE_SIZE: usize = 2;

/// Ack: magic(1) + type(1) + symbol(8) + user_id(4) + order_id(4) = 18
pub const ACK_WIRE_SIZE: usize = 18;

/// Cancel Ack: same as Ack = 18
pub const CANCEL_ACK_WIRE_SIZE: usize = 18;

/// Trade: magic(1) + type(1) + symbol(8) + buy_uid(4) + buy_oid(4) + sell_uid(4) + sell_oid(4) + price(4) + qty(4) = 34
pub const TRADE_WIRE_SIZE: usize = 34;

/// Top of Book: magic(1) + type(1) + symbol(8) + side(1) + price(4) + qty(4) + pad(1) = 20
pub const TOP_OF_BOOK_WIRE_SIZE: usize = 20;

/// Reject: magic(1) + type(1) + symbol(8) + user_id(4) + order_id(4) + reason(1) = 19
pub const REJECT_WIRE_SIZE: usize = 19;

// Compile-time validation
comptime {
    std.debug.assert(NEW_ORDER_WIRE_SIZE == HEADER_SIZE + 4 + msg.MAX_SYMBOL_LENGTH + 4 + 4 + 1 + 4);
    std.debug.assert(CANCEL_WIRE_SIZE == HEADER_SIZE + 4 + msg.MAX_SYMBOL_LENGTH + 4);
    std.debug.assert(FLUSH_WIRE_SIZE == HEADER_SIZE);
    std.debug.assert(ACK_WIRE_SIZE == HEADER_SIZE + msg.MAX_SYMBOL_LENGTH + 4 + 4);
    std.debug.assert(TRADE_WIRE_SIZE == HEADER_SIZE + msg.MAX_SYMBOL_LENGTH + 4 + 4 + 4 + 4 + 4 + 4);
}

// ============================================================================
// Input Message Encoding
// ============================================================================

/// Encode input message to binary format.
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

    std.debug.assert(pos == NEW_ORDER_WIRE_SIZE);
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

    @memcpy(buf[pos..][0..msg.MAX_SYMBOL_LENGTH], &cancel.symbol);
    pos += msg.MAX_SYMBOL_LENGTH;

    writeU32Big(buf[pos..][0..4], cancel.user_order_id);
    pos += 4;

    std.debug.assert(pos == CANCEL_WIRE_SIZE);
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

/// Decode input message from binary format.
pub fn decode(data: []const u8) codec.CodecError!codec.DecodeResult {
    if (data.len < HEADER_SIZE) return codec.CodecError.IncompleteMessage;
    if (data[0] != MAGIC) return codec.CodecError.InvalidMagic;

    const msg_type = data[1];

    return switch (msg_type) {
        MSG_NEW_ORDER => {
            if (data.len < NEW_ORDER_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            return .{
                .message = decodeNewOrder(data),
                .bytes_consumed = NEW_ORDER_WIRE_SIZE,
            };
        },
        MSG_CANCEL => {
            if (data.len < CANCEL_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            return .{
                .message = decodeCancel(data),
                .bytes_consumed = CANCEL_WIRE_SIZE,
            };
        },
        MSG_FLUSH => {
            return .{
                .message = .{
                    .msg_type = .flush,
                    .data = .{ .flush = .{} },
                },
                .bytes_consumed = FLUSH_WIRE_SIZE,
            };
        },
        else => codec.CodecError.UnknownMessageType,
    };
}

fn decodeNewOrder(data: []const u8) msg.InputMsg {
    std.debug.assert(data.len >= NEW_ORDER_WIRE_SIZE);
    std.debug.assert(data[0] == MAGIC and data[1] == MSG_NEW_ORDER);

    var pos: usize = HEADER_SIZE;

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
            .user_order_id = user_order_id,
            .price = price,
            .quantity = quantity,
            .side = side,
            .symbol = symbol,
        } },
    };
}

fn decodeCancel(data: []const u8) msg.InputMsg {
    std.debug.assert(data.len >= CANCEL_WIRE_SIZE);
    std.debug.assert(data[0] == MAGIC and data[1] == MSG_CANCEL);

    var pos: usize = HEADER_SIZE;

    const user_id = readU32Big(data[pos..][0..4]);
    pos += 4;
 
    var symbol: msg.Symbol = undefined;
    @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
    pos += msg.MAX_SYMBOL_LENGTH;

    const user_order_id = readU32Big(data[pos..][0..4]);

    return .{
        .msg_type = .cancel,
        .data = .{ .cancel = .{
            .user_id = user_id,
            .user_order_id = user_order_id,
            .symbol = symbol,
        } },
    };
}

// ============================================================================
// Output Message Encoding
// ============================================================================

/// Encode output message to binary format.
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

    std.debug.assert(pos == ACK_WIRE_SIZE);
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

    std.debug.assert(pos == TRADE_WIRE_SIZE);
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

    // Padding byte for alignment
    buf[pos] = 0;
    pos += 1;

    std.debug.assert(pos == TOP_OF_BOOK_WIRE_SIZE);
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

    std.debug.assert(pos == CANCEL_ACK_WIRE_SIZE);
    return pos;
}

fn encodeReject(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    if (buf.len < REJECT_WIRE_SIZE) return codec.CodecError.BufferTooSmall;

    var pos: usize = 0;

    buf[pos] = MAGIC;
    pos += 1;
    buf[pos] = MSG_REJECT;
    pos += 1;

    @memcpy(buf[pos..][0..msg.MAX_SYMBOL_LENGTH], &message.symbol);
    pos += msg.MAX_SYMBOL_LENGTH;

    writeU32Big(buf[pos..][0..4], message.data.reject.user_id);
    pos += 4;

    writeU32Big(buf[pos..][0..4], message.data.reject.user_order_id);
    pos += 4;

    buf[pos] = @intFromEnum(message.data.reject.reason);
    pos += 1;

    std.debug.assert(pos == REJECT_WIRE_SIZE);
    return pos;
}

// ============================================================================
// Output Message Decoding
// ============================================================================

/// Decode output message from binary format.
pub fn decodeOutput(data: []const u8) codec.CodecError!codec.OutputDecodeResult {
    if (data.len < HEADER_SIZE) return codec.CodecError.IncompleteMessage;
    if (data[0] != MAGIC) return codec.CodecError.InvalidMagic;

    const msg_type = data[1];

    return switch (msg_type) {
        MSG_ACK => {
            if (data.len < ACK_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            return .{
                .message = decodeAckMsg(data),
                .bytes_consumed = ACK_WIRE_SIZE,
            };
        },
        MSG_TRADE => {
            if (data.len < TRADE_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            return .{
                .message = decodeTradeMsg(data),
                .bytes_consumed = TRADE_WIRE_SIZE,
            };
        },
        MSG_TOP_OF_BOOK => {
            if (data.len < TOP_OF_BOOK_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            return .{
                .message = decodeTopOfBookMsg(data),
                .bytes_consumed = TOP_OF_BOOK_WIRE_SIZE,
            };
        },
        MSG_CANCEL_ACK => {
            if (data.len < CANCEL_ACK_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            return .{
                .message = decodeCancelAckMsg(data),
                .bytes_consumed = CANCEL_ACK_WIRE_SIZE,
            };
        },
        MSG_REJECT => {
            if (data.len < REJECT_WIRE_SIZE) return codec.CodecError.IncompleteMessage;
            return .{
                .message = decodeRejectMsg(data),
                .bytes_consumed = REJECT_WIRE_SIZE,
            };
        },
        else => codec.CodecError.UnknownMessageType,
    };
}

fn decodeAckMsg(data: []const u8) msg.OutputMsg {
    var pos: usize = HEADER_SIZE;

    var symbol: msg.Symbol = undefined;
    @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
    pos += msg.MAX_SYMBOL_LENGTH;

    return msg.OutputMsg.makeAck(
        readU32Big(data[pos..][0..4]),
        readU32Big(data[pos + 4 ..][0..4]),
        symbol,
        0,
    );
}

fn decodeTradeMsg(data: []const u8) msg.OutputMsg {
    var pos: usize = HEADER_SIZE;

    var symbol: msg.Symbol = undefined;
    @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
    pos += msg.MAX_SYMBOL_LENGTH;

    return msg.OutputMsg.makeTrade(
        readU32Big(data[pos..][0..4]),
        readU32Big(data[pos + 4 ..][0..4]),
        readU32Big(data[pos + 8 ..][0..4]),
        readU32Big(data[pos + 12 ..][0..4]),
        readU32Big(data[pos + 16 ..][0..4]),
        readU32Big(data[pos + 20 ..][0..4]),
        symbol,
        0,
    );
}

fn decodeTopOfBookMsg(data: []const u8) msg.OutputMsg {
    var pos: usize = HEADER_SIZE;

    var symbol: msg.Symbol = undefined;
    @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
    pos += msg.MAX_SYMBOL_LENGTH;

    const side: msg.Side = @enumFromInt(data[pos]);
    pos += 1;

    return msg.OutputMsg.makeTopOfBook(
        symbol,
        side,
        readU32Big(data[pos..][0..4]),
        readU32Big(data[pos + 4 ..][0..4]),
    );
}

fn decodeCancelAckMsg(data: []const u8) msg.OutputMsg {
    var pos: usize = HEADER_SIZE;

    var symbol: msg.Symbol = undefined;
    @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
    pos += msg.MAX_SYMBOL_LENGTH;

    return msg.OutputMsg.makeCancelAck(
        readU32Big(data[pos..][0..4]),
        readU32Big(data[pos + 4 ..][0..4]),
        symbol,
        0,
    );
}

fn decodeRejectMsg(data: []const u8) msg.OutputMsg {
    var pos: usize = HEADER_SIZE;

    var symbol: msg.Symbol = undefined;
    @memcpy(&symbol, data[pos..][0..msg.MAX_SYMBOL_LENGTH]);
    pos += msg.MAX_SYMBOL_LENGTH;

    return msg.OutputMsg.makeReject(
        readU32Big(data[pos..][0..4]),
        readU32Big(data[pos + 4 ..][0..4]),
        @enumFromInt(data[pos + 8]),
        symbol,
        0,
    );
}

// ============================================================================
// Network Byte Order Helpers
// ============================================================================

inline fn readU32Big(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

inline fn writeU32Big(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .big);
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

    try std.testing.expectEqual(NEW_ORDER_WIRE_SIZE, encoded_len);
    try std.testing.expectEqual(MAGIC, buf[0]);
    try std.testing.expectEqual(MSG_NEW_ORDER, buf[1]);

    const result = try decode(&buf);
    try std.testing.expectEqual(msg.InputMsgType.new_order, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 42), result.message.data.new_order.user_id);
    try std.testing.expectEqual(@as(u32, 5000), result.message.data.new_order.price);
    try std.testing.expectEqual(@as(u32, 100), result.message.data.new_order.quantity);
    try std.testing.expectEqual(msg.Side.buy, result.message.data.new_order.side);
}

test "binary roundtrip - cancel" {
    const input = msg.InputMsg.cancel(42, msg.makeSymbol("IBM"), 100);

    var buf: [256]u8 = undefined;
    const encoded_len = try encode(&input, &buf);

    try std.testing.expectEqual(CANCEL_WIRE_SIZE, encoded_len);

    const result = try decode(&buf);
    try std.testing.expectEqual(msg.InputMsgType.cancel, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 42), result.message.data.cancel.user_id);
    try std.testing.expectEqual(@as(u32, 100), result.message.data.cancel.user_order_id);
    try std.testing.expect(std.mem.eql(u8, "IBM", msg.symbolSlice(&result.message.data.cancel.symbol)));
}

test "binary roundtrip - trade" {
    const trade = msg.OutputMsg.makeTrade(1, 100, 2, 200, 5000, 50, msg.makeSymbol("IBM"), 42);

    var buf: [256]u8 = undefined;
    const encoded_len = try encodeOutput(&trade, &buf);

    try std.testing.expectEqual(TRADE_WIRE_SIZE, encoded_len);

    const result = try decodeOutput(&buf);
    try std.testing.expectEqual(msg.OutputMsgType.trade, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.trade.buy_user_id);
    try std.testing.expectEqual(@as(u32, 5000), result.message.data.trade.price);
}

test "binary roundtrip - reject" {
    const reject = msg.OutputMsg.makeReject(42, 100, .invalid_price, msg.makeSymbol("AAPL"), 5);

    var buf: [256]u8 = undefined;
    const encoded_len = try encodeOutput(&reject, &buf);

    try std.testing.expectEqual(REJECT_WIRE_SIZE, encoded_len);

    const result = try decodeOutput(&buf);
    try std.testing.expectEqual(msg.OutputMsgType.reject, result.message.msg_type);
    try std.testing.expectEqual(msg.RejectReason.invalid_price, result.message.data.reject.reason);
}

test "binary network byte order" {
    var buf: [4]u8 = undefined;
    writeU32Big(&buf, 0x12345678);

    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x56), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x78), buf[3]);
}

test "binary incomplete message" {
    const partial = [_]u8{ MAGIC, MSG_NEW_ORDER, 0x00, 0x00 };
    try std.testing.expectError(codec.CodecError.IncompleteMessage, decode(&partial));
}

test "binary invalid magic" {
    const invalid = [_]u8{ 0xFF, MSG_NEW_ORDER };
    try std.testing.expectError(codec.CodecError.InvalidMagic, decode(&invalid));
}

test "binary unknown message type" {
    const unknown = [_]u8{ MAGIC, 0xFF };
    try std.testing.expectError(codec.CodecError.UnknownMessageType, decode(&unknown));
}
