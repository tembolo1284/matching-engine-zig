//! FIX Protocol codec implementation.
//!
//! Supports FIX 4.2 and 4.4 message parsing and encoding for order flow.
//!
//! Supported Input Messages:
//! - NewOrderSingle (D): New order submission
//! - OrderCancelRequest (F): Cancel existing order
//!
//! Supported Output Messages:
//! - ExecutionReport (8): Acks, fills, cancels, rejects
//!
//! FIX Message Structure:
//! ```
//! 8=FIX.4.2|9=<body_length>|35=<msg_type>|...|10=<checksum>|
//!          ^--- body starts here          ^--- body ends here
//! ```
//!
//! Notes:
//! - Standard delimiter is SOH (0x01), but pipe '|' is also accepted for testing
//! - ClOrdID is expected to be numeric (u32) or will be hashed
//! - Checksum is validated on decode, calculated on encode
//!
//! Limitations (first pass):
//! - No session management (Logon, Logout, Heartbeat)
//! - No sequence number tracking
//! - No message recovery
//! - SenderCompID/TargetCompID not validated

const std = @import("std");
const msg = @import("message_types.zig");
const codec = @import("codec.zig");

// ============================================================================
// FIX Constants
// ============================================================================

/// FIX field delimiter (SOH = Start of Header).
pub const SOH: u8 = 0x01;

/// Alternative delimiter for human-readable logs/testing.
pub const PIPE: u8 = '|';

/// Maximum FIX message size we'll accept.
pub const MAX_FIX_MESSAGE_SIZE: usize = 4096;

/// Maximum field value length.
pub const MAX_FIELD_VALUE_LEN: usize = 256;

// ============================================================================
// FIX Tags
// ============================================================================

// Header/Trailer Tags
pub const TAG_BEGIN_STRING: u32 = 8;
pub const TAG_BODY_LENGTH: u32 = 9;
pub const TAG_MSG_TYPE: u32 = 35;
pub const TAG_SENDER_COMP_ID: u32 = 49;
pub const TAG_TARGET_COMP_ID: u32 = 56;
pub const TAG_MSG_SEQ_NUM: u32 = 34;
pub const TAG_SENDING_TIME: u32 = 52;
pub const TAG_CHECKSUM: u32 = 10;

// Order Tags
pub const TAG_CL_ORD_ID: u32 = 11;
pub const TAG_ORIG_CL_ORD_ID: u32 = 41;
pub const TAG_SYMBOL: u32 = 55;
pub const TAG_SIDE: u32 = 54;
pub const TAG_ORDER_QTY: u32 = 38;
pub const TAG_ORD_TYPE: u32 = 40;
pub const TAG_PRICE: u32 = 44;
pub const TAG_ACCOUNT: u32 = 1;

// Execution Report Tags
pub const TAG_ORDER_ID: u32 = 37;
pub const TAG_EXEC_ID: u32 = 17;
pub const TAG_EXEC_TYPE: u32 = 150;
pub const TAG_ORD_STATUS: u32 = 39;
pub const TAG_LAST_PX: u32 = 31;
pub const TAG_LAST_QTY: u32 = 32;
pub const TAG_LEAVES_QTY: u32 = 151;
pub const TAG_CUM_QTY: u32 = 14;
pub const TAG_AVG_PX: u32 = 6;
pub const TAG_TEXT: u32 = 58;
pub const TAG_ORD_REJ_REASON: u32 = 103;

// ============================================================================
// FIX Values
// ============================================================================

// Message Types (Tag 35)
pub const MSG_TYPE_HEARTBEAT: u8 = '0';
pub const MSG_TYPE_LOGON: u8 = 'A';
pub const MSG_TYPE_LOGOUT: u8 = '5';
pub const MSG_TYPE_EXEC_REPORT: u8 = '8';
pub const MSG_TYPE_NEW_ORDER: u8 = 'D';
pub const MSG_TYPE_CANCEL: u8 = 'F';

// Side (Tag 54)
pub const SIDE_BUY: u8 = '1';
pub const SIDE_SELL: u8 = '2';

// OrdType (Tag 40)
pub const ORD_TYPE_MARKET: u8 = '1';
pub const ORD_TYPE_LIMIT: u8 = '2';

