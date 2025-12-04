//! CSV protocol codec - human-readable, newline-delimited.
//!
//! Input formats:
//! ```
//!   New Order: N, userId, symbol, price, qty, side, userOrderId
//!   Cancel:    C, userId, userOrderId [, symbol]
//!   Flush:     F
//! ```
//!
//! Output formats:
//! ```
//!   Ack:       A, symbol, userId, userOrderId
//!   Trade:     T, symbol, buyUserId, buyOrderId, sellUserId, sellOrderId, price, qty
//!   TopOfBook: B, symbol, side, price, qty   (or "B, symbol, side, -, -" for empty)
//!   CancelAck: C, symbol, userId, userOrderId
//!   Reject:    R, symbol, userId, userOrderId, reason
//! ```
//!
//! Notes:
//! - Fields are comma-separated with optional whitespace
//! - Lines terminated by LF or CRLF
//! - Side: 'B'/'b' for buy, 'S'/'s' for sell

const std = @import("std");
const msg = @import("message_types.zig");
const codec = @import("codec.zig");

// ============================================================================
// Constants
// ============================================================================

/// Maximum line length.
const MAX_LINE_LENGTH: usize = 256;

/// Maximum fields per line.
const MAX_FIELDS: usize = 16;

// ============================================================================
// Line Parsing Result
// ============================================================================

/// Result of finding line end.
const LineEndResult = union(enum) {
    /// Found newline at position.
    found: usize,
    /// No newline found, but data ends (valid for last line).
    end_of_data,
    /// Need more data.
    incomplete,
};

// ============================================================================
// Input Message Decoding
// ============================================================================

/// Decode input message from CSV format.
pub fn decodeInput(data: []const u8) codec.CodecError!codec.DecodeResult {
    // Find line ending
    const line_info = findLineEnd(data);
    const line_len = switch (line_info) {
        .found => |pos| pos,
        .end_of_data => data.len,
        .incomplete => return codec.CodecError.IncompleteMessage,
    };

    if (line_len == 0) return codec.CodecError.MalformedMessage;

    const line = data[0..line_len];

    // Parse fields
    var fields: [MAX_FIELDS][]const u8 = undefined;
    const num_fields = splitFields(line, &fields);

    if (num_fields == 0) return codec.CodecError.MalformedMessage;

    const msg_type_str = codec.trim(fields[0]);
    if (msg_type_str.len == 0) return codec.CodecError.MalformedMessage;

    var result: codec.DecodeResult = undefined;
    result.bytes_consumed = calculateConsumed(data, line_len);

    switch (msg_type_str[0]) {
        'N' => result.message = try parseNewOrder(fields[0..num_fields]),
        'C' => result.message = try parseCancel(fields[0..num_fields]),
        'F' => result.message = msg.InputMsg.flush(),
        else => return codec.CodecError.UnknownMessageType,
    }

    return result;
}

fn parseNewOrder(fields: [][]const u8) codec.CodecError!msg.InputMsg {
    // N, userId, symbol, price, qty, side, userOrderId
    if (fields.len < 7) return codec.CodecError.IncompleteMessage;

    const user_id = codec.parseU32(codec.trim(fields[1])) orelse return codec.CodecError.InvalidField;
    const symbol_str = codec.trim(fields[2]);
    const price = codec.parseU32(codec.trim(fields[3])) orelse return codec.CodecError.InvalidField;
    const quantity = codec.parseU32(codec.trim(fields[4])) orelse return codec.CodecError.InvalidField;
    const side_str = codec.trim(fields[5]);
    const order_id = codec.parseU32(codec.trim(fields[6])) orelse return codec.CodecError.InvalidField;

    if (side_str.len == 0) return codec.CodecError.InvalidField;

    const side: msg.Side = switch (side_str[0]) {
        'B', 'b' => .buy,
        'S', 's' => .sell,
        else => return codec.CodecError.InvalidField,
    };

    return msg.InputMsg.newOrder(.{
        .user_id = user_id,
        .user_order_id = order_id,
        .price = price,
        .quantity = quantity,
        .side = side,
        .symbol = msg.makeSymbol(symbol_str),
    });
}

