//! FIX Protocol Codec - FIX 4.2/4.4 Compatible
//!
//! Standard FIX tag structure:
//!   8=FIX.4.2|9=length|35=msgtype|...|10=checksum|
//!
//! We support SOH (0x01) or pipe (|) as delimiter for testing.
//!
//! Supported message types:
//!   Input:  D (New Order Single), F (Cancel Request)
//!   Output: 8 (Execution Report)
//!
//! Design principles:
//! - No dynamic allocation (Rule 3)
//! - Bounded parsing loops (Rule 2)
//! - Assertions on preconditions (Rule 5)

const std = @import("std");
const msg = @import("message_types.zig");

// ============================================================================
// FIX Constants
// ============================================================================

pub const SOH: u8 = 0x01; // Standard delimiter
pub const PIPE: u8 = '|'; // Test delimiter

pub const FIX_VERSION_42 = "FIX.4.2";
pub const FIX_VERSION_44 = "FIX.4.4";

// Standard FIX tags
pub const TAG_BEGIN_STRING: u32 = 8;
pub const TAG_BODY_LENGTH: u32 = 9;
pub const TAG_MSG_TYPE: u32 = 35;
pub const TAG_SENDER_COMP_ID: u32 = 49;
pub const TAG_TARGET_COMP_ID: u32 = 56;
pub const TAG_MSG_SEQ_NUM: u32 = 34;
pub const TAG_SENDING_TIME: u32 = 52;
pub const TAG_CHECKSUM: u32 = 10;

// Order tags
pub const TAG_CL_ORD_ID: u32 = 11; // Client order ID (user_order_id)
pub const TAG_ORIG_CL_ORD_ID: u32 = 41; // Original client order ID (for cancels)
pub const TAG_SYMBOL: u32 = 55;
pub const TAG_SIDE: u32 = 54; // 1=Buy, 2=Sell
pub const TAG_ORDER_QTY: u32 = 38;
pub const TAG_ORD_TYPE: u32 = 40; // 1=Market, 2=Limit
pub const TAG_PRICE: u32 = 44;
pub const TAG_ACCOUNT: u32 = 1; // We use this as user_id

// Execution report tags
pub const TAG_ORDER_ID: u32 = 37;
pub const TAG_EXEC_ID: u32 = 17;
pub const TAG_EXEC_TYPE: u32 = 150; // 0=New, 4=Canceled, F=Trade
pub const TAG_ORD_STATUS: u32 = 39;
pub const TAG_LAST_QTY: u32 = 32;
pub const TAG_LAST_PX: u32 = 31;
pub const TAG_LEAVES_QTY: u32 = 151;
pub const TAG_CUM_QTY: u32 = 14;
pub const TAG_AVG_PX: u32 = 6;
pub const TAG_TEXT: u32 = 58;

// Message types
pub const MSG_TYPE_NEW_ORDER = "D";
pub const MSG_TYPE_CANCEL = "F";
pub const MSG_TYPE_EXEC_REPORT = "8";
pub const MSG_TYPE_REJECT = "3";

// FIX Side values
pub const FIX_SIDE_BUY: u8 = '1';
pub const FIX_SIDE_SELL: u8 = '2';

// FIX OrdType values
pub const FIX_ORD_TYPE_MARKET: u8 = '1';
pub const FIX_ORD_TYPE_LIMIT: u8 = '2';

// FIX ExecType values
pub const FIX_EXEC_TYPE_NEW: u8 = '0';
pub const FIX_EXEC_TYPE_CANCELED: u8 = '4';
pub const FIX_EXEC_TYPE_TRADE: u8 = 'F';

// ============================================================================
// Configuration
// ============================================================================

const MAX_FIX_FIELDS: usize = 64;
const MAX_FIX_MESSAGE_SIZE: usize = 4096;
const MAX_FIELD_VALUE_LEN: usize = 64;

// ============================================================================
// Codec Errors
// ============================================================================

pub const CodecError = error{
    BufferTooSmall,
    InvalidFormat,
    InvalidMessageType,
    MissingRequiredField,
    InvalidFieldValue,
    ChecksumMismatch,
    MessageTooLong,
};

// ============================================================================
// FIX Field
// ============================================================================

const FixField = struct {
    tag: u32,
    value: []const u8,
};

// ============================================================================
// FIX Parser
// ============================================================================

