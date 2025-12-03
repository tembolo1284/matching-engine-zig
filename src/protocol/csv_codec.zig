//! CSV protocol codec - human readable, newline delimited.
//! Matches C protocol specification.
//!
//! Input formats:
//!   New Order: N, userId, symbol, price, qty, side, userOrderId
//!   Cancel:    C, userId, userOrderId
//!   Flush:     F
//!
//! Output formats:
//!   Ack:       A, symbol, userId, userOrderId
//!   Trade:     T, symbol, buyUserId, buyOrderId, sellUserId, sellOrderId, price, qty
//!   TopOfBook: B, symbol, side, price, qty   (or "B, symbol, side, -, -" for empty)
//!   CancelAck: C, symbol, userId, userOrderId
//!   Reject:    R, symbol, userId, userOrderId, reason

const std = @import("std");
const msg = @import("message_types.zig");
const codec = @import("codec.zig");

// ============================================================================
// Constants
// ============================================================================

const MAX_LINE_LENGTH = 256;
const MAX_FIELDS = 16;

// ============================================================================
// Input Message Decoding
// ============================================================================

pub fn decodeInput(data: []const u8) codec.CodecError!codec.DecodeResult {
    // Find line ending
    const line_end = findLineEnd(data);
    if (line_end == 0 and !endsWithNewline(data)) return codec.CodecError.IncompleteMessage;

    const line_len = if (line_end == 0) data.len else line_end;
    const line = data[0..line_len];

    // Parse fields
    var fields: [MAX_FIELDS][]const u8 = undefined;
    const num_fields = splitFields(line, &fields);

    if (num_fields == 0) return codec.CodecError.MalformedMessage;

    const msg_type_str = trim(fields[0]);
    if (msg_type_str.len == 0) return codec.CodecError.MalformedMessage;

    var result: codec.DecodeResult = undefined;
    result.bytes_consumed = consumedBytes(data, line_len);

    switch (msg_type_str[0]) {
        'N' => result.message = try parseNewOrder(fields[0..num_fields]),
        'C' => result.message = try parseCancel(fields[0..num_fields]),
        'F' => result.message = .{
            .msg_type = .flush,
            .data = .{ .flush = .{} },
        },
        else => return codec.CodecError.UnknownMessageType,
    }

    return result;
}

fn parseNewOrder(fields: [][]const u8) codec.CodecError!msg.InputMsg {
    // N, userId, symbol, price, qty, side, userOrderId
    if (fields.len < 7) return codec.CodecError.InvalidField;

    const user_id = codec.parseU32(trim(fields[1])) orelse return codec.CodecError.InvalidField;
    const symbol_str = trim(fields[2]);
    const price = codec.parseU32(trim(fields[3])) orelse return codec.CodecError.InvalidField;
    const quantity = codec.parseU32(trim(fields[4])) orelse return codec.CodecError.InvalidField;
    const side_str = trim(fields[5]);
    const order_id = codec.parseU32(trim(fields[6])) orelse return codec.CodecError.InvalidField;

    if (side_str.len == 0) return codec.CodecError.InvalidField;

    const side: msg.Side = switch (side_str[0]) {
        'B', 'b' => .buy,
        'S', 's' => .sell,
        else => return codec.CodecError.InvalidField,
    };

    return .{
        .msg_type = .new_order,
        .data = .{ .new_order = .{
            .user_id = user_id,
            .user_order_id = order_id,
            .price = price,
            .quantity = quantity,
            .side = side,
            .symbol = msg.makeSymbol(symbol_str),
        } },
    };
}

fn parseCancel(fields: [][]const u8) codec.CodecError!msg.InputMsg {
    // C, userId, userOrderId
    if (fields.len < 3) return codec.CodecError.InvalidField;

    const user_id = codec.parseU32(trim(fields[1])) orelse return codec.CodecError.InvalidField;
    const order_id = codec.parseU32(trim(fields[2])) orelse return codec.CodecError.InvalidField;

    return .{
        .msg_type = .cancel,
        .data = .{ .cancel = .{
            .user_id = user_id,
            .user_order_id = order_id,
        } },
    };
}

// ============================================================================
// Input Message Encoding
// ============================================================================

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
            writer.print("C, {}, {}\n", .{
                c.user_id,
                c.user_order_id,
            }) catch return codec.CodecError.BufferTooSmall;
        },
        .flush => {
            writer.print("F\n", .{}) catch return codec.CodecError.BufferTooSmall;
        },
    }

    return stream.pos;
}

// ============================================================================
// Output Message Decoding (for UDP responses)
// ============================================================================

pub fn decodeOutput(data: []const u8) codec.CodecError!codec.OutputDecodeResult {
    const line_end = findLineEnd(data);
    if (line_end == 0 and !endsWithNewline(data)) return codec.CodecError.IncompleteMessage;

    const line_len = if (line_end == 0) data.len else line_end;
    const line = data[0..line_len];

    var fields: [MAX_FIELDS][]const u8 = undefined;
    const num_fields = splitFields(line, &fields);

    if (num_fields == 0) return codec.CodecError.MalformedMessage;

    const msg_type_str = trim(fields[0]);
    if (msg_type_str.len == 0) return codec.CodecError.MalformedMessage;

    var result: codec.OutputDecodeResult = undefined;
    result.bytes_consumed = consumedBytes(data, line_len);

    switch (msg_type_str[0]) {
        'A' => result.message = try parseAck(fields[0..num_fields]),
        'T' => result.message = try parseTrade(fields[0..num_fields]),
        'B' => result.message = try parseTopOfBook(fields[0..num_fields]),
        'C' => result.message = try parseCancelAck(fields[0..num_fields]),
        'X' => result.message = try parseCancelAck(fields[0..num_fields]), // Also accept X
        'R' => result.message = try parseReject(fields[0..num_fields]),
        else => return codec.CodecError.UnknownMessageType,
    }

    return result;
}