// ExecType (Tag 150)
pub const EXEC_TYPE_NEW: u8 = '0';
pub const EXEC_TYPE_PARTIAL_FILL: u8 = '1';
pub const EXEC_TYPE_FILL: u8 = '2';
pub const EXEC_TYPE_CANCELED: u8 = '4';
pub const EXEC_TYPE_REJECTED: u8 = '8';

// OrdStatus (Tag 39)
pub const ORD_STATUS_NEW: u8 = '0';
pub const ORD_STATUS_PARTIAL: u8 = '1';
pub const ORD_STATUS_FILLED: u8 = '2';
pub const ORD_STATUS_CANCELED: u8 = '4';
pub const ORD_STATUS_REJECTED: u8 = '8';

// OrdRejReason (Tag 103)
pub const REJ_REASON_UNKNOWN_SYMBOL: u32 = 1;
pub const REJ_REASON_EXCHANGE_CLOSED: u32 = 2;
pub const REJ_REASON_ORDER_EXCEEDS_LIMIT: u32 = 3;
pub const REJ_REASON_DUPLICATE_ORDER: u32 = 6;
pub const REJ_REASON_OTHER: u32 = 99;

// ============================================================================
// Parsed Field Storage
// ============================================================================

/// Parsed FIX message fields.
const ParsedFields = struct {
    // Header
    begin_string: ?[]const u8 = null,
    body_length: ?u32 = null,
    msg_type: ?u8 = null,
    sender_comp_id: ?[]const u8 = null,
    target_comp_id: ?[]const u8 = null,
    msg_seq_num: ?u32 = null,

    // Order fields
    cl_ord_id: ?[]const u8 = null,
    orig_cl_ord_id: ?[]const u8 = null,
    symbol: ?[]const u8 = null,
    side: ?u8 = null,
    order_qty: ?u32 = null,
    ord_type: ?u8 = null,
    price: ?u32 = null,
    account: ?[]const u8 = null,

    // Trailer
    checksum: ?[]const u8 = null,

    // Metadata
    body_start: usize = 0,
    body_end: usize = 0,
    delimiter: u8 = SOH,
};

// ============================================================================
// Input Message Decoding
// ============================================================================

/// Decode FIX input message.
pub fn decodeInput(data: []const u8) codec.CodecError!codec.DecodeResult {
    if (data.len < 20) return codec.CodecError.IncompleteMessage;

    // Detect delimiter (SOH or pipe)
    const delimiter = detectDelimiter(data);

    // Parse all fields
    var fields = ParsedFields{ .delimiter = delimiter };
    const total_len = try parseMessage(data, delimiter, &fields);

    // Validate checksum
    if (!validateChecksum(data, &fields)) {
        return codec.CodecError.InvalidChecksum;
    }

    // Get message type
    const msg_type = fields.msg_type orelse return codec.CodecError.InvalidField;

    // Dispatch based on message type
    const message = switch (msg_type) {
        MSG_TYPE_NEW_ORDER => try parseNewOrderSingle(&fields),
        MSG_TYPE_CANCEL => try parseCancelRequest(&fields),
        else => return codec.CodecError.UnknownMessageType,
    };

    return .{
        .message = message,
        .bytes_consumed = total_len,
    };
}

fn parseNewOrderSingle(fields: *const ParsedFields) codec.CodecError!msg.InputMsg {
    // Required fields
    const cl_ord_id_str = fields.cl_ord_id orelse return codec.CodecError.InvalidField;
    const symbol_str = fields.symbol orelse return codec.CodecError.InvalidField;
    const side_char = fields.side orelse return codec.CodecError.InvalidField;
    const order_qty = fields.order_qty orelse return codec.CodecError.InvalidField;

    // Parse ClOrdID (try numeric first, then hash)
    const user_order_id = parseClOrdId(cl_ord_id_str);

    // Parse Account as user_id (optional, default to 1)
    const user_id: u32 = if (fields.account) |acc|
        codec.parseU32(acc) orelse 1
    else
        1;

    // Parse side
    const side: msg.Side = switch (side_char) {
        SIDE_BUY => .buy,
        SIDE_SELL => .sell,
        else => return codec.CodecError.InvalidField,
    };

    // Parse price (0 for market orders)
    const price: u32 = fields.price orelse 0;

    return msg.InputMsg.newOrder(.{
        .user_id = user_id,
        .user_order_id = user_order_id,
        .price = price,
        .quantity = order_qty,
        .side = side,
        .symbol = msg.makeSymbol(symbol_str),
    });
}

