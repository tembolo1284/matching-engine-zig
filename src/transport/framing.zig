//! Message Framing - Protocol Detection and Message Boundary Parsing

const std = @import("std");
const binary = @import("../protocol/binary_codec.zig");
const fix = @import("../protocol/fix_codec.zig");
const msg = @import("../protocol/message_types.zig");

pub const MAX_MESSAGE_SIZE: usize = 4096;
pub const MIN_DETECT_BYTES: usize = 5; // Need at least length prefix + magic
pub const READ_BUFFER_SIZE: usize = 8192;
pub const LENGTH_PREFIX_SIZE: usize = 4;

// How many bytes we’re willing to skip in one call while trying to resync
// after corruption/overflow/partial frames. Keeps things bounded.
pub const MAX_RESYNC_STEPS: usize = 4096;

pub const Protocol = enum {
    unknown,
    binary,
    fix,

    pub fn toString(self: Protocol) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .binary => "binary",
            .fix => "FIX",
        };
    }
};

pub const FrameError = error{
    BufferTooSmall,
    InvalidProtocol,
    MessageTooLarge,
    IncompleteMessage,
    ParseError,
};

pub const FrameResult = struct {
    message: ?msg.InputMsg,
    bytes_consumed: usize,
    protocol: Protocol,
};

/// Detect protocol from data (handles length-prefixed binary)
pub fn detectProtocol(data: []const u8) Protocol {
    if (data.len < MIN_DETECT_BYTES) {
        return .unknown;
    }

    // Check for length-prefixed binary: first 4 bytes are length, then magic
    if (data.len >= 5) {
        // Length-prefixed binary: bytes 4 should be magic 0x4D
        if (data[4] == binary.BINARY_MAGIC) {
            return .binary;
        }
    }

    // Check for non-prefixed binary (magic at byte 0)
    if (data[0] == binary.BINARY_MAGIC) {
        return .binary;
    }

    // Check for FIX
    if (data.len >= 5 and std.mem.startsWith(u8, data, "8=FIX")) {
        return .fix;
    }

    if (data.len >= 2 and data[0] == '8' and data[1] == '=') {
        return .fix;
    }

    return .unknown;
}

/// Find message boundary in data
pub fn findMessageBoundary(data: []const u8, protocol: Protocol) ?usize {
    if (data.len < MIN_DETECT_BYTES) {
        return null;
    }

    return switch (protocol) {
        .binary => findBinaryMessageEnd(data),
        .fix => findFixMessageEnd(data),
        .unknown => null,
    };
}

fn findBinaryMessageEnd(data: []const u8) ?usize {
    if (data.len < 5) return null;

    // Check if length-prefixed (first 4 bytes are length, byte 4 is magic)
    if (data[4] == binary.BINARY_MAGIC) {
        // Length-prefixed format
        const msg_len = std.mem.readInt(u32, data[0..4], .big);
        const total_len = LENGTH_PREFIX_SIZE + msg_len;

        if (total_len > MAX_MESSAGE_SIZE) {
            return null;
        }

        if (data.len >= total_len) {
            return total_len;
        }
        return null;
    }

    // Non-prefixed format (magic at byte 0)
    if (data[0] != binary.BINARY_MAGIC) {
        return null;
    }

    if (data.len < 2) return null;

    const msg_type = data[1];
    const expected_size = binary.messageSize(msg_type);

    if (expected_size == 0) {
        return null;
    }

    if (data.len >= expected_size) {
        return expected_size;
    }

    return null;
}

fn findFixMessageEnd(data: []const u8) ?usize {
    return fix.findMessageEnd(data);
}