const FixParser = struct {
    data: []const u8,
    pos: usize,
    delimiter: u8,
    fields: [MAX_FIX_FIELDS]FixField,
    field_count: usize,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        // Auto-detect delimiter
        const delim = detectDelimiter(data);

        return Self{
            .data = data,
            .pos = 0,
            .delimiter = delim,
            .fields = undefined,
            .field_count = 0,
        };
    }

    /// Parse all fields from message
    pub fn parse(self: *Self) CodecError!void {
        self.field_count = 0;

        // Rule 2: Bounded loop
        var iterations: usize = 0;
        while (self.pos < self.data.len and iterations < MAX_FIX_FIELDS) : (iterations += 1) {
            const field = self.parseField() orelse break;

            if (self.field_count < MAX_FIX_FIELDS) {
                self.fields[self.field_count] = field;
                self.field_count += 1;
            }
        }
    }

    fn parseField(self: *Self) ?FixField {
        // Find '='
        const eq_pos = std.mem.indexOfScalarPos(u8, self.data, self.pos, '=') orelse return null;

        // Parse tag
        const tag_str = self.data[self.pos..eq_pos];
        const tag = std.fmt.parseInt(u32, tag_str, 10) catch return null;

        // Find delimiter
        const delim_pos = std.mem.indexOfScalarPos(u8, self.data, eq_pos + 1, self.delimiter) orelse self.data.len;

        // Extract value
        const value = self.data[eq_pos + 1 .. delim_pos];

        // Advance position
        self.pos = if (delim_pos < self.data.len) delim_pos + 1 else self.data.len;

        return FixField{ .tag = tag, .value = value };
    }

    /// Get field by tag
    pub fn getField(self: *const Self, tag: u32) ?[]const u8 {
        for (self.fields[0..self.field_count]) |field| {
            if (field.tag == tag) {
                return field.value;
            }
        }
        return null;
    }

    /// Get field as u32
    pub fn getFieldU32(self: *const Self, tag: u32) ?u32 {
        const value = self.getField(tag) orelse return null;
        return std.fmt.parseInt(u32, value, 10) catch null;
    }
};

// ============================================================================
// Decode Result
// ============================================================================

pub const DecodeResult = struct {
    message: msg.InputMsg,
    bytes_consumed: usize,
};

// ============================================================================
// Detection
// ============================================================================

/// Detect delimiter (SOH or pipe)
fn detectDelimiter(data: []const u8) u8 {
    // Look for first delimiter after 8=FIX
    for (data) |byte| {
        if (byte == SOH) return SOH;
        if (byte == PIPE) return PIPE;
    }
    return SOH; // Default to SOH
}

/// Check if data looks like a FIX message
pub fn isFixMessage(data: []const u8) bool {
    if (data.len < 10) return false;

    // FIX messages start with "8=FIX"
    return std.mem.startsWith(u8, data, "8=FIX");
}

/// Find end of FIX message (after checksum field)
pub fn findMessageEnd(data: []const u8) ?usize {
    const delimiter = detectDelimiter(data);

    // Look for "10=" (checksum tag)
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '1' and data[i + 1] == '0' and data[i + 2] == '=') {
            // Find delimiter after checksum value
            const delim_pos = std.mem.indexOfScalarPos(u8, data, i + 3, delimiter);
            if (delim_pos) |pos| {
                return pos + 1;
            }
        }
    }

    return null;
}

// ============================================================================
// Input Decoding
// ============================================================================

/// Decode FIX input message
pub fn decodeInput(data: []const u8) CodecError!DecodeResult {
    if (!isFixMessage(data)) {
        return CodecError.InvalidFormat;
    }

    // Find message end
    const msg_end = findMessageEnd(data) orelse data.len;

    var parser = FixParser.init(data[0..msg_end]);
    try parser.parse();

    // Get message type
    const msg_type = parser.getField(TAG_MSG_TYPE) orelse {
        return CodecError.MissingRequiredField;
    };

    if (std.mem.eql(u8, msg_type, MSG_TYPE_NEW_ORDER)) {
        return decodeNewOrder(&parser, msg_end);
    } else if (std.mem.eql(u8, msg_type, MSG_TYPE_CANCEL)) {
        return decodeCancel(&parser, msg_end);
    } else {
        return CodecError.InvalidMessageType;
    }
}