fn parseCancel(fields: [][]const u8) codec.CodecError!msg.InputMsg {
    // C, userId, userOrderId [, symbol]
    if (fields.len < 3) return codec.CodecError.IncompleteMessage;

    const user_id = codec.parseU32(codec.trim(fields[1])) orelse return codec.CodecError.InvalidField;
    const order_id = codec.parseU32(codec.trim(fields[2])) orelse return codec.CodecError.InvalidField;

    // Optional symbol hint
    if (fields.len >= 4) {
        const symbol_str = codec.trim(fields[3]);
        if (symbol_str.len > 0) {
            return msg.InputMsg.cancelWithSymbol(user_id, order_id, msg.makeSymbol(symbol_str));
        }
    }

    return msg.InputMsg.cancel(user_id, order_id);
}

// ============================================================================
// Input Message Encoding
// ============================================================================

/// Encode input message to CSV format.
pub fn encodeInput(message: *const msg.InputMsg, buf: []u8) codec.CodecError!usize {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (message.msg_type) {
        .new_order => {
            const o = &message.data.new_order;
            writer.print("N, {}, {s}, {}, {}, {c}, {}\n", .{
                o.user_id,
                msg.symbolSlice(&o.symbol),
                o.price,
                o.quantity,
                @intFromEnum(o.side),
                o.user_order_id,
            }) catch return codec.CodecError.BufferTooSmall;
        },
        .cancel => {
            const c = &message.data.cancel;
            if (c.hasSymbolHint()) {
                writer.print("C, {}, {}, {s}\n", .{
                    c.user_id,
                    c.user_order_id,
                    msg.symbolSlice(&c.symbol),
                }) catch return codec.CodecError.BufferTooSmall;
            } else {
                writer.print("C, {}, {}\n", .{
                    c.user_id,
                    c.user_order_id,
                }) catch return codec.CodecError.BufferTooSmall;
            }
        },
        .flush => {
            writer.print("F\n", .{}) catch return codec.CodecError.BufferTooSmall;
        },
    }

    return stream.pos;
}

// ============================================================================
// Output Message Decoding
// ============================================================================

/// Decode output message from CSV format.
pub fn decodeOutput(data: []const u8) codec.CodecError!codec.OutputDecodeResult {
    const line_info = findLineEnd(data);
    const line_len = switch (line_info) {
        .found => |pos| pos,
        .end_of_data => data.len,
        .incomplete => return codec.CodecError.IncompleteMessage,
    };

    if (line_len == 0) return codec.CodecError.MalformedMessage;

    const line = data[0..line_len];

    var fields: [MAX_FIELDS][]const u8 = undefined;
    const num_fields = splitFields(line, &fields);

    if (num_fields == 0) return codec.CodecError.MalformedMessage;

    const msg_type_str = codec.trim(fields[0]);
    if (msg_type_str.len == 0) return codec.CodecError.MalformedMessage;

    var result: codec.OutputDecodeResult = undefined;
    result.bytes_consumed = calculateConsumed(data, line_len);

    switch (msg_type_str[0]) {
        'A' => result.message = try parseAck(fields[0..num_fields]),
        'T' => result.message = try parseTrade(fields[0..num_fields]),
        'B' => result.message = try parseTopOfBook(fields[0..num_fields]),
        'C', 'X' => result.message = try parseCancelAck(fields[0..num_fields]),
        'R' => result.message = try parseReject(fields[0..num_fields]),
        else => return codec.CodecError.UnknownMessageType,
    }

    return result;
}