fn parseCancelRequest(fields: *const ParsedFields) codec.CodecError!msg.InputMsg {
    // For cancel, we need OrigClOrdID (the order to cancel)
    // ClOrdID is the cancel request's own ID (we'll ignore it)
    const orig_cl_ord_id_str = fields.orig_cl_ord_id orelse
        fields.cl_ord_id orelse
        return codec.CodecError.InvalidField;

    const user_order_id = parseClOrdId(orig_cl_ord_id_str);

    // Parse Account as user_id
    const user_id: u32 = if (fields.account) |acc|
        codec.parseU32(acc) orelse 1
    else
        1;

    // Symbol is optional but helpful for routing
    const symbol = if (fields.symbol) |s| msg.makeSymbol(s) else msg.EMPTY_SYMBOL;

    return msg.InputMsg.cancel(user_id, symbol, user_order_id);
}

// ============================================================================
// Output Message Decoding
// ============================================================================

/// Decode FIX output message (ExecutionReport).
pub fn decodeOutput(data: []const u8) codec.CodecError!codec.OutputDecodeResult {
    if (data.len < 20) return codec.CodecError.IncompleteMessage;

    const delimiter = detectDelimiter(data);

    var fields = ParsedFields{ .delimiter = delimiter };
    const total_len = try parseMessage(data, delimiter, &fields);

    if (!validateChecksum(data, &fields)) {
        return codec.CodecError.InvalidChecksum;
    }

    const msg_type = fields.msg_type orelse return codec.CodecError.InvalidField;

    if (msg_type != MSG_TYPE_EXEC_REPORT) {
        return codec.CodecError.UnknownMessageType;
    }

    const message = try parseExecutionReport(data, delimiter, &fields);

    return .{
        .message = message,
        .bytes_consumed = total_len,
    };
}

fn parseExecutionReport(data: []const u8, delimiter: u8, fields: *const ParsedFields) codec.CodecError!msg.OutputMsg {
    const symbol_str = fields.symbol orelse return codec.CodecError.InvalidField;
    const symbol = msg.makeSymbol(symbol_str);

    // Get ExecType to determine message type
    const exec_type_str = findField(data[fields.body_start..fields.body_end], TAG_EXEC_TYPE, delimiter);
    const exec_type: u8 = if (exec_type_str) |s| (if (s.len > 0) s[0] else '0') else '0';

    // Parse common fields
    const cl_ord_id_str = fields.cl_ord_id orelse return codec.CodecError.InvalidField;
    const user_order_id = parseClOrdId(cl_ord_id_str);
    const user_id: u32 = if (fields.account) |acc| codec.parseU32(acc) orelse 1 else 1;

    return switch (exec_type) {
        EXEC_TYPE_NEW => msg.OutputMsg.makeAck(user_id, user_order_id, symbol, 0),

        EXEC_TYPE_FILL, EXEC_TYPE_PARTIAL_FILL => blk: {
            const last_px_str = findField(data[fields.body_start..fields.body_end], TAG_LAST_PX, delimiter);
            const last_qty_str = findField(data[fields.body_start..fields.body_end], TAG_LAST_QTY, delimiter);

            const price = if (last_px_str) |s| codec.parseU32(s) orelse 0 else 0;
            const qty = if (last_qty_str) |s| codec.parseU32(s) orelse 0 else 0;

            // For simplicity, use same IDs for both sides (real impl would track)
            break :blk msg.OutputMsg.makeTrade(
                user_id,
                user_order_id,
                user_id,
                user_order_id,
                price,
                qty,
                symbol,
                0,
            );
        },

        EXEC_TYPE_CANCELED => msg.OutputMsg.makeCancelAck(user_id, user_order_id, symbol, 0),

        EXEC_TYPE_REJECTED => blk: {
            const rej_reason_str = findField(data[fields.body_start..fields.body_end], TAG_ORD_REJ_REASON, delimiter);
            const rej_code = if (rej_reason_str) |s| codec.parseU32(s) orelse 99 else 99;
            const reason = mapRejectReason(rej_code);
            break :blk msg.OutputMsg.makeReject(user_id, user_order_id, reason, symbol, 0);
        },

        else => msg.OutputMsg.makeAck(user_id, user_order_id, symbol, 0),
    };
}

// ============================================================================
// Input Message Encoding
// ============================================================================