fn decodeNewOrder(parser: *const FixParser, bytes_consumed: usize) CodecError!DecodeResult {
    // Required fields
    const symbol = parser.getField(TAG_SYMBOL) orelse return CodecError.MissingRequiredField;
    const side_str = parser.getField(TAG_SIDE) orelse return CodecError.MissingRequiredField;
    const qty = parser.getFieldU32(TAG_ORDER_QTY) orelse return CodecError.MissingRequiredField;

    // Optional fields with defaults
    const user_id = parser.getFieldU32(TAG_ACCOUNT) orelse 0;
    const cl_ord_id = parser.getFieldU32(TAG_CL_ORD_ID) orelse 0;
    const price = parser.getFieldU32(TAG_PRICE) orelse 0; // 0 = market order

    // Parse side
    if (side_str.len == 0) return CodecError.InvalidFieldValue;
    const side: msg.Side = switch (side_str[0]) {
        FIX_SIDE_BUY => .buy,
        FIX_SIDE_SELL => .sell,
        else => return CodecError.InvalidFieldValue,
    };

    // Build message
    var result: msg.InputMsg = undefined;
    @memset(std.mem.asBytes(&result), 0);

    result.type = .new_order;
    result.data.new_order.user_id = user_id;
    result.data.new_order.user_order_id = cl_ord_id;
    result.data.new_order.price = price;
    result.data.new_order.quantity = qty;
    result.data.new_order.side = side;
    msg.copySymbol(&result.data.new_order.symbol, symbol);

    return DecodeResult{
        .message = result,
        .bytes_consumed = bytes_consumed,
    };
}

fn decodeCancel(parser: *const FixParser, bytes_consumed: usize) CodecError!DecodeResult {
    // Required fields
    const user_id = parser.getFieldU32(TAG_ACCOUNT) orelse 0;
    const orig_cl_ord_id = parser.getFieldU32(TAG_ORIG_CL_ORD_ID) orelse
        parser.getFieldU32(TAG_CL_ORD_ID) orelse
        return CodecError.MissingRequiredField;

    // Build message
    var result: msg.InputMsg = undefined;
    @memset(std.mem.asBytes(&result), 0);

    result.type = .cancel;
    result.data.cancel.user_id = user_id;
    result.data.cancel.user_order_id = orig_cl_ord_id;
    // Symbol will be looked up by engine

    return DecodeResult{
        .message = result,
        .bytes_consumed = bytes_consumed,
    };
}

// ============================================================================
// Output Encoding
// ============================================================================

/// FIX message builder
const FixBuilder = struct {
    buf: []u8,
    pos: usize,
    delimiter: u8,
    body_start: usize,

    const Self = @This();

    pub fn init(buf: []u8, delimiter: u8) Self {
        return Self{
            .buf = buf,
            .pos = 0,
            .delimiter = delimiter,
            .body_start = 0,
        };
    }

    pub fn addField(self: *Self, tag: u32, value: []const u8) CodecError!void {
        // Format: tag=value<delim>
        const written = std.fmt.bufPrint(
            self.buf[self.pos..],
            "{d}={s}",
            .{ tag, value },
        ) catch return CodecError.BufferTooSmall;

        self.pos += written.len;

        if (self.pos >= self.buf.len) return CodecError.BufferTooSmall;
        self.buf[self.pos] = self.delimiter;
        self.pos += 1;
    }

    pub fn addFieldU32(self: *Self, tag: u32, value: u32) CodecError!void {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return CodecError.BufferTooSmall;
        try self.addField(tag, num_str);
    }

    pub fn addFieldChar(self: *Self, tag: u32, value: u8) CodecError!void {
        const char_buf = [_]u8{value};
        try self.addField(tag, &char_buf);
    }

    pub fn markBodyStart(self: *Self) void {
        self.body_start = self.pos;
    }

    pub fn getBodyLength(self: *const Self) usize {
        return self.pos - self.body_start;
    }

    pub fn getBytes(self: *const Self) []const u8 {
        return self.buf[0..self.pos];
    }
};

/// Encode output message to FIX format
pub fn encodeOutput(output: *const msg.OutputMsg, buf: []u8) CodecError!usize {
    return encodeOutputWithDelimiter(output, buf, SOH);
}

/// Encode output message with specific delimiter (for testing)
pub fn encodeOutputWithDelimiter(output: *const msg.OutputMsg, buf: []u8, delimiter: u8) CodecError!usize {
    return switch (output.type) {
        .ack => encodeAck(&output.data.ack, buf, delimiter),
        .cancel_ack => encodeCancelAck(&output.data.cancel_ack, buf, delimiter),
        .trade => encodeTrade(&output.data.trade, buf, delimiter),
        .top_of_book => encodeTopOfBook(&output.data.top_of_book, buf, delimiter),
    };
}

