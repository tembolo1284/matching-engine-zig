//! Protocol detection and unified codec interface.
//!
//! Supported protocols:
//! - **Binary**: Low-latency, fixed-size messages (magic 0x4D)
//! - **CSV**: Human-readable, newline-delimited
//! - **FIX**: FIX 4.2 compatible (partial implementation)
//!
//! Protocol detection:
//! ```
//! First byte(s)     Protocol
//! ─────────────────────────────
//! 0x4D ('M')        Binary
//! "8=FIX"           FIX
//! 'N','C','F'       CSV (input)
//! 'A','T','B','X','R' CSV (output)
//! ```
//!
//! Usage:
//! ```zig
//! // Auto-detect and decode
//! const result = try Codec.decodeInput(data);
//!
//! // Encode with specific protocol
//! var codec = Codec.init(.binary);
//! const len = try codec.encodeInput(&msg, &buf);
//! ```

const std = @import("std");
const msg = @import("message_types.zig");

// ============================================================================
// Protocol Types
// ============================================================================

/// Supported wire protocols.
pub const Protocol = enum(u8) {
    /// Binary protocol: magic byte + type + payload.
    binary,
    /// CSV protocol: comma-separated, newline-terminated.
    csv,
    /// FIX protocol: tag=value pairs.
    fix,
    /// Protocol not yet determined.
    unknown,

    /// Get human-readable name.
    pub fn name(self: Protocol) []const u8 {
        return switch (self) {
            .binary => "Binary",
            .csv => "CSV",
            .fix => "FIX",
            .unknown => "Unknown",
        };
    }
};

/// Binary protocol magic byte (0x4D = 'M').
pub const BINARY_MAGIC: u8 = 0x4D;

/// FIX protocol start byte ('8').
pub const FIX_START: u8 = '8';

// ============================================================================
// Error Types
// ============================================================================

/// Codec errors.
pub const CodecError = error{
    /// Output buffer too small.
    BufferTooSmall,
    /// Generic invalid message.
    InvalidMessage,
    /// Binary magic byte mismatch.
    InvalidMagic,
    /// Message length field invalid.
    InvalidLength,
    /// Field value invalid.
    InvalidField,
    /// Checksum mismatch (FIX).
    InvalidChecksum,
    /// Unknown message type byte.
    UnknownMessageType,
    /// Message structure invalid.
    MalformedMessage,
    /// Need more data.
    IncompleteMessage,
    /// Integer overflow during parsing.
    Overflow,
};

// ============================================================================
// Decode Results
// ============================================================================

/// Result of decoding an input message.
pub const DecodeResult = struct {
    /// Decoded message.
    message: msg.InputMsg,
    /// Bytes consumed from input.
    bytes_consumed: usize,
};

/// Result of decoding an output message.
pub const OutputDecodeResult = struct {
    /// Decoded message.
    message: msg.OutputMsg,
    /// Bytes consumed from input.
    bytes_consumed: usize,
};

// ============================================================================
// Protocol Detection
// ============================================================================

/// Detect protocol from first byte(s) of data.
pub fn detectProtocol(data: []const u8) Protocol {
    if (data.len == 0) return .unknown;

    const first = data[0];

    // Binary: starts with magic byte 0x4D ('M')
    if (first == BINARY_MAGIC) return .binary;

    // FIX: starts with "8=FIX"
    if (first == FIX_START and data.len >= 5) {
        if (std.mem.startsWith(u8, data, "8=FIX")) return .fix;
    }

    // CSV input: starts with message type letter
    if (first == 'N' or first == 'C' or first == 'F') return .csv;

    // CSV output: starts with output message type
    if (first == 'A' or first == 'T' or first == 'B' or first == 'X' or first == 'R') return .csv;

    return .unknown;
}

// ============================================================================
// Unified Codec Interface
// ============================================================================