/// Encode input message to FIX format.
pub fn encodeInput(message: *const msg.InputMsg, buf: []u8) codec.CodecError!usize {
    return switch (message.msg_type) {
        .new_order => encodeNewOrderSingle(&message.data.new_order, buf),
        .cancel => encodeCancelRequest(&message.data.cancel, buf),
        .flush => codec.CodecError.UnknownMessageType, // No FIX equivalent
    };
}

fn encodeNewOrderSingle(order: *const msg.NewOrderMsg, buf: []u8) codec.CodecError!usize {
    var builder = FixBuilder.init(buf);

    // Build body first (need length for header)
    var body_buf: [1024]u8 = undefined;
    var body = FixBuilder.init(&body_buf);

    // Message type
    body.addChar(TAG_MSG_TYPE, MSG_TYPE_NEW_ORDER);

    // ClOrdID
    body.addU32(TAG_CL_ORD_ID, order.user_order_id);

    // Account (user_id)
    body.addU32(TAG_ACCOUNT, order.user_id);

    // Symbol
    body.addSymbol(TAG_SYMBOL, &order.symbol);

    // Side
    body.addChar(TAG_SIDE, if (order.side == .buy) SIDE_BUY else SIDE_SELL);

    // OrderQty
    body.addU32(TAG_ORDER_QTY, order.quantity);

    // OrdType
    if (order.price == 0) {
        body.addChar(TAG_ORD_TYPE, ORD_TYPE_MARKET);
    } else {
        body.addChar(TAG_ORD_TYPE, ORD_TYPE_LIMIT);
        body.addU32(TAG_PRICE, order.price);
    }

    const body_len = body.pos;
    const body_data = body_buf[0..body_len];

    // Now build full message
    // Header
    builder.addStr(TAG_BEGIN_STRING, "FIX.4.2");
    builder.addU32(TAG_BODY_LENGTH, @intCast(body_len));

    // Copy body
    if (builder.pos + body_len > buf.len) return codec.CodecError.BufferTooSmall;
    @memcpy(buf[builder.pos..][0..body_len], body_data);
    builder.pos += body_len;

    // Checksum (calculated over everything before checksum field)
    const checksum = calculateChecksum(buf[0..builder.pos]);
    builder.addChecksum(checksum);

    return builder.pos;
}

fn encodeCancelRequest(cancel: *const msg.CancelMsg, buf: []u8) codec.CodecError!usize {
    var builder = FixBuilder.init(buf);

    var body_buf: [512]u8 = undefined;
    var body = FixBuilder.init(&body_buf);

    body.addChar(TAG_MSG_TYPE, MSG_TYPE_CANCEL);
    body.addU32(TAG_CL_ORD_ID, cancel.user_order_id); // Cancel request ID
    body.addU32(TAG_ORIG_CL_ORD_ID, cancel.user_order_id); // Order to cancel
    body.addU32(TAG_ACCOUNT, cancel.user_id);

    if (!msg.symbolIsEmpty(&cancel.symbol)) {
        body.addSymbol(TAG_SYMBOL, &cancel.symbol);
    }

    const body_len = body.pos;
    const body_data = body_buf[0..body_len];

    builder.addStr(TAG_BEGIN_STRING, "FIX.4.2");
    builder.addU32(TAG_BODY_LENGTH, @intCast(body_len));

    if (builder.pos + body_len > buf.len) return codec.CodecError.BufferTooSmall;
    @memcpy(buf[builder.pos..][0..body_len], body_data);
    builder.pos += body_len;

    const checksum = calculateChecksum(buf[0..builder.pos]);
    builder.addChecksum(checksum);

    return builder.pos;
}

// ============================================================================
// Output Message Encoding
// ============================================================================