pub const FrameBuffer = struct {
    data: [READ_BUFFER_SIZE]u8,
    len: usize,
    protocol: Protocol,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .data = undefined,
            .len = 0,
            .protocol = .unknown,
        };
    }

    pub fn reset(self: *Self) void {
        self.len = 0;
        self.protocol = .unknown;
    }

    pub fn append(self: *Self, data: []const u8) usize {
        const space = READ_BUFFER_SIZE - self.len;
        const to_copy = @min(data.len, space);

        if (to_copy > 0) {
            @memcpy(self.data[self.len..][0..to_copy], data[0..to_copy]);
            self.len += to_copy;
        }

        return to_copy;
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.data[0..self.len];
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.len == 0;
    }

    pub fn isFull(self: *const Self) bool {
        return self.len >= READ_BUFFER_SIZE;
    }

    pub fn available(self: *const Self) usize {
        return READ_BUFFER_SIZE - self.len;
    }

    pub fn consume(self: *Self, count: usize) void {
        std.debug.assert(count <= self.len);

        if (count == self.len) {
            self.len = 0;
        } else if (count > 0) {
            const remaining = self.len - count;
            std.mem.copyForwards(u8, self.data[0..remaining], self.data[count..self.len]);
            self.len = remaining;
        }
    }

    pub fn detectBufferProtocol(self: *Self) Protocol {
        if (self.protocol == .unknown and self.len >= MIN_DETECT_BYTES) {
            self.protocol = detectProtocol(self.slice());
        }
        return self.protocol;
    }

    pub fn tryExtractMessage(self: *Self) FrameError!?msg.InputMsg {
        if (self.len < MIN_DETECT_BYTES) {
            return null;
        }

        if (self.protocol == .unknown) {
            self.protocol = detectProtocol(self.slice());

            if (self.protocol == .unknown) {
                return FrameError.InvalidProtocol;
            }
        }

        const boundary = findMessageBoundary(self.slice(), self.protocol) orelse {
            return null;
        };

        if (boundary > MAX_MESSAGE_SIZE) {
            return FrameError.MessageTooLarge;
        }

        const result = try decodeMessage(self.slice()[0..boundary], self.protocol);

        self.consume(boundary);

        return result;
    }
};

fn decodeMessage(data: []const u8, protocol: Protocol) FrameError!msg.InputMsg {
    return switch (protocol) {
        .binary => {
            // Check if length-prefixed
            if (data.len >= 5 and data[4] == binary.BINARY_MAGIC) {
                // Skip the 4-byte length prefix
                const payload = data[LENGTH_PREFIX_SIZE..];
                const result = binary.decodeInput(payload) catch {
                    return FrameError.ParseError;
                };
                return result.message;
            } else {
                // Non-prefixed
                const result = binary.decodeInput(data) catch {
                    return FrameError.ParseError;
                };
                return result.message;
            }
        },
        .fix => {
            const result = fix.decodeInput(data) catch {
                return FrameError.ParseError;
            };
            return result.message;
        },
        .unknown => FrameError.InvalidProtocol,
    };
}

pub fn encodeOutput(output: *const msg.OutputMsg, protocol: Protocol, buf: []u8) !usize {
    return switch (protocol) {
        .binary => {
            // Encode with length prefix for compatibility with C client
            if (buf.len < LENGTH_PREFIX_SIZE + binary.SIZE_TRADE) {
                return error.BufferTooSmall;
            }

            // Encode message after the length prefix
            const msg_len = binary.encodeOutput(output, buf[LENGTH_PREFIX_SIZE..]) catch {
                return error.BufferTooSmall;
            };

            // Write length prefix
            std.mem.writeInt(u32, buf[0..4], @intCast(msg_len), .big);

            return LENGTH_PREFIX_SIZE + msg_len;
        },
        .fix => fix.encodeOutput(output, buf) catch return error.BufferTooSmall,
        .unknown => error.InvalidProtocol,
    };
}