/// Unified codec for encoding/decoding messages.
pub const Codec = struct {
    /// Protocol to use for encoding.
    protocol: Protocol,

    const Self = @This();

    /// Initialize codec with specific protocol.
    pub fn init(protocol: Protocol) Self {
        std.debug.assert(protocol != .unknown);
        return .{ .protocol = protocol };
    }

    /// Auto-detect protocol and decode input message.
    pub fn decodeInput(data: []const u8) CodecError!DecodeResult {
        const proto = detectProtocol(data);
        return switch (proto) {
            .binary => @import("binary_codec.zig").decode(data),
            .csv => @import("csv_codec.zig").decodeInput(data),
            .fix => CodecError.UnknownMessageType, // FIX not implemented
            .unknown => CodecError.UnknownMessageType,
        };
    }

    /// Auto-detect protocol and decode output message.
    pub fn decodeOutput(data: []const u8) CodecError!OutputDecodeResult {
        const proto = detectProtocol(data);
        return switch (proto) {
            .binary => @import("binary_codec.zig").decodeOutput(data),
            .csv => @import("csv_codec.zig").decodeOutput(data),
            .fix => CodecError.UnknownMessageType, // FIX not implemented
            .unknown => CodecError.UnknownMessageType,
        };
    }

    /// Encode input message using configured protocol.
    pub fn encodeInput(self: Self, message: *const msg.InputMsg, buf: []u8) CodecError!usize {
        return switch (self.protocol) {
            .binary => @import("binary_codec.zig").encode(message, buf),
            .csv => @import("csv_codec.zig").encodeInput(message, buf),
            .fix => CodecError.UnknownMessageType, // FIX not implemented
            .unknown => CodecError.UnknownMessageType,
        };
    }

    /// Encode output message using configured protocol.
    pub fn encodeOutput(self: Self, message: *const msg.OutputMsg, buf: []u8) CodecError!usize {
        return switch (self.protocol) {
            .binary => @import("binary_codec.zig").encodeOutput(message, buf),
            .csv => @import("csv_codec.zig").encodeOutput(message, buf),
            .fix => CodecError.UnknownMessageType, // FIX not implemented
            .unknown => CodecError.UnknownMessageType,
        };
    }
};

// ============================================================================
// Parsing Utilities
// ============================================================================

/// Maximum digits in a u32.
const MAX_U32_DIGITS: usize = 10;

/// Parse u32 from decimal string.
/// Returns null if:
/// - String is empty
/// - Contains non-digit characters
/// - Value overflows u32
pub fn parseU32(str: []const u8) ?u32 {
    if (str.len == 0) return null;
    if (str.len > MAX_U32_DIGITS) return null;

    var result: u64 = 0; // Use u64 to detect overflow
    for (str) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
        if (result > std.math.maxInt(u32)) return null;
    }

    return @intCast(result);
}

/// Parse u64 from decimal string.
pub fn parseU64(str: []const u8) ?u64 {
    if (str.len == 0) return null;
    if (str.len > 20) return null;

    var result: u64 = 0;
    for (str) |c| {
        if (c < '0' or c > '9') return null;
        // Check for overflow before multiplication
        const digit: u64 = c - '0';
        if (result > (std.math.maxInt(u64) - digit) / 10) {
            return null;
        }
        result = result * 10 + digit;
    }

    return result;
}

/// Write u32 as decimal string.
/// Returns bytes written, or 0 if buffer too small.
pub fn writeU32(buf: []u8, value: u32) usize {
    if (value == 0) {
        if (buf.len == 0) return 0;
        buf[0] = '0';
        return 1;
    }

    // Build digits in reverse
    var tmp: [MAX_U32_DIGITS]u8 = undefined;
    var len: usize = 0;
    var v = value;

    while (v > 0) : (len += 1) {
        tmp[len] = @intCast((v % 10) + '0');
        v /= 10;
    }

    if (buf.len < len) return 0;

    // Reverse into output buffer
    for (0..len) |i| {
        buf[i] = tmp[len - 1 - i];
    }

    return len;
}

/// Write symbol to buffer (up to first null).
/// Returns bytes written.
pub fn writeSymbol(buf: []u8, symbol: *const msg.Symbol) usize {
    var len: usize = 0;
    for (symbol) |c| {
        if (c == 0) break;
        if (len >= buf.len) break;
        buf[len] = c;
        len += 1;
    }
    return len;
}

