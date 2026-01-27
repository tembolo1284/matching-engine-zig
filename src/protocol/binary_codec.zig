//! Binary Protocol Codec
//!
//! Wire-format encoding/decoding for high-performance binary messaging.
//! All multi-byte integers are in network byte order (big-endian).
//!
//! Since Zig 0.15 doesn't allow arrays in packed structs, we use
//! manual byte-level encoding/decoding for exact wire format control.

const std = @import("std");
const msg = @import("message_types.zig");

// ============================================================================
// Protocol Constants
// ============================================================================

pub const BINARY_MAGIC: u8 = 0x4D;

pub const MSG_NEW_ORDER: u8 = 'N';
pub const MSG_CANCEL: u8 = 'C';
pub const MSG_FLUSH: u8 = 'F';

pub const MSG_ACK: u8 = 'A';
pub const MSG_CANCEL_ACK: u8 = 'X';
pub const MSG_TRADE: u8 = 'T';
pub const MSG_TOP_OF_BOOK: u8 = 'B';

pub const BINARY_SYMBOL_LEN: usize = 8;

// ============================================================================
// Wire Format Sizes
// ============================================================================

pub const SIZE_NEW_ORDER: usize = 27;
pub const SIZE_CANCEL: usize = 10;
pub const SIZE_FLUSH: usize = 2;
pub const SIZE_ACK: usize = 18;
pub const SIZE_CANCEL_ACK: usize = 18;
pub const SIZE_TRADE: usize = 34;
pub const SIZE_TOP_OF_BOOK: usize = 19;

// ============================================================================
// Codec Errors
// ============================================================================

pub const CodecError = error{
    BufferTooSmall,
    InvalidMagic,
    InvalidMessageType,
    InvalidSide,
    InvalidData,
};

// ============================================================================
// Decode Result
// ============================================================================

pub const DecodeResult = struct {
    message: msg.InputMsg,
    bytes_consumed: usize,
};

// ============================================================================
// Detection and Validation
// ============================================================================

pub fn isBinaryMessage(data: []const u8) bool {
    if (data.len < 2) return false;
    return data[0] == BINARY_MAGIC;
}

pub fn messageSize(msg_type: u8) usize {
    return switch (msg_type) {
        MSG_NEW_ORDER => SIZE_NEW_ORDER,
        MSG_CANCEL => SIZE_CANCEL,
        MSG_FLUSH => SIZE_FLUSH,
        MSG_ACK => SIZE_ACK,
        MSG_CANCEL_ACK => SIZE_CANCEL_ACK,
        MSG_TRADE => SIZE_TRADE,
        MSG_TOP_OF_BOOK => SIZE_TOP_OF_BOOK,
        else => 0,
    };
}

pub fn validate(data: []const u8) bool {
    if (data.len < 2) return false;
    if (data[0] != BINARY_MAGIC) return false;

    const expected = messageSize(data[1]);
    return expected > 0 and data.len >= expected;
}

// ============================================================================
// Input Decoding
// ============================================================================

pub fn decodeInput(data: []const u8) CodecError!DecodeResult {
    std.debug.assert(data.len >= 2);

    if (data[0] != BINARY_MAGIC) {
        return CodecError.InvalidMagic;
    }

    const msg_type = data[1];

    return switch (msg_type) {
        MSG_NEW_ORDER => decodeNewOrder(data),
        MSG_CANCEL => decodeCancel(data),
        MSG_FLUSH => decodeFlush(data),
        else => CodecError.InvalidMessageType,
    };
}

fn decodeNewOrder(data: []const u8) CodecError!DecodeResult {
    if (data.len < SIZE_NEW_ORDER) {
        return CodecError.BufferTooSmall;
    }

    // Wire format (27 bytes):
    //   0:  magic
    //   1:  msg_type 'N'
    //   2-5:  user_id (big-endian)
    //   6-13: symbol (8 bytes)
    //   14-17: price (big-endian)
    //   18-21: quantity (big-endian)
    //   22: side 'B'/'S'
    //   23-26: user_order_id (big-endian)

    const side_byte = data[22];
    if (side_byte != 'B' and side_byte != 'S') {
        return CodecError.InvalidSide;
    }

    var result: msg.InputMsg = undefined;
    @memset(std.mem.asBytes(&result), 0);

    result.type = .new_order;
    result.data.new_order.user_id = std.mem.readInt(u32, data[2..6], .big);
    result.data.new_order.user_order_id = std.mem.readInt(u32, data[23..27], .big);
    result.data.new_order.price = std.mem.readInt(u32, data[14..18], .big);
    result.data.new_order.quantity = std.mem.readInt(u32, data[18..22], .big);
    result.data.new_order.side = if (side_byte == 'B') .buy else .sell;

    @memcpy(result.data.new_order.symbol[0..BINARY_SYMBOL_LEN], data[6..14]);
    @memset(result.data.new_order.symbol[BINARY_SYMBOL_LEN..], 0);

    std.debug.assert(result.type == .new_order);

    return DecodeResult{
        .message = result,
        .bytes_consumed = SIZE_NEW_ORDER,
    };
}

