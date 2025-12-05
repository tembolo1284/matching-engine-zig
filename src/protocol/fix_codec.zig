//! FIX Protocol codec (stub implementation).
//!
//! STATUS: NOT IMPLEMENTED
//!
//! This is a placeholder for FIX 4.2/4.4 protocol support.
//! All functions return UnknownMessageType error.
//!
//! FIX Protocol Overview:
//! - Tag=Value format with SOH (0x01) delimiter
//! - BeginString (8), BodyLength (9), MsgType (35), Checksum (10)
//! - Order messages: NewOrderSingle (D), OrderCancelRequest (F)
//! - Execution reports: ExecutionReport (8)
//!
//! TODO:
//! - [ ] Implement message parsing
//! - [ ] Implement message encoding
//! - [ ] Add checksum validation
//! - [ ] Support session management (Logon, Logout, Heartbeat)

const std = @import("std");
const msg = @import("message_types.zig");
const codec = @import("codec.zig");

// ============================================================================
// FIX Constants
// ============================================================================

/// FIX field delimiter (SOH = Start of Header).
pub const SOH: u8 = 0x01;

/// Alternative delimiter for human-readable logs.
pub const PIPE: u8 = '|';

// FIX Tags
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
pub const TAG_SYMBOL: u32 = 55;
pub const TAG_SIDE: u32 = 54;
pub const TAG_ORDER_QTY: u32 = 38;
pub const TAG_ORD_TYPE: u32 = 40;
pub const TAG_PRICE: u32 = 44;

// Execution Report Tags
pub const TAG_ORDER_ID: u32 = 37;
pub const TAG_EXEC_ID: u32 = 17;
pub const TAG_EXEC_TYPE: u32 = 150;
pub const TAG_ORD_STATUS: u32 = 39;
pub const TAG_LAST_PX: u32 = 31;
pub const TAG_LAST_QTY: u32 = 32;

// Message Types
pub const MSG_TYPE_NEW_ORDER: []const u8 = "D";
pub const MSG_TYPE_CANCEL: []const u8 = "F";
pub const MSG_TYPE_EXEC_REPORT: []const u8 = "8";
pub const MSG_TYPE_LOGON: []const u8 = "A";
pub const MSG_TYPE_LOGOUT: []const u8 = "5";
pub const MSG_TYPE_HEARTBEAT: []const u8 = "0";

// ============================================================================
// Stub Functions (Not Implemented)
// ============================================================================

/// Decode FIX input message.
/// STATUS: NOT IMPLEMENTED - returns error.
pub fn decodeInput(data: []const u8) codec.CodecError!codec.DecodeResult {
    _ = data;
    return codec.CodecError.UnknownMessageType;
}

/// Decode FIX output message.
/// STATUS: NOT IMPLEMENTED - returns error.
pub fn decodeOutput(data: []const u8) codec.CodecError!codec.OutputDecodeResult {
    _ = data;
    return codec.CodecError.UnknownMessageType;
}

/// Encode input message to FIX format.
/// STATUS: NOT IMPLEMENTED - returns error.
pub fn encodeInput(message: *const msg.InputMsg, buf: []u8) codec.CodecError!usize {
    _ = message;
    _ = buf;
    return codec.CodecError.UnknownMessageType;
}

/// Encode output message to FIX format.
/// STATUS: NOT IMPLEMENTED - returns error.
pub fn encodeOutput(message: *const msg.OutputMsg, buf: []u8) codec.CodecError!usize {
    _ = message;
    _ = buf;
    return codec.CodecError.UnknownMessageType;
}

// ============================================================================
// Utility Functions (Implemented)
// ============================================================================

/// Calculate FIX checksum (sum of bytes mod 256).
pub fn calculateChecksum(data: []const u8) u8 {
    var sum: u32 = 0;
    for (data) |byte| {
        sum += byte;
    }
    return @intCast(sum & 0xFF);
}

/// Format checksum as 3-digit string.
pub fn formatChecksum(checksum: u8, buf: *[3]u8) void {
    buf[0] = '0' + (checksum / 100);
    buf[1] = '0' + ((checksum / 10) % 10);
    buf[2] = '0' + (checksum % 10);
}

/// Parse checksum from 3-digit string.
pub fn parseChecksum(str: []const u8) ?u8 {
    if (str.len != 3) return null;

    var result: u16 = 0;
    for (str) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }

    if (result > 255) return null;
    return @intCast(result);
}

/// Find field value by tag.
pub fn findField(data: []const u8, tag: u32, delimiter: u8) ?[]const u8 {
    var tag_buf: [16]u8 = undefined;
    const tag_len = std.fmt.formatIntBuf(&tag_buf, tag, 10, .lower, .{});
    const tag_str = tag_buf[0..tag_len];

    var pos: usize = 0;
    while (pos < data.len) {
        // Find next delimiter or start
        const field_start = pos;

        // Find '='
        const eq_pos = std.mem.indexOfScalarPos(u8, data, pos, '=') orelse break;

        // Check if tag matches
        if (std.mem.eql(u8, data[field_start..eq_pos], tag_str)) {
            // Find end of value
            const value_start = eq_pos + 1;
            const value_end = std.mem.indexOfScalarPos(u8, data, value_start, delimiter) orelse data.len;
            return data[value_start..value_end];
        }

        // Move to next field
        pos = std.mem.indexOfScalarPos(u8, data, eq_pos, delimiter) orelse break;
        pos += 1;
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "calculateChecksum" {
    // "8=FIX.4.2|9=5|35=0|" should have known checksum
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

test "parseChecksum" {
    try std.testing.expectEqual(@as(?u8, 0), parseChecksum("000"));
    try std.testing.expectEqual(@as(?u8, 123), parseChecksum("123"));
    try std.testing.expectEqual(@as(?u8, 255), parseChecksum("255"));
    try std.testing.expectEqual(@as(?u8, null), parseChecksum("256"));
    try std.testing.expectEqual(@as(?u8, null), parseChecksum("12"));
    try std.testing.expectEqual(@as(?u8, null), parseChecksum("abc"));
}

test "findField" {
    const data = "8=FIX.4.2|9=123|35=D|55=IBM|";

    try std.testing.expectEqualStrings("FIX.4.2", findField(data, 8, '|').?);
    try std.testing.expectEqualStrings("123", findField(data, 9, '|').?);
    try std.testing.expectEqualStrings("D", findField(data, 35, '|').?);
    try std.testing.expectEqualStrings("IBM", findField(data, 55, '|').?);
    try std.testing.expectEqual(@as(?[]const u8, null), findField(data, 99, '|'));
}

test "stub functions return error" {
    const result1 = decodeInput("8=FIX.4.2");
    try std.testing.expectError(codec.CodecError.UnknownMessageType, result1);

    const result2 = decodeOutput("8=FIX.4.2");
    try std.testing.expectError(codec.CodecError.UnknownMessageType, result2);

    var buf: [256]u8 = undefined;
    const order = msg.InputMsg.flush();
    const result3 = encodeInput(&order, &buf);
    try std.testing.expectError(codec.CodecError.UnknownMessageType, result3);
}