/// Trim whitespace from both ends of string.
pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;

    while (start < end and isWhitespace(s[start])) {
        start += 1;
    }

    while (end > start and isWhitespace(s[end - 1])) {
        end -= 1;
    }

    return s[start..end];
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// ============================================================================
// Tests
// ============================================================================

test "protocol detection - binary" {
    try std.testing.expectEqual(Protocol.binary, detectProtocol(&[_]u8{ 0x4D, 'N' }));
    try std.testing.expectEqual(Protocol.binary, detectProtocol(&[_]u8{0x4D}));
}

test "protocol detection - csv" {
    try std.testing.expectEqual(Protocol.csv, detectProtocol("N, 1, IBM, 100, 50, B, 1"));
    try std.testing.expectEqual(Protocol.csv, detectProtocol("C, 1, 100\n"));
    try std.testing.expectEqual(Protocol.csv, detectProtocol("F\n"));
    try std.testing.expectEqual(Protocol.csv, detectProtocol("A, IBM, 1, 100\n"));
    try std.testing.expectEqual(Protocol.csv, detectProtocol("T, IBM, 1, 100, 2, 200, 50, 100\n"));
}

test "protocol detection - fix" {
    try std.testing.expectEqual(Protocol.fix, detectProtocol("8=FIX.4.2|9=123"));
    try std.testing.expectEqual(Protocol.fix, detectProtocol("8=FIX.4.4\x019=100"));
}

test "protocol detection - unknown" {
    try std.testing.expectEqual(Protocol.unknown, detectProtocol(&[_]u8{0xFF}));
    try std.testing.expectEqual(Protocol.unknown, detectProtocol(&[_]u8{}));
    try std.testing.expectEqual(Protocol.unknown, detectProtocol("GARBAGE"));
}

test "parseU32 - valid" {
    try std.testing.expectEqual(@as(?u32, 0), parseU32("0"));
    try std.testing.expectEqual(@as(?u32, 12345), parseU32("12345"));
    try std.testing.expectEqual(@as(?u32, 4294967295), parseU32("4294967295"));
}

test "parseU32 - invalid" {
    try std.testing.expectEqual(@as(?u32, null), parseU32(""));
    try std.testing.expectEqual(@as(?u32, null), parseU32("abc"));
    try std.testing.expectEqual(@as(?u32, null), parseU32("12a34"));
    try std.testing.expectEqual(@as(?u32, null), parseU32("-1"));
}

test "parseU32 - overflow" {
    try std.testing.expectEqual(@as(?u32, null), parseU32("4294967296")); // u32 max + 1
    try std.testing.expectEqual(@as(?u32, null), parseU32("99999999999"));
}

test "writeU32" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 1), writeU32(&buf, 0));
    try std.testing.expectEqualStrings("0", buf[0..1]);

    try std.testing.expectEqual(@as(usize, 5), writeU32(&buf, 12345));
    try std.testing.expectEqualStrings("12345", buf[0..5]);

    try std.testing.expectEqual(@as(usize, 10), writeU32(&buf, 4294967295));
    try std.testing.expectEqualStrings("4294967295", buf[0..10]);
}

test "writeU32 - buffer too small" {
    var buf: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), writeU32(&buf, 12345));
}

test "trim" {
    try std.testing.expectEqualStrings("hello", trim("  hello  "));
    try std.testing.expectEqualStrings("hello", trim("\t\nhello\r\n"));
    try std.testing.expectEqualStrings("hello world", trim("  hello world  "));
    try std.testing.expectEqualStrings("", trim("   "));
}

test "Codec unified interface" {
    // Test encoding with specific protocol
    var codec = Codec.init(.csv);
    try std.testing.expectEqual(Protocol.csv, codec.protocol);

    const order = msg.InputMsg.newOrder(.{
        .user_id = 1,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 50,
        .symbol = msg.makeSymbol("IBM"),
        .side = .buy,
    });

    var buf: [256]u8 = undefined;
    const len = try codec.encodeInput(&order, &buf);
    try std.testing.expect(len > 0);

    // Verify auto-detect works
    const result = try Codec.decodeInput(buf[0..len]);
    try std.testing.expectEqual(msg.InputMsgType.new_order, result.message.msg_type);
}