/// Encode output message to FIX format (ExecutionReport).
pub fn encodeOutput(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    var builder = FixBuilder.init(buf);

    var body_buf: [1024]u8 = undefined;
    var body = FixBuilder.init(&body_buf);

    // All output messages become ExecutionReport
    body.addChar(TAG_MSG_TYPE, MSG_TYPE_EXEC_REPORT);

    switch (message.msg_type) {
        .ack => {
            const a = &message.data.ack;
            body.addU32(TAG_ORDER_ID, a.user_order_id);
            body.addU32(TAG_CL_ORD_ID, a.user_order_id);
            body.addU32(TAG_EXEC_ID, a.user_order_id);
            body.addChar(TAG_EXEC_TYPE, EXEC_TYPE_NEW);
            body.addChar(TAG_ORD_STATUS, ORD_STATUS_NEW);
            body.addSymbol(TAG_SYMBOL, &message.symbol);
            body.addU32(TAG_ACCOUNT, a.user_id);
        },

        .trade => {
            const t = &message.data.trade;
            body.addU32(TAG_ORDER_ID, t.buy_order_id);
            body.addU32(TAG_CL_ORD_ID, t.buy_order_id);
            body.addU32(TAG_EXEC_ID, t.buy_order_id); // Should be unique
            body.addChar(TAG_EXEC_TYPE, EXEC_TYPE_FILL);
            body.addChar(TAG_ORD_STATUS, ORD_STATUS_FILLED);
            body.addSymbol(TAG_SYMBOL, &message.symbol);
            body.addU32(TAG_LAST_PX, t.price);
            body.addU32(TAG_LAST_QTY, t.quantity);
            body.addU32(TAG_ACCOUNT, t.buy_user_id);
        },

        .cancel_ack => {
            const x = &message.data.cancel_ack;
            body.addU32(TAG_ORDER_ID, x.user_order_id);
            body.addU32(TAG_CL_ORD_ID, x.user_order_id);
            body.addU32(TAG_EXEC_ID, x.user_order_id);
            body.addChar(TAG_EXEC_TYPE, EXEC_TYPE_CANCELED);
            body.addChar(TAG_ORD_STATUS, ORD_STATUS_CANCELED);
            body.addSymbol(TAG_SYMBOL, &message.symbol);
            body.addU32(TAG_ACCOUNT, x.user_id);
        },

        .reject => {
            const r = &message.data.reject;
            body.addU32(TAG_ORDER_ID, r.user_order_id);
            body.addU32(TAG_CL_ORD_ID, r.user_order_id);
            body.addU32(TAG_EXEC_ID, r.user_order_id);
            body.addChar(TAG_EXEC_TYPE, EXEC_TYPE_REJECTED);
            body.addChar(TAG_ORD_STATUS, ORD_STATUS_REJECTED);
            body.addSymbol(TAG_SYMBOL, &message.symbol);
            body.addU32(TAG_ACCOUNT, r.user_id);
            body.addU32(TAG_ORD_REJ_REASON, mapRejectReasonToFix(r.reason));
            body.addStr(TAG_TEXT, r.reason.description());
        },

        .top_of_book => {
            // TopOfBook doesn't have a direct FIX equivalent
            // Could use MarketDataSnapshotFullRefresh (W) but that's complex
            return codec.CodecError.UnknownMessageType;
        },
    }

    const body_len = body.pos;
    const body_data = body_buf[0..body_len];

    builder.addStr(TAG_BEGIN_STRING, "FIX.4.2");
    builder.addU32(TAG_BODY_LENGTH, @intCast(body_len));

    if (builder.pos + body_len > buf.len) return codec.CodecError.BufferTooSmall;
    @memcpy(buf[builder.pos..][0..body_len], body_data);
    builder.pos += body_len;

    const checksum = calculateChecksum(buf[0..builder.pos]);
    builder.addChecksum(checksum);

    return builder.pos;
}

// ============================================================================
// FIX Message Builder
// ============================================================================

const FixBuilder = struct {
    buf: []u8,
    pos: usize,

    fn init(buf: []u8) FixBuilder {
        return .{ .buf = buf, .pos = 0 };
    }

    fn addTag(self: *FixBuilder, tag: u32) void {
        self.pos += codec.writeU32(self.buf[self.pos..], tag);
        self.buf[self.pos] = '=';
        self.pos += 1;
    }

    fn addDelim(self: *FixBuilder) void {
        self.buf[self.pos] = SOH;
        self.pos += 1;
    }

    fn addStr(self: *FixBuilder, tag: u32, value: []const u8) void {
        self.addTag(tag);
        @memcpy(self.buf[self.pos..][0..value.len], value);
        self.pos += value.len;
        self.addDelim();
    }

    fn addChar(self: *FixBuilder, tag: u32, value: u8) void {
        self.addTag(tag);
        self.buf[self.pos] = value;
        self.pos += 1;
        self.addDelim();
    }

    fn addU32(self: *FixBuilder, tag: u32, value: u32) void {
        self.addTag(tag);
        self.pos += codec.writeU32(self.buf[self.pos..], value);
        self.addDelim();
    }

    fn addSymbol(self: *FixBuilder, tag: u32, symbol: *const msg.Symbol) void {
        self.addTag(tag);
        self.pos += codec.writeSymbol(self.buf[self.pos..], symbol);
        self.addDelim();
    }

    fn addChecksum(self: *FixBuilder, checksum: u8) void {
        self.addTag(TAG_CHECKSUM);
        formatChecksum(checksum, self.buf[self.pos..][0..3]);
        self.pos += 3;
        self.addDelim();
    }
};