fn encodeAck(ack: *const msg.AckMsg, buf: []u8, delimiter: u8) CodecError!usize {
    // Build body first to get length
    var body_buf: [512]u8 = undefined;
    var body = FixBuilder.init(&body_buf, delimiter);

    try body.addField(TAG_MSG_TYPE, MSG_TYPE_EXEC_REPORT);
    try body.addFieldU32(TAG_ORDER_ID, ack.user_order_id);
    try body.addFieldU32(TAG_EXEC_ID, ack.user_order_id);
    try body.addFieldChar(TAG_EXEC_TYPE, FIX_EXEC_TYPE_NEW);
    try body.addFieldChar(TAG_ORD_STATUS, '0'); // New
    try body.addField(TAG_SYMBOL, msg.symbolSlice(&ack.symbol));
    try body.addFieldU32(TAG_ACCOUNT, ack.user_id);
    try body.addFieldU32(TAG_CL_ORD_ID, ack.user_order_id);

    return buildFullMessage(buf, delimiter, body.getBytes());
}

fn encodeCancelAck(cancel_ack: *const msg.CancelAckMsg, buf: []u8, delimiter: u8) CodecError!usize {
    var body_buf: [512]u8 = undefined;
    var body = FixBuilder.init(&body_buf, delimiter);

    try body.addField(TAG_MSG_TYPE, MSG_TYPE_EXEC_REPORT);
    try body.addFieldU32(TAG_ORDER_ID, cancel_ack.user_order_id);
    try body.addFieldU32(TAG_EXEC_ID, cancel_ack.user_order_id);
    try body.addFieldChar(TAG_EXEC_TYPE, FIX_EXEC_TYPE_CANCELED);
    try body.addFieldChar(TAG_ORD_STATUS, '4'); // Canceled
    try body.addField(TAG_SYMBOL, msg.symbolSlice(&cancel_ack.symbol));
    try body.addFieldU32(TAG_ACCOUNT, cancel_ack.user_id);
    try body.addFieldU32(TAG_CL_ORD_ID, cancel_ack.user_order_id);

    return buildFullMessage(buf, delimiter, body.getBytes());
}

fn encodeTrade(trade: *const msg.TradeMsg, buf: []u8, delimiter: u8) CodecError!usize {
    // For trades, we generate two execution reports (one for each side)
    // For simplicity, we'll generate one combined report
    var body_buf: [512]u8 = undefined;
    var body = FixBuilder.init(&body_buf, delimiter);

    try body.addField(TAG_MSG_TYPE, MSG_TYPE_EXEC_REPORT);
    try body.addFieldU32(TAG_ORDER_ID, trade.user_order_id_buy);
    try body.addFieldU32(TAG_EXEC_ID, trade.user_order_id_buy);
    try body.addFieldChar(TAG_EXEC_TYPE, FIX_EXEC_TYPE_TRADE);
    try body.addFieldChar(TAG_ORD_STATUS, '2'); // Filled (simplified)
    try body.addField(TAG_SYMBOL, msg.symbolSlice(&trade.symbol));
    try body.addFieldU32(TAG_ACCOUNT, trade.user_id_buy);
    try body.addFieldU32(TAG_CL_ORD_ID, trade.user_order_id_buy);
    try body.addFieldU32(TAG_LAST_QTY, trade.quantity);
    try body.addFieldU32(TAG_LAST_PX, trade.price);

    return buildFullMessage(buf, delimiter, body.getBytes());
}

fn encodeTopOfBook(tob: *const msg.TopOfBookMsg, buf: []u8, delimiter: u8) CodecError!usize {
    // FIX doesn't have a standard TOB message, so we use a custom format
    // or market data message. For simplicity, we'll skip TOB in FIX
    // and just return an empty message indicator
    _ = tob;
    _ = buf;
    _ = delimiter;

    // Return 0 to indicate no FIX encoding for TOB
    return 0;
}