fn parseAck(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // A, symbol, userId, userOrderId
    if (fields.len < 4) return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeAck(
        codec.parseU32(codec.trim(fields[2])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(codec.trim(fields[3])) orelse return codec.CodecError.InvalidField,
        msg.makeSymbol(codec.trim(fields[1])),
        0,
    );
}

fn parseTrade(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // T, symbol, buyUserId, buyOrderId, sellUserId, sellOrderId, price, qty
    if (fields.len < 8) return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeTrade(
        codec.parseU32(codec.trim(fields[2])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(codec.trim(fields[3])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(codec.trim(fields[4])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(codec.trim(fields[5])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(codec.trim(fields[6])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(codec.trim(fields[7])) orelse return codec.CodecError.InvalidField,
        msg.makeSymbol(codec.trim(fields[1])),
        0,
    );
}

fn parseTopOfBook(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // B, symbol, side, price, qty
    if (fields.len < 5) return codec.CodecError.InvalidField;

    const side_str = codec.trim(fields[2]);
    if (side_str.len == 0) return codec.CodecError.InvalidField;

    const side: msg.Side = switch (side_str[0]) {
        'B', 'b' => .buy,
        'S', 's' => .sell,
        else => return codec.CodecError.InvalidField,
    };

    // Handle "-, -" for empty book
    const price_str = codec.trim(fields[3]);
    const qty_str = codec.trim(fields[4]);

    const price: u32 = if (price_str.len > 0 and price_str[0] == '-')
        0
    else
        codec.parseU32(price_str) orelse return codec.CodecError.InvalidField;

    const qty: u32 = if (qty_str.len > 0 and qty_str[0] == '-')
        0
    else
        codec.parseU32(qty_str) orelse return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeTopOfBook(
        msg.makeSymbol(codec.trim(fields[1])),
        side,
        price,
        qty,
    );
}

fn parseCancelAck(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // C/X, symbol, userId, userOrderId
    if (fields.len < 4) return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeCancelAck(
        codec.parseU32(codec.trim(fields[2])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(codec.trim(fields[3])) orelse return codec.CodecError.InvalidField,
        msg.makeSymbol(codec.trim(fields[1])),
        0,
    );
}

fn parseReject(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // R, symbol, userId, userOrderId, reason
    if (fields.len < 5) return codec.CodecError.InvalidField;

    const reason_code = codec.parseU32(codec.trim(fields[4])) orelse return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeReject(
        codec.parseU32(codec.trim(fields[2])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(codec.trim(fields[3])) orelse return codec.CodecError.InvalidField,
        @enumFromInt(@as(u8, @truncate(reason_code))),
        msg.makeSymbol(codec.trim(fields[1])),
        0,
    );
}

// ============================================================================
// Output Message Encoding
// ============================================================================

/// Encode output message to CSV format.
pub fn encodeOutput(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (message.msg_type) {
        .ack => {
            const a = &message.data.ack;
            writer.print("A, {s}, {}, {}\n", .{
                msg.symbolSlice(&message.symbol),
                a.user_id,
                a.user_order_id,
            }) catch return codec.CodecError.BufferTooSmall;
        },

        .trade => {
            const t = &message.data.trade;
            writer.print("T, {s}, {}, {}, {}, {}, {}, {}\n", .{
                msg.symbolSlice(&message.symbol),
                t.buy_user_id,
                t.buy_order_id,
                t.sell_user_id,
                t.sell_order_id,
                t.price,
                t.quantity,
            }) catch return codec.CodecError.BufferTooSmall;
        },

        .top_of_book => {
            const b = &message.data.top_of_book;
            if (b.isEmpty()) {
                writer.print("B, {s}, {c}, -, -\n", .{
                    msg.symbolSlice(&message.symbol),
                    @intFromEnum(b.side),
                }) catch return codec.CodecError.BufferTooSmall;
            } else {
                writer.print("B, {s}, {c}, {}, {}\n", .{
                    msg.symbolSlice(&message.symbol),
                    @intFromEnum(b.side),
                    b.price,
                    b.quantity,
                }) catch return codec.CodecError.BufferTooSmall;
            }
        },

        .cancel_ack => {
            const x = &message.data.cancel_ack;
            writer.print("C, {s}, {}, {}\n", .{
                msg.symbolSlice(&message.symbol),
                x.user_id,
                x.user_order_id,
            }) catch return codec.CodecError.BufferTooSmall;
        },

        .reject => {
            const r = &message.data.reject;
            writer.print("R, {s}, {}, {}, {}\n", .{
                msg.symbolSlice(&message.symbol),
                r.user_id,
                r.user_order_id,
                @intFromEnum(r.reason),
            }) catch return codec.CodecError.BufferTooSmall;
        },
    }

    return stream.pos;
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Find line ending in data.
fn findLineEnd(data: []const u8) LineEndResult {
    for (data, 0..) |c, i| {
        if (c == '\n') return .{ .found = i };
    }

    // No newline - check if this could be a complete message
    // (e.g., last line in a file without trailing newline)
    if (data.len > 0 and data.len < MAX_LINE_LENGTH) {
        // Could be complete if it looks like a valid message start
        if (data[0] == 'N' or data[0] == 'C' or data[0] == 'F' or
            data[0] == 'A' or data[0] == 'T' or data[0] == 'B' or
            data[0] == 'X' or data[0] == 'R')
        {
            return .end_of_data;
        }
    }

    return .incomplete;
}

/// Calculate bytes consumed including newline.
fn calculateConsumed(data: []const u8, line_len: usize) usize {
    var consumed = line_len;

    // Skip LF
    if (consumed < data.len and data[consumed] == '\n') {
        consumed += 1;
    }

    return consumed;
}

/// Split line into fields at commas.
fn splitFields(line: []const u8, fields: *[MAX_FIELDS][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;

    for (line, 0..) |c, i| {
        if (c == ',' or c == '\r' or c == '\n') {
            if (count < MAX_FIELDS) {
                fields[count] = line[start..i];
                count += 1;
            }
            start = i + 1;
        }
    }

    // Last field
    if (start <= line.len and count < MAX_FIELDS) {
        var end = line.len;
        while (end > start and (line[end - 1] == '\r' or line[end - 1] == '\n')) {
            end -= 1;
        }
        fields[count] = line[start..end];
        count += 1;
    }

    return count;
}

// ============================================================================
// Tests
// ============================================================================

test "CSV decode new order" {
    const data = "N, 1, IBM, 100, 50, B, 42\n";
    const result = try decodeInput(data);

    try std.testing.expectEqual(msg.InputMsgType.new_order, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.new_order.user_id);
    try std.testing.expectEqual(@as(u32, 42), result.message.data.new_order.user_order_id);
    try std.testing.expectEqual(@as(u32, 100), result.message.data.new_order.price);
    try std.testing.expectEqual(@as(u32, 50), result.message.data.new_order.quantity);
    try std.testing.expectEqual(msg.Side.buy, result.message.data.new_order.side);
    try std.testing.expectEqual(data.len, result.bytes_consumed);
}

test "CSV decode cancel" {
    const data = "C, 1, 100\n";
    const result = try decodeInput(data);

    try std.testing.expectEqual(msg.InputMsgType.cancel, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.cancel.user_id);
    try std.testing.expectEqual(@as(u32, 100), result.message.data.cancel.user_order_id);
}

test "CSV decode cancel with symbol hint" {
    const data = "C, 1, 100, IBM\n";
    const result = try decodeInput(data);

    try std.testing.expectEqual(msg.InputMsgType.cancel, result.message.msg_type);
    try std.testing.expect(result.message.data.cancel.hasSymbolHint());
}

test "CSV decode flush" {
    const data = "F\n";
    const result = try decodeInput(data);

    try std.testing.expectEqual(msg.InputMsgType.flush, result.message.msg_type);
}

test "CSV encode output ack" {
    const ack = msg.OutputMsg.makeAck(1, 100, msg.makeSymbol("IBM"), 0);

    var buf: [256]u8 = undefined;
    const len = try encodeOutput(&ack, &buf);

    try std.testing.expectEqualStrings("A, IBM, 1, 100\n", buf[0..len]);
}

test "CSV encode output trade" {
    const trade = msg.OutputMsg.makeTrade(1, 100, 2, 200, 5000, 50, msg.makeSymbol("IBM"), 0);

    var buf: [256]u8 = undefined;
    const len = try encodeOutput(&trade, &buf);

    try std.testing.expectEqualStrings("T, IBM, 1, 100, 2, 200, 5000, 50\n", buf[0..len]);
}

test "CSV encode output empty top of book" {
    const tob = msg.OutputMsg.makeTopOfBook(msg.makeSymbol("IBM"), .buy, 0, 0);

    var buf: [256]u8 = undefined;
    const len = try encodeOutput(&tob, &buf);

    try std.testing.expectEqualStrings("B, IBM, B, -, -\n", buf[0..len]);
}

test "CSV roundtrip output" {
    const trade = msg.OutputMsg.makeTrade(1, 100, 2, 200, 5000, 50, msg.makeSymbol("IBM"), 0);

    var buf: [256]u8 = undefined;
    const len = try encodeOutput(&trade, &buf);
    const result = try decodeOutput(buf[0..len]);

    try std.testing.expectEqual(msg.OutputMsgType.trade, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.trade.buy_user_id);
    try std.testing.expectEqual(@as(u32, 5000), result.message.data.trade.price);
}

test "CSV incomplete message" {
    const data = "N, 1, IBM";
    try std.testing.expectError(codec.CodecError.IncompleteMessage, decodeInput(data));
}

test "CSV malformed message" {
    const data = "\n";
    try std.testing.expectError(codec.CodecError.MalformedMessage, decodeInput(data));
}

test "CSV multiple messages" {
    const data = "N, 1, IBM, 100, 50, B, 1\nN, 2, AAPL, 200, 30, S, 2\n";

    const result1 = try decodeInput(data);
    try std.testing.expectEqual(@as(u32, 1), result1.message.data.new_order.user_id);

    const result2 = try decodeInput(data[result1.bytes_consumed..]);
    try std.testing.expectEqual(@as(u32, 2), result2.message.data.new_order.user_id);
}