// ============================================================================
// Parsing Utilities
// ============================================================================

/// Detect delimiter used in message (SOH or pipe).
fn detectDelimiter(data: []const u8) u8 {
    // Look for first delimiter after "8=FIX"
    for (data) |c| {
        if (c == SOH) return SOH;
        if (c == PIPE) return PIPE;
    }
    return SOH;
}

/// Parse FIX message, extracting fields into ParsedFields.
fn parseMessage(data: []const u8, delimiter: u8, fields: *ParsedFields) codec.CodecError!usize {
    var pos: usize = 0;

    // Parse BeginString (tag 8)
    const begin_result = parseField(data, pos, delimiter);
    if (begin_result.tag != TAG_BEGIN_STRING) return codec.CodecError.MalformedMessage;
    fields.begin_string = begin_result.value;
    pos = begin_result.next_pos;

    // Parse BodyLength (tag 9)
    const length_result = parseField(data, pos, delimiter);
    if (length_result.tag != TAG_BODY_LENGTH) return codec.CodecError.MalformedMessage;
    fields.body_length = codec.parseU32(length_result.value) orelse return codec.CodecError.InvalidLength;
    pos = length_result.next_pos;

    // Body starts here
    fields.body_start = pos;

    // Parse remaining fields until checksum
    while (pos < data.len) {
        const field_result = parseField(data, pos, delimiter);
        if (field_result.tag == 0) break;

        switch (field_result.tag) {
            TAG_MSG_TYPE => {
                if (field_result.value.len > 0) {
                    fields.msg_type = field_result.value[0];
                }
            },
            TAG_CL_ORD_ID => fields.cl_ord_id = field_result.value,
            TAG_ORIG_CL_ORD_ID => fields.orig_cl_ord_id = field_result.value,
            TAG_SYMBOL => fields.symbol = field_result.value,
            TAG_SIDE => {
                if (field_result.value.len > 0) {
                    fields.side = field_result.value[0];
                }
            },
            TAG_ORDER_QTY => fields.order_qty = codec.parseU32(field_result.value),
            TAG_ORD_TYPE => {
                if (field_result.value.len > 0) {
                    fields.ord_type = field_result.value[0];
                }
            },
            TAG_PRICE => fields.price = codec.parseU32(field_result.value),
            TAG_ACCOUNT => fields.account = field_result.value,
            TAG_SENDER_COMP_ID => fields.sender_comp_id = field_result.value,
            TAG_TARGET_COMP_ID => fields.target_comp_id = field_result.value,
            TAG_MSG_SEQ_NUM => fields.msg_seq_num = codec.parseU32(field_result.value),
            TAG_CHECKSUM => {
                fields.checksum = field_result.value;
                fields.body_end = pos;
                return field_result.next_pos;
            },
            else => {},
        }

        pos = field_result.next_pos;
    }

    return codec.CodecError.IncompleteMessage;
}

const FieldResult = struct {
    tag: u32,
    value: []const u8,
    next_pos: usize,
};

fn parseField(data: []const u8, start: usize, delimiter: u8) FieldResult {
    if (start >= data.len) return .{ .tag = 0, .value = &.{}, .next_pos = start };

    // Find '='
    const eq_pos = std.mem.indexOfScalarPos(u8, data, start, '=') orelse
        return .{ .tag = 0, .value = &.{}, .next_pos = data.len };

    // Parse tag
    const tag_str = data[start..eq_pos];
    const tag = codec.parseU32(tag_str) orelse
        return .{ .tag = 0, .value = &.{}, .next_pos = data.len };

    // Find delimiter
    const value_start = eq_pos + 1;
    const value_end = std.mem.indexOfScalarPos(u8, data, value_start, delimiter) orelse data.len;

    return .{
        .tag = tag,
        .value = data[value_start..value_end],
        .next_pos = if (value_end < data.len) value_end + 1 else data.len,
    };
}