/// Build complete FIX message with header and trailer
fn buildFullMessage(buf: []u8, delimiter: u8, body: []const u8) CodecError!usize {
    var builder = FixBuilder.init(buf, delimiter);

    // Header
    try builder.addField(TAG_BEGIN_STRING, FIX_VERSION_42);

    // Body length (we need to calculate this)
    var len_buf: [16]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch return CodecError.BufferTooSmall;
    try builder.addField(TAG_BODY_LENGTH, len_str);

    // Copy body
    if (builder.pos + body.len > builder.buf.len) {
        return CodecError.BufferTooSmall;
    }
    @memcpy(builder.buf[builder.pos..][0..body.len], body);
    builder.pos += body.len;

    // Checksum
    const checksum = calculateChecksum(builder.buf[0..builder.pos]);
    var checksum_buf: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&checksum_buf, "{d:0>3}", .{checksum}) catch return CodecError.BufferTooSmall;
    try builder.addField(TAG_CHECKSUM, checksum_buf[0..3]);

    return builder.pos;
}

/// Calculate FIX checksum (sum of all bytes mod 256)
fn calculateChecksum(data: []const u8) u8 {
    var sum: u32 = 0;
    for (data) |byte| {
        sum += byte;
    }
    return @truncate(sum % 256);
}

// ============================================================================
// Input Encoding (for clients/testing)
// ============================================================================

/// Encode new order to FIX format
pub fn encodeNewOrder(
    user_id: u32,
    user_order_id: u32,
    symbol: []const u8,
    price: u32,
    quantity: u32,
    side: msg.Side,
    buf: []u8,
) CodecError!usize {
    return encodeNewOrderWithDelimiter(user_id, user_order_id, symbol, price, quantity, side, buf, SOH);
}

pub fn encodeNewOrderWithDelimiter(
    user_id: u32,
    user_order_id: u32,
    symbol: []const u8,
    price: u32,
    quantity: u32,
    side: msg.Side,
    buf: []u8,
    delimiter: u8,
) CodecError!usize {
    var body_buf: [512]u8 = undefined;
    var body = FixBuilder.init(&body_buf, delimiter);

    try body.addField(TAG_MSG_TYPE, MSG_TYPE_NEW_ORDER);
    try body.addFieldU32(TAG_ACCOUNT, user_id);
    try body.addFieldU32(TAG_CL_ORD_ID, user_order_id);
    try body.addField(TAG_SYMBOL, symbol);
    try body.addFieldChar(TAG_SIDE, if (side == .buy) FIX_SIDE_BUY else FIX_SIDE_SELL);
    try body.addFieldU32(TAG_ORDER_QTY, quantity);

    if (price > 0) {
        try body.addFieldChar(TAG_ORD_TYPE, FIX_ORD_TYPE_LIMIT);
        try body.addFieldU32(TAG_PRICE, price);
    } else {
        try body.addFieldChar(TAG_ORD_TYPE, FIX_ORD_TYPE_MARKET);
    }

    return buildFullMessage(buf, delimiter, body.getBytes());
}

/// Encode cancel to FIX format
pub fn encodeCancel(
    user_id: u32,
    user_order_id: u32,
    symbol: []const u8,
    buf: []u8,
) CodecError!usize {
    return encodeCancelWithDelimiter(user_id, user_order_id, symbol, buf, SOH);
}

pub fn encodeCancelWithDelimiter(
    user_id: u32,
    user_order_id: u32,
    symbol: []const u8,
    buf: []u8,
    delimiter: u8,
) CodecError!usize {
    var body_buf: [512]u8 = undefined;
    var body = FixBuilder.init(&body_buf, delimiter);

    try body.addField(TAG_MSG_TYPE, MSG_TYPE_CANCEL);
    try body.addFieldU32(TAG_ACCOUNT, user_id);
    try body.addFieldU32(TAG_ORIG_CL_ORD_ID, user_order_id);
    try body.addField(TAG_SYMBOL, symbol);

    return buildFullMessage(buf, delimiter, body.getBytes());
}

// ============================================================================
// Tests
// ============================================================================

test "is fix message" {
    try std.testing.expect(isFixMessage("8=FIX.4.2|9=100|35=D|"));
    try std.testing.expect(isFixMessage("8=FIX.4.4\x019=100\x0135=D\x01"));
    try std.testing.expect(!isFixMessage("MN")); // Binary
    try std.testing.expect(!isFixMessage("N,1,IBM,100,500,B,1")); // CSV
}

test "detect delimiter" {
    try std.testing.expectEqual(PIPE, detectDelimiter("8=FIX.4.2|9=100|"));
    try std.testing.expectEqual(SOH, detectDelimiter("8=FIX.4.2\x019=100\x01"));
}

