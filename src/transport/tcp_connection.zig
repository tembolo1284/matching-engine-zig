//! TCP Connection - Per-Client Connection State
//!
//! Manages:
//! - Socket I/O
//! - Message framing/parsing
//! - Protocol detection
//! - Send/receive buffers
//!
//! Design principles:
//! - No dynamic allocation (Rule 3)
//! - Bounded operations (Rule 2)
//! - Clear state management
const std = @import("std");
const net = std.net;
const posix = std.posix;
const framing = @import("framing.zig");
const msg = @import("../protocol/message_types.zig");

// ============================================================================
// Configuration
// ============================================================================

/// Send buffer size - large enough for thousands of messages
pub const SEND_BUFFER_SIZE: usize = 65536;

/// Maximum pending sends before we consider connection slow
pub const MAX_PENDING_SENDS: usize = 10000;

// ============================================================================
// Connection State
// ============================================================================

pub const ConnectionState = enum {
    connecting,
    connected,
    disconnecting,
    disconnected,

    pub fn isActive(self: ConnectionState) bool {
        return self == .connected;
    }
};

// ============================================================================
// Connection Statistics
// ============================================================================

pub const ConnectionStats = struct {
    bytes_received: u64,
    bytes_sent: u64,
    messages_received: u64,
    messages_sent: u64,
    send_errors: u64,
    recv_errors: u64,
    send_buffer_full: u64,
    connect_time_ns: i128,

    pub fn init() ConnectionStats {
        return ConnectionStats{
            .bytes_received = 0,
            .bytes_sent = 0,
            .messages_received = 0,
            .messages_sent = 0,
            .send_errors = 0,
            .recv_errors = 0,
            .send_buffer_full = 0,
            .connect_time_ns = std.time.nanoTimestamp(),
        };
    }
};

// ============================================================================
// Send Buffer
// ============================================================================

const SendBuffer = struct {
    data: [SEND_BUFFER_SIZE]u8,
    len: usize,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .data = undefined,
            .len = 0,
        };
    }

    pub fn reset(self: *Self) void {
        self.len = 0;
    }

    pub fn available(self: *const Self) usize {
        return SEND_BUFFER_SIZE - self.len;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.len == 0;
    }

    pub fn append(self: *Self, data: []const u8) usize {
        const to_copy = @min(data.len, self.available());
        if (to_copy > 0) {
            @memcpy(self.data[self.len..][0..to_copy], data[0..to_copy]);
            self.len += to_copy;
        }
        return to_copy;
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.data[0..self.len];
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
};

// ============================================================================
// TCP Connection
// ============================================================================