/// Parse ClOrdID - try numeric first, then hash if alphanumeric.
fn parseClOrdId(str: []const u8) u32 {
    // Try parsing as u32
    if (codec.parseU32(str)) |id| {
        return id;
    }

    // Fall back to FNV-1a hash
    var hash: u32 = 2166136261;
    for (str) |c| {
        hash ^= c;
        hash *%= 16777619;
    }
    return hash;
}

/// Calculate FIX checksum (sum of bytes mod 256).
pub fn calculateChecksum(data: []const u8) u8 {
    var sum: u32 = 0;
    for (data) |byte| {
        sum += byte;
    }
    return @intCast(sum & 0xFF);
}

/// Validate checksum in parsed message.
fn validateChecksum(data: []const u8, fields: *const ParsedFields) bool {
    const checksum_str = fields.checksum orelse return false;
    const expected = parseChecksumStr(checksum_str) orelse return false;

    // Checksum is calculated over everything up to (but not including) "10="
    const checksum_field_start = fields.body_end;
    if (checksum_field_start == 0) return false;

    const actual = calculateChecksum(data[0..checksum_field_start]);
    return actual == expected;
}

/// Format checksum as 3-digit string.
pub fn formatChecksum(checksum: u8, buf: *[3]u8) void {
    buf[0] = '0' + (checksum / 100);
    buf[1] = '0' + ((checksum / 10) % 10);
    buf[2] = '0' + (checksum % 10);
}

/// Parse checksum from 3-digit string.
pub fn parseChecksumStr(str: []const u8) ?u8 {
    if (str.len != 3) return null;

    var result: u16 = 0;
    for (str) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }

    if (result > 255) return null;
    return @intCast(result);
}

/// Find field value by tag in data slice.
pub fn findField(data: []const u8, tag: u32, delimiter: u8) ?[]const u8 {
    var tag_buf: [16]u8 = undefined;
    const tag_len = codec.writeU32(&tag_buf, tag);
    const tag_str = tag_buf[0..tag_len];

    var pos: usize = 0;
    while (pos < data.len) {
        const field_start = pos;

        const eq_pos = std.mem.indexOfScalarPos(u8, data, pos, '=') orelse break;

        if (std.mem.eql(u8, data[field_start..eq_pos], tag_str)) {
            const value_start = eq_pos + 1;
            const value_end = std.mem.indexOfScalarPos(u8, data, value_start, delimiter) orelse data.len;
            return data[value_start..value_end];
        }

        pos = std.mem.indexOfScalarPos(u8, data, eq_pos, delimiter) orelse break;
        pos += 1;
    }

    return null;
}

// ============================================================================
// Reject Reason Mapping
// ============================================================================

fn mapRejectReason(fix_code: u32) msg.RejectReason {
    return switch (fix_code) {
        REJ_REASON_UNKNOWN_SYMBOL => .unknown_symbol,
        REJ_REASON_DUPLICATE_ORDER => .duplicate_order_id,
        else => .invalid_quantity, // Default
    };
}