fn decodeCancel(data: []const u8) CodecError!DecodeResult {
    if (data.len < SIZE_CANCEL) {
        return CodecError.BufferTooSmall;
    }

    // Wire format (10 bytes):
    //   0: magic
    //   1: msg_type 'C'
    //   2-5: user_id (big-endian)
    //   6-9: user_order_id (big-endian)

    var result: msg.InputMsg = undefined;
    @memset(std.mem.asBytes(&result), 0);

    result.type = .cancel;
    result.data.cancel.user_id = std.mem.readInt(u32, data[2..6], .big);
    result.data.cancel.user_order_id = std.mem.readInt(u32, data[6..10], .big);

    std.debug.assert(result.type == .cancel);

    return DecodeResult{
        .message = result,
        .bytes_consumed = SIZE_CANCEL,
    };
}

fn decodeFlush(data: []const u8) CodecError!DecodeResult {
    if (data.len < SIZE_FLUSH) {
        return CodecError.BufferTooSmall;
    }

    // Wire format (2 bytes):
    //   0: magic
    //   1: msg_type 'F'

    var result: msg.InputMsg = undefined;
    @memset(std.mem.asBytes(&result), 0);

    result.type = .flush;

    std.debug.assert(result.type == .flush);

    return DecodeResult{
        .message = result,
        .bytes_consumed = SIZE_FLUSH,
    };
}

// ============================================================================
// Output Encoding
// ============================================================================

pub fn encodeOutput(output: *const msg.OutputMsg, buf: []u8) CodecError!usize {
    std.debug.assert(buf.len >= SIZE_TRADE); // Largest message

    return switch (output.type) {
        .ack => encodeAck(&output.data.ack, buf),
        .cancel_ack => encodeCancelAck(&output.data.cancel_ack, buf),
        .trade => encodeTrade(&output.data.trade, buf),
        .top_of_book => encodeTopOfBook(&output.data.top_of_book, buf),
    };
}

fn encodeAck(ack: *const msg.AckMsg, buf: []u8) CodecError!usize {
    if (buf.len < SIZE_ACK) {
        return CodecError.BufferTooSmall;
    }

    // Wire format (18 bytes):
    //   0: magic
    //   1: msg_type 'A'
    //   2-9: symbol (8 bytes)
    //   10-13: user_id (big-endian)
    //   14-17: user_order_id (big-endian)

    buf[0] = BINARY_MAGIC;
    buf[1] = MSG_ACK;
    @memcpy(buf[2..10], ack.symbol[0..BINARY_SYMBOL_LEN]);
    std.mem.writeInt(u32, buf[10..14], ack.user_id, .big);
    std.mem.writeInt(u32, buf[14..18], ack.user_order_id, .big);

    return SIZE_ACK;
}

fn encodeCancelAck(cancel_ack: *const msg.CancelAckMsg, buf: []u8) CodecError!usize {
    if (buf.len < SIZE_CANCEL_ACK) {
        return CodecError.BufferTooSmall;
    }

    // Wire format (18 bytes):
    //   0: magic
    //   1: msg_type 'X'
    //   2-9: symbol (8 bytes)
    //   10-13: user_id (big-endian)
    //   14-17: user_order_id (big-endian)

    buf[0] = BINARY_MAGIC;
    buf[1] = MSG_CANCEL_ACK;
    @memcpy(buf[2..10], cancel_ack.symbol[0..BINARY_SYMBOL_LEN]);
    std.mem.writeInt(u32, buf[10..14], cancel_ack.user_id, .big);
    std.mem.writeInt(u32, buf[14..18], cancel_ack.user_order_id, .big);

    return SIZE_CANCEL_ACK;
}