pub const TcpConnection = struct {
    /// Client ID (unique identifier)
    client_id: u32,

    /// Socket stream
    stream: net.Stream,

    /// Connection state
    state: ConnectionState,

    /// Stream parser for incoming messages
    parser: framing.StreamParser,

    /// Send buffer for outgoing messages
    send_buffer: SendBuffer,

    /// Statistics
    stats: ConnectionStats,

    /// Client address (for logging)
    address: net.Address,

    /// Pending output messages count
    pending_sends: usize,

    const Self = @This();

    /// Create connection from accepted socket
    pub fn init(client_id: u32, stream: net.Stream, address: net.Address) Self {
        return Self{
            .client_id = client_id,
            .stream = stream,
            .state = .connected,
            .parser = framing.StreamParser.init(),
            .send_buffer = SendBuffer.init(),
            .stats = ConnectionStats.init(),
            .address = address,
            .pending_sends = 0,
        };
    }

    /// Close connection
    pub fn close(self: *Self) void {
        if (self.state == .disconnected) return;
        self.state = .disconnecting;
        self.stream.close();
        self.state = .disconnected;
    }

    /// Check if connection is active
    pub fn isActive(self: *const Self) bool {
        return self.state.isActive();
    }

    /// Get detected protocol
    pub fn getProtocol(self: *const Self) framing.Protocol {
        return self.parser.getProtocol();
    }

    /// Try to receive data from socket
    ///
    /// Returns true if data was received, false on error or would-block.
    pub fn tryReceive(self: *Self) !bool {
        if (!self.isActive()) return false;

        var recv_buf: [framing.READ_BUFFER_SIZE]u8 = undefined;

        const bytes_read = self.stream.read(&recv_buf) catch |err| {
            switch (err) {
                error.WouldBlock => return false,
                error.ConnectionResetByPeer,
                error.BrokenPipe,
                => {
                    self.state = .disconnecting;
                    return false;
                },
                else => {
                    self.stats.recv_errors += 1;
                    return err;
                },
            }
        };

        if (bytes_read == 0) {
            // Connection closed by peer
            self.state = .disconnecting;
            return false;
        }

        _ = self.parser.feed(recv_buf[0..bytes_read]);
        self.stats.bytes_received += bytes_read;
        return true;
    }

    /// Get next parsed message (if available)
    pub fn nextMessage(self: *Self) ?msg.InputMsg {
        const message = self.parser.nextMessage();
        if (message != null) {
            self.stats.messages_received += 1;
        }
        return message;
    }

    /// Queue output message for sending
    ///
    /// Returns true if message was queued, false if buffer full.
    pub fn queueMessage(self: *Self, output: *const msg.OutputMsg) bool {
        if (!self.isActive()) return false;

        const protocol = self.getProtocol();
        if (protocol == .unknown) {
            // Default to binary if protocol not yet detected
            return self.queueMessageWithProtocol(output, .binary);
        }
        return self.queueMessageWithProtocol(output, protocol);
    }

    /// Queue message with specific protocol
    pub fn queueMessageWithProtocol(self: *Self, output: *const msg.OutputMsg, protocol: framing.Protocol) bool {
        var encode_buf: [256]u8 = undefined;
        const encoded_len = framing.encodeOutput(output, protocol, &encode_buf) catch {
            return false;
        };

        if (encoded_len == 0) {
            // Some messages (like TOB in FIX) may not encode
            return true;
        }

        // Try to send existing data first to make room
        if (self.send_buffer.available() < encoded_len) {
            _ = self.trySend() catch {};
        }

        // Try again after potential flush
        if (self.send_buffer.available() < encoded_len) {
            self.stats.send_buffer_full += 1;
            return false; // Still no space
        }

        _ = self.send_buffer.append(encode_buf[0..encoded_len]);
        self.pending_sends += 1;
        self.stats.messages_sent += 1;
        return true;
    }

    /// Try to send buffered data
    ///
    /// Returns number of bytes sent.
    pub fn trySend(self: *Self) !usize {
        if (!self.isActive()) return 0;
        if (self.send_buffer.isEmpty()) return 0;

        const data = self.send_buffer.slice();

        const bytes_sent = self.stream.write(data) catch |err| {
            switch (err) {
                error.WouldBlock => return 0,
                error.ConnectionResetByPeer,
                error.BrokenPipe,
                => {
                    self.state = .disconnecting;
                    return 0;
                },
                else => {
                    self.stats.send_errors += 1;
                    return err;
                },
            }
        };

        if (bytes_sent > 0) {
            self.send_buffer.consume(bytes_sent);
            self.stats.bytes_sent += bytes_sent;
        }

        return bytes_sent;
    }

    /// Flush all pending data (blocking)
    pub fn flush(self: *Self) !void {
        while (!self.send_buffer.isEmpty() and self.isActive()) {
            const sent = try self.trySend();
            if (sent == 0) {
                // Would block - yield and retry
                std.Thread.yield() catch {};
            }
        }
    }

    /// Check if there's pending data to send
    pub fn hasPendingData(self: *const Self) bool {
        return !self.send_buffer.isEmpty();
    }

    /// Check if connection has pending input data
    pub fn hasPendingInput(self: *const Self) bool {
        return self.parser.hasPendingData();
    }

    /// Get number of bytes pending in send buffer
    pub fn getPendingBytes(self: *const Self) usize {
        return self.send_buffer.len;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) ConnectionStats {
        return self.stats;
    }

    /// Get socket file descriptor (for polling)
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.stream.handle;
    }

    /// Set socket to non-blocking mode
    pub fn setNonBlocking(self: *Self, non_blocking: bool) !void {
        const flags = try posix.fcntl(self.stream.handle, posix.F.GETFL, 0);
        const new_flags = if (non_blocking)
            flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))
        else
            flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(self.stream.handle, posix.F.SETFL, new_flags);
    }

    /// Set TCP_NODELAY (disable Nagle's algorithm)
    pub fn setNoDelay(self: *Self, no_delay: bool) !void {
        const value: u32 = if (no_delay) 1 else 0;
        try posix.setsockopt(
            self.stream.handle,
            posix.IPPROTO.TCP,
            posix.TCP.NODELAY,
            &std.mem.toBytes(value),
        );
    }
};

// ============================================================================
// Tests
// ============================================================================

test "send buffer operations" {
    var buf = SendBuffer.init();
    try std.testing.expect(buf.isEmpty());
    try std.testing.expectEqual(@as(usize, SEND_BUFFER_SIZE), buf.available());

    const data = "Hello World";
    const appended = buf.append(data);
    try std.testing.expectEqual(@as(usize, 11), appended);
    try std.testing.expect(!buf.isEmpty());
    try std.testing.expectEqualStrings("Hello World", buf.slice());

    buf.consume(6);
    try std.testing.expectEqualStrings("World", buf.slice());

    buf.reset();
    try std.testing.expect(buf.isEmpty());
}

test "connection state" {
    try std.testing.expect(ConnectionState.connected.isActive());
    try std.testing.expect(!ConnectionState.disconnected.isActive());
    try std.testing.expect(!ConnectionState.disconnecting.isActive());
}

test "connection stats init" {
    const stats = ConnectionStats.init();
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_received);
    try std.testing.expectEqual(@as(u64, 0), stats.messages_sent);
    try std.testing.expect(stats.connect_time_ns > 0);
}