test "encode and decode new order with pipe" {
    var buf: [1024]u8 = undefined;

    const encoded_len = try encodeNewOrderWithDelimiter(
        1, // user_id
        100, // user_order_id
        "IBM",
        150, // price
        1000, // quantity
        .buy,
        &buf,
        PIPE,
    );

    try std.testing.expect(encoded_len > 0);
    try std.testing.expect(isFixMessage(buf[0..encoded_len]));

    // Decode
    const result = try decodeInput(buf[0..encoded_len]);

    try std.testing.expectEqual(msg.InputMsgType.new_order, result.message.type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.new_order.user_id);
    try std.testing.expectEqual(@as(u32, 100), result.message.data.new_order.user_order_id);
    try std.testing.expectEqual(@as(u32, 150), result.message.data.new_order.price);
    try std.testing.expectEqual(@as(u32, 1000), result.message.data.new_order.quantity);
    try std.testing.expectEqual(msg.Side.buy, result.message.data.new_order.side);
}

test "encode and decode cancel with pipe" {
    var buf: [1024]u8 = undefined;

    const encoded_len = try encodeCancelWithDelimiter(
        1,
        100,
        "AAPL",
        &buf,
        PIPE,
    );

    try std.testing.expect(encoded_len > 0);

    const result = try decodeInput(buf[0..encoded_len]);

    try std.testing.expectEqual(msg.InputMsgType.cancel, result.message.type);
    try std.testing.expectEqual(@as(u32, 1), result.message.data.cancel.user_id);
    try std.testing.expectEqual(@as(u32, 100), result.message.data.cancel.user_order_id);
}

test "encode ack to fix" {
    var buf: [1024]u8 = undefined;

    const ack = msg.makeAckMsg("IBM", 1, 100);
    const encoded_len = try encodeOutputWithDelimiter(&ack, &buf, PIPE);

    try std.testing.expect(encoded_len > 0);
    try std.testing.expect(isFixMessage(buf[0..encoded_len]));

    // Should contain execution report type
    try std.testing.expect(std.mem.indexOf(u8, buf[0..encoded_len], "35=8") != null);
    // Should contain ExecType=New
    try std.testing.expect(std.mem.indexOf(u8, buf[0..encoded_len], "150=0") != null);
}

test "encode trade to fix" {
    var buf: [1024]u8 = undefined;

    const trade = msg.makeTradeMsg("GOOG", 1, 100, 2, 200, 150, 500);
    const encoded_len = try encodeOutputWithDelimiter(&trade, &buf, PIPE);

    try std.testing.expect(encoded_len > 0);
    try std.testing.expect(isFixMessage(buf[0..encoded_len]));

    // Should contain ExecType=Trade
    try std.testing.expect(std.mem.indexOf(u8, buf[0..encoded_len], "150=F") != null);
    // Should contain LastQty
    try std.testing.expect(std.mem.indexOf(u8, buf[0..encoded_len], "32=500") != null);
    // Should contain LastPx
    try std.testing.expect(std.mem.indexOf(u8, buf[0..encoded_len], "31=150") != null);
}

test "checksum calculation" {
    // Simple test case
    const data = "8=FIX.4.2|9=5|35=D|";
    const checksum = calculateChecksum(data);
    try std.testing.expect(checksum > 0);
    try std.testing.expect(checksum < 256);
}

test "fix parser" {
    const data = "8=FIX.4.2|9=100|35=D|1=123|55=IBM|54=1|38=1000|44=150|";
    var parser = FixParser.init(data);
    try parser.parse();

    try std.testing.expectEqualStrings("FIX.4.2", parser.getField(TAG_BEGIN_STRING).?);
    try std.testing.expectEqualStrings("D", parser.getField(TAG_MSG_TYPE).?);
    try std.testing.expectEqualStrings("IBM", parser.getField(TAG_SYMBOL).?);
    try std.testing.expectEqual(@as(u32, 123), parser.getFieldU32(TAG_ACCOUNT).?);
    try std.testing.expectEqual(@as(u32, 1000), parser.getFieldU32(TAG_ORDER_QTY).?);
}

test "market order has zero price" {
    var buf: [1024]u8 = undefined;

    const encoded_len = try encodeNewOrderWithDelimiter(
        1,
        100,
        "TSLA",
        0, // Market order
        500,
        .sell,
        &buf,
        PIPE,
    );

    const result = try decodeInput(buf[0..encoded_len]);

    try std.testing.expectEqual(@as(u32, 0), result.message.data.new_order.price);
}