fn parseAck(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // A, symbol, userId, userOrderId
    if (fields.len < 4) return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeAck(
        codec.parseU32(trim(fields[2])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(trim(fields[3])) orelse return codec.CodecError.InvalidField,
        msg.makeSymbol(trim(fields[1])),
        0,
    );
}

fn parseTrade(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // T, symbol, buyUserId, buyOrderId, sellUserId, sellOrderId, price, qty
    if (fields.len < 8) return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeTrade(
        codec.parseU32(trim(fields[2])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(trim(fields[3])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(trim(fields[4])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(trim(fields[5])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(trim(fields[6])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(trim(fields[7])) orelse return codec.CodecError.InvalidField,
        msg.makeSymbol(trim(fields[1])),
        0,
    );
}

fn parseTopOfBook(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // B, symbol, side, price, qty
    if (fields.len < 5) return codec.CodecError.InvalidField;

    const side_str = trim(fields[2]);
    if (side_str.len == 0) return codec.CodecError.InvalidField;

    const side: msg.Side = switch (side_str[0]) {
        'B', 'b' => .buy,
        'S', 's' => .sell,
        else => return codec.CodecError.InvalidField,
    };

    // Handle "-, -" for empty book
    const price_str = trim(fields[3]);
    const qty_str = trim(fields[4]);

    const price: u32 = if (price_str.len > 0 and price_str[0] == '-') 0 else codec.parseU32(price_str) orelse return codec.CodecError.InvalidField;
    const qty: u32 = if (qty_str.len > 0 and qty_str[0] == '-') 0 else codec.parseU32(qty_str) orelse return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeTopOfBook(
        msg.makeSymbol(trim(fields[1])),
        side,
        price,
        qty,
    );
}

fn parseCancelAck(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // C, symbol, userId, userOrderId
    if (fields.len < 4) return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeCancelAck(
        codec.parseU32(trim(fields[2])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(trim(fields[3])) orelse return codec.CodecError.InvalidField,
        msg.makeSymbol(trim(fields[1])),
        0,
    );
}

fn parseReject(fields: [][]const u8) codec.CodecError!msg.OutputMsg {
    // R, symbol, userId, userOrderId, reason
    if (fields.len < 5) return codec.CodecError.InvalidField;

    const reason_code = codec.parseU32(trim(fields[4])) orelse return codec.CodecError.InvalidField;

    return msg.OutputMsg.makeReject(
        codec.parseU32(trim(fields[2])) orelse return codec.CodecError.InvalidField,
        codec.parseU32(trim(fields[3])) orelse return codec.CodecError.InvalidField,
        @enumFromInt(@as(u8, @truncate(reason_code))),
        msg.makeSymbol(trim(fields[1])),
        0,
    );
}

// ============================================================================
// Output Message Encoding
// ============================================================================

pub fn encodeOutput(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (message.msg_type) {
        .ack => {
            // A, symbol, userId, userOrderId
            const a = &message.data.ack;
            writer.print("A, {s}, {}, {}\n", .{
                msg.symbolSlice(&message.symbol),
                a.user_id,
                a.user_order_id,
            }) catch return codec.CodecError.BufferTooSmall;
        },
        .trade => {
            // T, symbol, buyUserId, buyOrderId, sellUserId, sellOrderId, price, qty
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
            // B, symbol, side, price, qty  (or "-, -" for empty)
            const b = &message.data.top_of_book;
            if (b.price == 0 and b.quantity == 0) {
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
            // C, symbol, userId, userOrderId (note: 'C' matches C spec)
            const x = &message.data.cancel_ack;
            writer.print("C, {s}, {}, {}\n", .{
                msg.symbolSlice(&message.symbol),
                x.user_id,
                x.user_order_id,
            }) catch return codec.CodecError.BufferTooSmall;
        },
        .reject => {
            // R, symbol, userId, userOrderId, reason
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

fn findLineEnd(data: []const u8) usize {
    for (data, 0..) |c, i| {
        if (c == '\n') return i;
    }
    return 0;
}

fn endsWithNewline(data: []const u8) bool {
    return data.len > 0 and data[data.len - 1] == '\n';
}

fn consumedBytes(data: []const u8, line_len: usize) usize {
    var consumed = line_len;
    // Skip the newline if present
    if (consumed < data.len and data[consumed] == '\n') {
        consumed += 1;
    }
    return consumed;
}

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
        if (end > start) {
            fields[count] = line[start..end];
            count += 1;
        } else if (start < line.len) {
            fields[count] = line[start..end];
            count += 1;
        }
    }

    return count;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;

    while (start < end and (s[start] == ' ' or s[start] == '\t')) {
        start += 1;
    }
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) {
        end -= 1;
    }

    return s[start..end];
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
}

test "CSV encode output with symbol" {
    const ack = msg.OutputMsg.makeAck(1, 100, msg.makeSymbol("IBM"), 0);

    var buf: [256]u8 = undefined;
    const len = try encodeOutput(&ack, &buf);

    const expected = "A, IBM, 1, 100\n";
    try std.testing.expectEqualStrings(expected, buf[0..len]);
}

test "CSV roundtrip output" {
    const trade = msg.OutputMsg.makeTrade(1, 100, 2, 200, 5000, 50, msg.makeSymbol("IBM"), 0);

    var buf: [256]u8 = undefined;
    const len = try encodeOutput(&trade, &buf);

    const result = try decodeOutput(buf[0..len]);
    try std.testing.expectEqual(msg.OutputMsgType.trade, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.trade.buy_user_id);
}