fn encodeTrade(trade: *const msg.TradeMsg, buf: []u8) CodecError!usize {
    if (buf.len < SIZE_TRADE) {
        return CodecError.BufferTooSmall;
    }

    // Wire format (34 bytes):
    //   0: magic
    //   1: msg_type 'T'
    //   2-9: symbol (8 bytes)
    //   10-13: user_id_buy (big-endian)
    //   14-17: user_order_id_buy (big-endian)
    //   18-21: user_id_sell (big-endian)
    //   22-25: user_order_id_sell (big-endian)
    //   26-29: price (big-endian)
    //   30-33: quantity (big-endian)

    buf[0] = BINARY_MAGIC;
    buf[1] = MSG_TRADE;
    @memcpy(buf[2..10], trade.symbol[0..BINARY_SYMBOL_LEN]);
    std.mem.writeInt(u32, buf[10..14], trade.user_id_buy, .big);
    std.mem.writeInt(u32, buf[14..18], trade.user_order_id_buy, .big);
    std.mem.writeInt(u32, buf[18..22], trade.user_id_sell, .big);
    std.mem.writeInt(u32, buf[22..26], trade.user_order_id_sell, .big);
    std.mem.writeInt(u32, buf[26..30], trade.price, .big);
    std.mem.writeInt(u32, buf[30..34], trade.quantity, .big);

    return SIZE_TRADE;
}

fn encodeTopOfBook(tob: *const msg.TopOfBookMsg, buf: []u8) CodecError!usize {
    if (buf.len < SIZE_TOP_OF_BOOK) {
        return CodecError.BufferTooSmall;
    }

    // Wire format (19 bytes):
    //   0: magic
    //   1: msg_type 'B'
    //   2-9: symbol (8 bytes)
    //   10: side 'B'/'S'
    //   11-14: price (big-endian)
    //   15-18: quantity (big-endian)

    buf[0] = BINARY_MAGIC;
    buf[1] = MSG_TOP_OF_BOOK;
    @memcpy(buf[2..10], tob.symbol[0..BINARY_SYMBOL_LEN]);
    buf[10] = @intFromEnum(tob.side);
    std.mem.writeInt(u32, buf[11..15], tob.price, .big);
    std.mem.writeInt(u32, buf[15..19], tob.total_quantity, .big);

    return SIZE_TOP_OF_BOOK;
}

// ============================================================================
// Input Encoding (for clients/testing)
// ============================================================================

pub fn encodeNewOrder(
    user_id: u32,
    user_order_id: u32,
    symbol: []const u8,
    price: u32,
    quantity: u32,
    side: msg.Side,
    buf: []u8,
) CodecError!usize {
    if (buf.len < SIZE_NEW_ORDER) {
        return CodecError.BufferTooSmall;
    }

    std.debug.assert(symbol.len > 0);

    buf[0] = BINARY_MAGIC;
    buf[1] = MSG_NEW_ORDER;
    std.mem.writeInt(u32, buf[2..6], user_id, .big);

    // Symbol: copy and zero-pad
    @memset(buf[6..14], 0);
    const copy_len = @min(symbol.len, BINARY_SYMBOL_LEN);
    @memcpy(buf[6..][0..copy_len], symbol[0..copy_len]);

    std.mem.writeInt(u32, buf[14..18], price, .big);
    std.mem.writeInt(u32, buf[18..22], quantity, .big);
    buf[22] = @intFromEnum(side);
    std.mem.writeInt(u32, buf[23..27], user_order_id, .big);

    return SIZE_NEW_ORDER;
}

pub fn encodeCancel(
    user_id: u32,
    user_order_id: u32,
    buf: []u8,
) CodecError!usize {
    if (buf.len < SIZE_CANCEL) {
        return CodecError.BufferTooSmall;
    }

    buf[0] = BINARY_MAGIC;
    buf[1] = MSG_CANCEL;
    std.mem.writeInt(u32, buf[2..6], user_id, .big);
    std.mem.writeInt(u32, buf[6..10], user_order_id, .big);

    return SIZE_CANCEL;
}

pub fn encodeFlush(buf: []u8) CodecError!usize {
    if (buf.len < SIZE_FLUSH) {
        return CodecError.BufferTooSmall;
    }

    buf[0] = BINARY_MAGIC;
    buf[1] = MSG_FLUSH;

    return SIZE_FLUSH;
}

// ============================================================================
// Tests
// ============================================================================

test "wire format sizes" {
    try std.testing.expectEqual(@as(usize, 27), SIZE_NEW_ORDER);
    try std.testing.expectEqual(@as(usize, 10), SIZE_CANCEL);
    try std.testing.expectEqual(@as(usize, 2), SIZE_FLUSH);
    try std.testing.expectEqual(@as(usize, 18), SIZE_ACK);
    try std.testing.expectEqual(@as(usize, 18), SIZE_CANCEL_ACK);
    try std.testing.expectEqual(@as(usize, 34), SIZE_TRADE);
    try std.testing.expectEqual(@as(usize, 19), SIZE_TOP_OF_BOOK);
}