fn mapRejectReasonToFix(reason: msg.RejectReason) u32 {
    return switch (reason) {
        .unknown_symbol => REJ_REASON_UNKNOWN_SYMBOL,
        .duplicate_order_id => REJ_REASON_DUPLICATE_ORDER,
        else => REJ_REASON_OTHER,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "calculateChecksum" {
    const data = "8=FIX.4.2\x019=5\x0135=0\x01";
    const checksum = calculateChecksum(data);
    try std.testing.expect(checksum > 0);
}

test "formatChecksum" {
    var buf: [3]u8 = undefined;

    formatChecksum(0, &buf);
    try std.testing.expectEqualStrings("000", &buf);

    formatChecksum(123, &buf);
    try std.testing.expectEqualStrings("123", &buf);

    formatChecksum(255, &buf);
    try std.testing.expectEqualStrings("255", &buf);
}

test "parseChecksumStr" {
    try std.testing.expectEqual(@as(?u8, 0), parseChecksumStr("000"));
    try std.testing.expectEqual(@as(?u8, 123), parseChecksumStr("123"));
    try std.testing.expectEqual(@as(?u8, 255), parseChecksumStr("255"));
    try std.testing.expectEqual(@as(?u8, null), parseChecksumStr("256"));
    try std.testing.expectEqual(@as(?u8, null), parseChecksumStr("12"));
    try std.testing.expectEqual(@as(?u8, null), parseChecksumStr("abc"));
}

test "findField" {
    const data = "8=FIX.4.2|9=123|35=D|55=IBM|";

    try std.testing.expectEqualStrings("FIX.4.2", findField(data, 8, '|').?);
    try std.testing.expectEqualStrings("123", findField(data, 9, '|').?);
    try std.testing.expectEqualStrings("D", findField(data, 35, '|').?);
    try std.testing.expectEqualStrings("IBM", findField(data, 55, '|').?);
    try std.testing.expectEqual(@as(?[]const u8, null), findField(data, 99, '|'));
}

test "parseClOrdId - numeric" {
    try std.testing.expectEqual(@as(u32, 12345), parseClOrdId("12345"));
    try std.testing.expectEqual(@as(u32, 0), parseClOrdId("0"));
}

test "parseClOrdId - alphanumeric" {
    // Should return a hash
    const hash1 = parseClOrdId("ORDER-001");
    const hash2 = parseClOrdId("ORDER-001");
    const hash3 = parseClOrdId("ORDER-002");

    try std.testing.expectEqual(hash1, hash2); // Same input = same hash
    try std.testing.expect(hash1 != hash3); // Different input = different hash
}

test "encode NewOrderSingle" {
    const order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 12345,
        .price = 10000,
        .quantity = 100,
        .side = .buy,
        .symbol = msg.makeSymbol("IBM"),
    };

    const input = msg.InputMsg{
        .msg_type = .new_order,
        .data = .{ .new_order = order },
    };

    var buf: [512]u8 = undefined;
    const len = try encodeInput(&input, &buf);

    // Verify it starts with FIX header
    try std.testing.expect(std.mem.startsWith(u8, buf[0..len], "8=FIX.4.2\x01"));

    // Verify checksum field is present
    const checksum_tag = "10=";
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], checksum_tag) != null);
}

test "encode ExecutionReport (Ack)" {
    const ack = msg.OutputMsg.makeAck(1, 12345, msg.makeSymbol("IBM"), 0);

    var buf: [512]u8 = undefined;
    const len = try encodeOutput(&ack, &buf);

    // Verify header
    try std.testing.expect(std.mem.startsWith(u8, buf[0..len], "8=FIX.4.2\x01"));

    // Verify message type is ExecutionReport
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "\x0135=8\x01") != null);

    // Verify ExecType=0 (New)
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "\x01150=0\x01") != null);
}

test "roundtrip NewOrderSingle" {
    const order = msg.NewOrderMsg{
        .user_id = 42,
        .user_order_id = 99999,
        .price = 5000,
        .quantity = 50,
        .side = .sell,
        .symbol = msg.makeSymbol("AAPL"),
    };

    const input = msg.InputMsg{
        .msg_type = .new_order,
        .data = .{ .new_order = order },
    };

    var buf: [512]u8 = undefined;
    const len = try encodeInput(&input, &buf);

    const result = try decodeInput(buf[0..len]);

    try std.testing.expectEqual(msg.InputMsgType.new_order, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 99999), result.message.data.new_order.user_order_id);
    try std.testing.expectEqual(@as(u32, 5000), result.message.data.new_order.price);
    try std.testing.expectEqual(@as(u32, 50), result.message.data.new_order.quantity);
    try std.testing.expectEqual(msg.Side.sell, result.message.data.new_order.side);
}

test "decode with pipe delimiter" {
    // Human-readable format with pipes
    const data = "8=FIX.4.2|9=73|35=D|1=42|11=12345|55=IBM|54=1|38=100|40=2|44=5000|10=178|";

    const result = try decodeInput(data);

    try std.testing.expectEqual(msg.InputMsgType.new_order, result.message.msg_type);
    try std.testing.expectEqual(@as(u32, 12345), result.message.data.new_order.user_order_id);
    try std.testing.expectEqual(msg.Side.buy, result.message.data.new_order.side);
}

test "detectDelimiter" {
    try std.testing.expectEqual(SOH, detectDelimiter("8=FIX.4.2\x019=123"));
    try std.testing.expectEqual(PIPE, detectDelimiter("8=FIX.4.2|9=123"));
}