pub const StreamParser = struct {
    buffer: FrameBuffer,
    messages_parsed: u64,
    bytes_received: u64,
    parse_errors: u64,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .buffer = FrameBuffer.init(),
            .messages_parsed = 0,
            .bytes_received = 0,
            .parse_errors = 0,
        };
    }

    pub fn reset(self: *Self) void {
        self.buffer.reset();
    }

    pub fn getProtocol(self: *const Self) Protocol {
        return self.buffer.protocol;
    }

    pub fn feed(self: *Self, data: []const u8) usize {
        const consumed = self.buffer.append(data);
        self.bytes_received += consumed;
        return consumed;
    }

    /// Extract the next message if available.
    ///
    /// **Important behavior change (fix):**
    /// If we hit a parse error, we consume 1 byte and keep trying (bounded),
    /// instead of immediately returning null. This prevents “1 byte per poll”
    /// slow recovery under load and avoids the system appearing stuck.
    pub fn nextMessage(self: *Self) ?msg.InputMsg {
        var steps: usize = 0;

        while (steps < MAX_RESYNC_STEPS) : (steps += 1) {
            const result = self.buffer.tryExtractMessage() catch {
                self.parse_errors += 1;

                if (self.buffer.len > 0) {
                    self.buffer.consume(1);
                    // keep trying to resync within this call
                    continue;
                }

                return null;
            };

            if (result) |message| {
                self.messages_parsed += 1;
                return message;
            }

            // No complete message available (need more bytes)
            return null;
        }

        // Bounded resync limit hit; let outer loop/poll bring in more data.
        return null;
    }

    pub fn hasPendingData(self: *const Self) bool {
        return !self.buffer.isEmpty();
    }

    pub const Stats = struct {
        messages_parsed: u64,
        bytes_received: u64,
        parse_errors: u64,
        buffer_len: usize,
        protocol: Protocol,
    };

    pub fn getStats(self: *const Self) Stats {
        return Stats{
            .messages_parsed = self.messages_parsed,
            .bytes_received = self.bytes_received,
            .parse_errors = self.parse_errors,
            .buffer_len = self.buffer.len,
            .protocol = self.buffer.protocol,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "detect protocol binary with length prefix" {
    // Length prefix (27) + magic + msg_type
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x1b, binary.BINARY_MAGIC, binary.MSG_NEW_ORDER, 0, 0 };
    try std.testing.expectEqual(Protocol.binary, detectProtocol(&data));
}

test "detect protocol binary without prefix" {
    const data = [_]u8{ binary.BINARY_MAGIC, binary.MSG_NEW_ORDER, 0, 0, 0 };
    try std.testing.expectEqual(Protocol.binary, detectProtocol(&data));
}

test "detect protocol fix" {
    const data = "8=FIX.4.2|9=100|35=D|";
    try std.testing.expectEqual(Protocol.fix, detectProtocol(data));
}

test "detect protocol unknown" {
    const data = "Hello World!!!!!";
    try std.testing.expectEqual(Protocol.unknown, detectProtocol(data));
}

test "find binary message boundary with length prefix" {
    // Length = 10 (cancel message size)
    var data: [14]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 10, .big);
    data[4] = binary.BINARY_MAGIC;
    data[5] = binary.MSG_CANCEL;

    const boundary = findMessageBoundary(&data, .binary);
    try std.testing.expectEqual(@as(?usize, 14), boundary);
}

test "frame buffer append and consume" {
    var buf = FrameBuffer.init();

    const data = "Hello World";
    const appended = buf.append(data);

    try std.testing.expectEqual(@as(usize, 11), appended);
    try std.testing.expectEqual(@as(usize, 11), buf.len);
    try std.testing.expectEqualStrings("Hello World", buf.slice());

    buf.consume(6);

    try std.testing.expectEqual(@as(usize, 5), buf.len);
    try std.testing.expectEqualStrings("World", buf.slice());
}

test "frame buffer reset" {
    var buf = FrameBuffer.init();

    _ = buf.append("Some data");
    buf.protocol = .binary;

    buf.reset();

    try std.testing.expectEqual(@as(usize, 0), buf.len);
    try std.testing.expectEqual(Protocol.unknown, buf.protocol);
}

test "stream parser stats" {
    var parser = StreamParser.init();

    const stats = parser.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.messages_parsed);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_received);
}