test "is binary message" {
    const valid = [_]u8{ BINARY_MAGIC, MSG_NEW_ORDER, 0, 0 };
    try std.testing.expect(isBinaryMessage(&valid));

    const invalid = [_]u8{ 0x00, MSG_NEW_ORDER, 0, 0 };
    try std.testing.expect(!isBinaryMessage(&invalid));

    const too_short = [_]u8{BINARY_MAGIC};
    try std.testing.expect(!isBinaryMessage(&too_short));
}

test "encode and decode new order" {
    var buf: [64]u8 = undefined;

    const encoded_len = try encodeNewOrder(1, 100, "IBM", 150, 1000, .buy, &buf);

    try std.testing.expectEqual(@as(usize, 27), encoded_len);
    try std.testing.expectEqual(BINARY_MAGIC, buf[0]);
    try std.testing.expectEqual(MSG_NEW_ORDER, buf[1]);

    const result = try decodeInput(buf[0..encoded_len]);

    try std.testing.expectEqual(msg.InputMsgType.new_order, result.message.type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.new_order.user_id);
    try std.testing.expectEqual(@as(u32, 100), result.message.data.new_order.user_order_id);
    try std.testing.expectEqual(@as(u32, 150), result.message.data.new_order.price);
    try std.testing.expectEqual(@as(u32, 1000), result.message.data.new_order.quantity);
    try std.testing.expectEqual(msg.Side.buy, result.message.data.new_order.side);
    try std.testing.expectEqualStrings("IBM", msg.symbolSlice(&result.message.data.new_order.symbol));
}

test "encode and decode cancel" {
    var buf: [64]u8 = undefined;

    const encoded_len = try encodeCancel(1, 100, &buf);

    try std.testing.expectEqual(@as(usize, 10), encoded_len);

    const result = try decodeInput(buf[0..encoded_len]);

    try std.testing.expectEqual(msg.InputMsgType.cancel, result.message.type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.cancel.user_id);
    try std.testing.expectEqual(@as(u32, 100), result.message.data.cancel.user_order_id);
}

test "encode and decode flush" {
    var buf: [64]u8 = undefined;

    const encoded_len = try encodeFlush(&buf);

    try std.testing.expectEqual(@as(usize, 2), encoded_len);

    const result = try decodeInput(buf[0..encoded_len]);

    try std.testing.expectEqual(msg.InputMsgType.flush, result.message.type);
}

test "encode output ack" {
    var buf: [64]u8 = undefined;

    const ack = msg.makeAckMsg("AAPL", 1, 100);
    const encoded_len = try encodeOutput(&ack, &buf);

    try std.testing.expectEqual(@as(usize, 18), encoded_len);
    try std.testing.expectEqual(BINARY_MAGIC, buf[0]);
    try std.testing.expectEqual(MSG_ACK, buf[1]);
}

test "encode output trade" {
    var buf: [64]u8 = undefined;

    const trade = msg.makeTradeMsg("IBM", 1, 100, 2, 200, 150, 500);
    const encoded_len = try encodeOutput(&trade, &buf);

    try std.testing.expectEqual(@as(usize, 34), encoded_len);
    try std.testing.expectEqual(BINARY_MAGIC, buf[0]);
    try std.testing.expectEqual(MSG_TRADE, buf[1]);
}

test "invalid magic returns error" {
    const invalid = [_]u8{ 0x00, MSG_NEW_ORDER } ++ [_]u8{0} ** 25;
    const result = decodeInput(&invalid);
    try std.testing.expectError(CodecError.InvalidMagic, result);
}

test "invalid message type returns error" {
    const invalid = [_]u8{ BINARY_MAGIC, 0xFF } ++ [_]u8{0} ** 25;
    const result = decodeInput(&invalid);
    try std.testing.expectError(CodecError.InvalidMessageType, result);
}

test "buffer too small returns error" {
    const short = [_]u8{ BINARY_MAGIC, MSG_NEW_ORDER };
    const result = decodeInput(&short);
    try std.testing.expectError(CodecError.BufferTooSmall, result);
}

test "message size lookup" {
    try std.testing.expectEqual(@as(usize, 27), messageSize(MSG_NEW_ORDER));
    try std.testing.expectEqual(@as(usize, 10), messageSize(MSG_CANCEL));
    try std.testing.expectEqual(@as(usize, 2), messageSize(MSG_FLUSH));
    try std.testing.expectEqual(@as(usize, 18), messageSize(MSG_ACK));
    try std.testing.expectEqual(@as(usize, 34), messageSize(MSG_TRADE));
    try std.testing.expectEqual(@as(usize, 19), messageSize(MSG_TOP_OF_BOOK));
    try std.testing.expectEqual(@as(usize, 0), messageSize(0xFF));
}
