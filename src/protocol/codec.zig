//! Protocol detection and common codec types.
//!
//! Magic byte scheme (matching C spec):
//!   0x4D ('M') - Binary protocol
//!   '8'        - FIX protocol (starts with "8=FIX")
//!   'N','C','F' - CSV protocol (message type chars)

const std = @import("std");
const msg = @import("message_types.zig");

// ============================================================================
// Protocol Types
// ============================================================================

pub const Protocol = enum {
    binary,
    csv,
    fix,
    unknown,
};

/// Magic byte for binary protocol (matches C: 0x4D = 'M')
pub const BINARY_MAGIC: u8 = 0x4D;
pub const FIX_START: u8 = '8';

// ============================================================================
// Codec Errors
// ============================================================================

pub const CodecError = error{
    BufferTooSmall,
    InvalidMessage,
    InvalidMagic,
    InvalidLength,
    InvalidField,
    InvalidChecksum,
    UnknownMessageType,
    MalformedMessage,
    IncompleteMessage,
};

// ============================================================================
// Protocol Detection
// ============================================================================

/// Detect protocol from first byte(s)
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

    // CSV output messages
    if (first == 'A' or first == 'T' or first == 'B' or first == 'X' or first == 'R') return .csv;

    return .unknown;
}

// ============================================================================
// Decode Results
// ============================================================================

pub const DecodeResult = struct {
    message: msg.InputMsg,
    bytes_consumed: usize,
};

pub const OutputDecodeResult = struct {
    message: msg.OutputMsg,
    bytes_consumed: usize,
};

// ============================================================================
// Unified Codec Interface
// ============================================================================

pub const Codec = struct {
    protocol: Protocol,

    const Self = @This();

    pub fn init(protocol: Protocol) Self {
        return .{ .protocol = protocol };
    }

    /// Auto-detect and decode input message
    pub fn decodeInput(data: []const u8) CodecError!DecodeResult {
        const proto = detectProtocol(data);
        return switch (proto) {
            .binary => @import("binary_codec.zig").decode(data),
            .csv => @import("csv_codec.zig").decodeInput(data),
            .fix => @import("fix_codec.zig").decodeInput(data),
            .unknown => CodecError.UnknownMessageType,
        };
    }

    /// Auto-detect and decode output message (for UDP responses)
    pub fn decodeOutput(data: []const u8) CodecError!OutputDecodeResult {
        const proto = detectProtocol(data);
        return switch (proto) {
            .binary => @import("binary_codec.zig").decodeOutput(data),
            .csv => @import("csv_codec.zig").decodeOutput(data),
            .fix => @import("fix_codec.zig").decodeOutput(data),
            .unknown => CodecError.UnknownMessageType,
        };
    }

    /// Encode input message to specified protocol
    pub fn encodeInput(self: Self, message: *const msg.InputMsg, buf: []u8) CodecError!usize {
        return switch (self.protocol) {
            .binary => @import("binary_codec.zig").encode(message, buf),
            .csv => @import("csv_codec.zig").encodeInput(message, buf),
            .fix => @import("fix_codec.zig").encodeInput(message, buf),
            .unknown => CodecError.UnknownMessageType,
        };
    }

    /// Encode output message to specified protocol
    pub fn encodeOutput(self: Self, message: *const msg.OutputMsg, buf: []u8) CodecError!usize {
        return switch (self.protocol) {
            .binary => @import("binary_codec.zig").encodeOutput(message, buf),
            .csv => @import("csv_codec.zig").encodeOutput(message, buf),
            .fix => @import("fix_codec.zig").encodeOutput(message, buf),
            .unknown => CodecError.UnknownMessageType,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Parse u32 from decimal string
pub fn parseU32(str: []const u8) ?u32 {
    if (str.len == 0) return null;

    var result: u32 = 0;
    for (str) |c| {
        if (c < '0' or c > '9') return null;
        result = result *% 10 +% (c - '0');
    }
    return result;
}

/// Write u32 as decimal string, returns bytes written
pub fn writeU32(buf: []u8, value: u32) usize {
    if (value == 0) {
        if (buf.len > 0) buf[0] = '0';
        return 1;
    }

    var tmp: [10]u8 = undefined;
    var len: usize = 0;
    var v = value;

    while (v > 0) : (len += 1) {
        tmp[len] = @intCast((v % 10) + '0');
        v /= 10;
    }

    if (buf.len < len) return 0;

    // Reverse into buffer
    for (0..len) |i| {
        buf[i] = tmp[len - 1 - i];
    }

    return len;
}

/// Copy symbol to buffer, returns bytes written
pub fn writeSymbol(buf: []u8, symbol: msg.Symbol) usize {
    var len: usize = 0;
    for (symbol) |c| {
        if (c == 0) break;
        if (len >= buf.len) break;
        buf[len] = c;
        len += 1;
    }
    return len;
}

// ============================================================================
// Tests
// ============================================================================

test "protocol detection" {
    try std.testing.expectEqual(Protocol.binary, detectProtocol(&[_]u8{ 0x4D, 'N' }));
    try std.testing.expectEqual(Protocol.csv, detectProtocol("N, 1, IBM, 100, 50, B, 1"));
    try std.testing.expectEqual(Protocol.fix, detectProtocol("8=FIX.4.2|9=123"));
    try std.testing.expectEqual(Protocol.unknown, detectProtocol(&[_]u8{0xFF}));
}

test "parseU32" {
    try std.testing.expectEqual(@as(?u32, 12345), parseU32("12345"));
    try std.testing.expectEqual(@as(?u32, 0), parseU32("0"));
    try std.testing.expectEqual(@as(?u32, null), parseU32(""));
    try std.testing.expectEqual(@as(?u32, null), parseU32("abc"));
}
