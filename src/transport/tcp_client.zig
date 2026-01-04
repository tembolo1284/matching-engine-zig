//! TCP client connection state and buffer management.
//!
//! Each TcpClient represents a single TCP connection with:
//! - Receive buffer with frame extraction (heap-allocated)
//! - Send buffer with optional length-prefix framing (heap-allocated)
//! - Protocol auto-detection
//! - Per-connection statistics
//! - Consecutive error tracking for disconnect decision
//!
//! Wire format (with framing enabled):
//! ```
//! +------------------+--------------------+
//! | Length (4B, BE)  | Payload (N bytes)  |
//! +------------------+--------------------+
//! ```
//!
//! Buffer management:
//! - Receive: Accumulate bytes, extract complete frames
//! - Send: Queue outbound data, flush when socket writable
//! - Buffers are heap-allocated to avoid stack overflow
//!
//! Thread Safety:
//! - NOT thread-safe. Each client owned by single I/O thread.
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: All loops bounded by capacity constants
//! - Rule 5: Assertions validate state and inputs
//! - Rule 7: All buffer operations bounds-checked

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const config = @import("config.zig");
const codec = @import("../protocol/codec.zig");
const net_utils = @import("net_utils.zig");

// ============================================================================
// Platform Detection
// ============================================================================

const is_linux = builtin.os.tag == .linux;

// MSG.NOSIGNAL doesn't exist on macOS - we ignore SIGPIPE at process level instead
const SEND_FLAGS: u32 = if (is_linux) posix.MSG.NOSIGNAL else 0;

// ============================================================================
// Configuration
// ============================================================================

/// Receive buffer size per client.
/// Must accommodate largest expected message plus some headroom.
pub const RECV_BUFFER_SIZE: u32 = 4 * 1024 * 1024;

/// Send buffer size per client.
/// Should handle burst of outbound messages.
pub const SEND_BUFFER_SIZE: u32 = 4 * 1024 * 1024;

/// Frame header size (4-byte length prefix).
pub const FRAME_HEADER_SIZE: u32 = 4;

/// Maximum allowed message size.
/// Prevents memory exhaustion from malformed length headers.
pub const MAX_MESSAGE_SIZE: u32 = 4 * 16384;

/// Maximum consecutive decode errors before disconnect.
/// Prevents infinite loops on malformed data streams.
pub const MAX_CONSECUTIVE_ERRORS: u32 = 10;

// Compile-time validation
comptime {
    std.debug.assert(RECV_BUFFER_SIZE >= MAX_MESSAGE_SIZE + FRAME_HEADER_SIZE);
    std.debug.assert(SEND_BUFFER_SIZE >= MAX_MESSAGE_SIZE + FRAME_HEADER_SIZE);
    std.debug.assert(MAX_MESSAGE_SIZE > 0);
    std.debug.assert(MAX_MESSAGE_SIZE <= (4 * 65535)); // Reasonable limit
    std.debug.assert(MAX_CONSECUTIVE_ERRORS > 0);
    std.debug.assert(FRAME_HEADER_SIZE == 4);
}

// ============================================================================
// Client State
// ============================================================================

/// Connection state machine.
pub const ClientState = enum(u8) {
    /// Slot is available for new connection.
    disconnected,
    /// Active connection, can send/receive.
    connected,
    /// Draining send buffer before disconnect.
    draining,

    pub fn isActive(self: ClientState) bool {
        return self != .disconnected;
    }
};

// ============================================================================
// Client Statistics
// ============================================================================

/// Per-client statistics.
pub const ClientStats = struct {
    messages_received: u64,
    messages_sent: u64,
    bytes_received: u64,
    bytes_sent: u64,
    frames_dropped: u64,
    buffer_overflows: u64,
    decode_errors: u64,

    pub fn init() ClientStats {
        return .{
            .messages_received = 0,
            .messages_sent = 0,
            .bytes_received = 0,
            .bytes_sent = 0,
            .frames_dropped = 0,
            .buffer_overflows = 0,
            .decode_errors = 0,
        };
    }
};

// ============================================================================
// Frame Result
// ============================================================================

/// Result of frame extraction.
pub const FrameResult = union(enum) {
    /// Complete frame available.
    frame: []const u8,
    /// Need more data.
    incomplete,
    /// Frame too large, skipped.
    oversized: u32,
    /// Buffer empty.
    empty,
};

// ============================================================================
// TCP Client
// ============================================================================

/// Per-connection state for a TCP client.
///
/// Manages:
/// - Socket file descriptor
/// - Receive buffer with frame parsing (heap-allocated)
/// - Send buffer with queuing (heap-allocated)
/// - Protocol detection
/// - Statistics
pub const TcpClient = struct {
    // === Connection ===
    /// Socket file descriptor (-1 if disconnected).
    fd: posix.fd_t = -1,

    /// Unique client identifier for routing.
    client_id: config.ClientId = 0,

    /// Current connection state.
    state: ClientState = .disconnected,

    // === Heap-Allocated Buffers ===
    /// Incoming data buffer (heap-allocated, null when disconnected).
    recv_buf: ?[]u8 = null,

    /// Outgoing data buffer (heap-allocated, null when disconnected).
    send_buf: ?[]u8 = null,

    /// Allocator used for buffers (null when disconnected).
    allocator: ?std.mem.Allocator = null,

    /// Bytes currently in receive buffer.
    recv_len: u32 = 0,

    // === Send Buffer ===
    /// Total bytes queued for sending.
    send_len: u32 = 0,

    /// Bytes already sent (for partial sends).
    send_pos: u32 = 0,

    // === Protocol ===
    /// Detected protocol (CSV, binary, etc.).
    protocol: codec.Protocol = .unknown,

    // === Error Tracking ===
    /// Consecutive decode errors (reset on success).
    consecutive_errors: u32 = 0,

    // === Statistics ===
    stats: ClientStats = ClientStats.init(),

    // === Timestamps ===
    /// When connection was established.
    connect_time: i64 = 0,

    /// Last activity timestamp.
    last_active: i64 = 0,

    const Self = @This();

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Initialize client for new connection with heap-allocated buffers.
    pub fn init(allocator: std.mem.Allocator, fd: posix.fd_t, client_id: config.ClientId) !Self {
        std.debug.assert(fd >= 0);
        std.debug.assert(client_id != 0);
        std.debug.assert(config.isValidClient(client_id));

        // Allocate buffers on heap
        const recv_buf = try allocator.alloc(u8, RECV_BUFFER_SIZE);
        errdefer allocator.free(recv_buf);

        const send_buf = try allocator.alloc(u8, SEND_BUFFER_SIZE);
        errdefer allocator.free(send_buf);

        const now = std.time.timestamp();

        return .{
            .fd = fd,
            .client_id = client_id,
            .state = .connected,
            .recv_buf = recv_buf,
            .send_buf = send_buf,
            .allocator = allocator,
            .recv_len = 0,
            .send_len = 0,
            .send_pos = 0,
            .protocol = .unknown,
            .consecutive_errors = 0,
            .stats = ClientStats.init(),
            .connect_time = now,
            .last_active = now,
        };
    }

    /// Reset client to disconnected state.
    /// Closes socket and frees buffers if allocated.
    pub fn reset(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
        }

        // Free heap-allocated buffers
        if (self.allocator) |alloc| {
            if (self.recv_buf) |buf| {
                alloc.free(buf);
            }
            if (self.send_buf) |buf| {
                alloc.free(buf);
            }
        }

        self.* = .{};
    }

    /// Check if client is in connected state.
    pub fn isConnected(self: *const Self) bool {
        return self.state == .connected;
    }

    /// Check if client slot is available.
    pub fn isDisconnected(self: *const Self) bool {
        return self.state == .disconnected;
    }

    /// Update last activity timestamp.
    pub fn touch(self: *Self) void {
        self.last_active = std.time.timestamp();
    }

    // ========================================================================
    // Error Tracking
    // ========================================================================

    /// Record a decode error. Returns true if client should be disconnected.
    pub fn recordDecodeError(self: *Self) bool {
        self.consecutive_errors += 1;
        self.stats.decode_errors += 1;
        return self.consecutive_errors >= MAX_CONSECUTIVE_ERRORS;
    }

    /// Reset consecutive error counter (call on successful decode).
    pub fn resetErrors(self: *Self) void {
        self.consecutive_errors = 0;
    }

    /// Check if client has exceeded error threshold.
    pub fn shouldDisconnect(self: *const Self) bool {
        return self.consecutive_errors >= MAX_CONSECUTIVE_ERRORS;
    }

    // ========================================================================
    // Receive Operations
    // ========================================================================

    /// Receive data from socket into buffer.
    /// Returns bytes received, or error.
    ///
    /// Call in loop until WouldBlock (edge-triggered epoll).
    pub fn receive(self: *Self) !usize {
        std.debug.assert(self.state == .connected);
        std.debug.assert(self.fd >= 0);
        std.debug.assert(self.recv_len <= RECV_BUFFER_SIZE);

        const recv_buf = self.recv_buf orelse return error.BufferNotAllocated;

        const available = RECV_BUFFER_SIZE - self.recv_len;
        if (available == 0) {
            self.stats.buffer_overflows += 1;
            return error.BufferFull;
        }

        const n = posix.recv(
            self.fd,
            recv_buf[self.recv_len..],
            0,
        ) catch |err| {
            if (net_utils.isWouldBlock(err)) return error.WouldBlock;
            return err;
        };

        if (n == 0) return error.ConnectionClosed;

        self.recv_len += @intCast(n);
        self.stats.bytes_received += n;
        self.touch();

        std.debug.assert(self.recv_len <= RECV_BUFFER_SIZE);

        return n;
    }

    /// Get available data in receive buffer (for raw protocol).
    pub fn getReceivedData(self: *const Self) []const u8 {
        std.debug.assert(self.recv_len <= RECV_BUFFER_SIZE);
        const recv_buf = self.recv_buf orelse return &[_]u8{};
        return recv_buf[0..self.recv_len];
    }

    /// Check if receive buffer has any data.
    pub fn hasReceivedData(self: *const Self) bool {
        return self.recv_len > 0;
    }

    /// Get receive buffer fill percentage.
    pub fn getRecvBufferUsage(self: *const Self) u32 {
        return (self.recv_len * 100) / RECV_BUFFER_SIZE;
    }

    // ========================================================================
    // Frame Extraction (Length-Prefix Protocol)
    // ========================================================================

    /// Extract next complete frame from receive buffer.
    ///
    /// Frame format: [4-byte big-endian length][payload]
    ///
    /// Returns:
    /// - .frame: Complete frame payload (without header)
    /// - .incomplete: Need more data
    /// - .oversized: Frame too large, was skipped
    /// - .empty: No data in buffer
    pub fn extractFrame(self: *Self) FrameResult {
        std.debug.assert(self.recv_len <= RECV_BUFFER_SIZE);

        const recv_buf = self.recv_buf orelse return .empty;

        if (self.recv_len == 0) {
            return .empty;
        }

        if (self.recv_len < FRAME_HEADER_SIZE) {
            return .incomplete;
        }

        // Read length header
        const msg_len = std.mem.readInt(u32, recv_buf[0..4], .big);

        // Validate length
        if (msg_len > MAX_MESSAGE_SIZE) {
            std.log.warn("Client {}: oversized frame {} bytes (max {})", .{
                self.client_id,
                msg_len,
                MAX_MESSAGE_SIZE,
            });

            // Skip the invalid header
            self.compactRecvBuffer(FRAME_HEADER_SIZE);
            self.stats.frames_dropped += 1;

            return .{ .oversized = msg_len };
        }

        const total_len = FRAME_HEADER_SIZE + msg_len;

        if (self.recv_len < total_len) {
            return .incomplete;
        }

        std.debug.assert(total_len <= self.recv_len);
        std.debug.assert(total_len <= RECV_BUFFER_SIZE);

        // Return payload slice (caller must call consumeFrame after processing)
        return .{ .frame = recv_buf[FRAME_HEADER_SIZE..total_len] };
    }

    /// Consume a frame after successful processing.
    /// Call after extractFrame returns .frame and message is handled.
    pub fn consumeFrame(self: *Self, payload_len: usize) void {
        std.debug.assert(payload_len <= MAX_MESSAGE_SIZE);

        const total_len = FRAME_HEADER_SIZE + @as(u32, @intCast(payload_len));
        std.debug.assert(total_len <= self.recv_len);

        self.compactRecvBuffer(total_len);
        self.stats.messages_received += 1;
        self.resetErrors(); // Successful frame resets error counter
    }

    /// Compact receive buffer by removing bytes from front.
    pub fn compactRecvBuffer(self: *Self, bytes: u32) void {
        std.debug.assert(bytes <= self.recv_len);
        std.debug.assert(self.recv_len <= RECV_BUFFER_SIZE);

        const recv_buf = self.recv_buf orelse return;

        if (bytes >= self.recv_len) {
            self.recv_len = 0;
            return;
        }

        const remaining = self.recv_len - bytes;
        std.mem.copyForwards(
            u8,
            recv_buf[0..remaining],
            recv_buf[bytes..self.recv_len],
        );
        self.recv_len = remaining;

        std.debug.assert(self.recv_len <= RECV_BUFFER_SIZE);
    }

    // ========================================================================
    // Send Operations
    // ========================================================================

    /// Queue data for sending with length-prefix framing.
    ///
    /// Returns true if data was queued, false if buffer full.
    pub fn queueFramedSend(self: *Self, data: []const u8) bool {
        std.debug.assert(self.state.isActive());
        std.debug.assert(self.send_len <= SEND_BUFFER_SIZE);
        std.debug.assert(self.send_pos <= self.send_len);

        const send_buf = self.send_buf orelse return false;

        if (data.len > MAX_MESSAGE_SIZE) {
            std.log.warn("Client {}: attempted to send oversized message {} bytes", .{
                self.client_id,
                data.len,
            });
            return false;
        }

        const frame_size = FRAME_HEADER_SIZE + data.len;
        const available = SEND_BUFFER_SIZE - self.send_len;

        if (frame_size > available) {
            self.stats.buffer_overflows += 1;
            return false;
        }

        // Write length header (big-endian)
        const len_bytes = send_buf[self.send_len..][0..4];
        std.mem.writeInt(u32, len_bytes, @intCast(data.len), .big);
        self.send_len += FRAME_HEADER_SIZE;

        // Write payload
        @memcpy(send_buf[self.send_len..][0..data.len], data);
        self.send_len += @intCast(data.len);

        std.debug.assert(self.send_len <= SEND_BUFFER_SIZE);

        return true;
    }

    /// Queue data for sending without framing.
    ///
    /// Returns true if data was queued, false if buffer full.
    pub fn queueRawSend(self: *Self, data: []const u8) bool {
        std.debug.assert(self.state.isActive());
        std.debug.assert(data.len > 0);
        std.debug.assert(self.send_len <= SEND_BUFFER_SIZE);
        std.debug.assert(self.send_pos <= self.send_len);

        const send_buf = self.send_buf orelse return false;

        const available = SEND_BUFFER_SIZE - self.send_len;

        if (data.len > available) {
            self.stats.buffer_overflows += 1;
            return false;
        }

        @memcpy(send_buf[self.send_len..][0..data.len], data);
        self.send_len += @intCast(data.len);

        std.debug.assert(self.send_len <= SEND_BUFFER_SIZE);

        return true;
    }

    /// Attempt to flush send buffer to socket.
    ///
    /// May partially flush. Call repeatedly until hasPendingSend() is false.
    pub fn flushSend(self: *Self) !void {
        std.debug.assert(self.state.isActive());
        std.debug.assert(self.fd >= 0);
        std.debug.assert(self.send_pos <= self.send_len);
        std.debug.assert(self.send_len <= SEND_BUFFER_SIZE);

        const send_buf = self.send_buf orelse return error.BufferNotAllocated;

        while (self.send_pos < self.send_len) {
            const sent = posix.send(
                self.fd,
                send_buf[self.send_pos..self.send_len],
                SEND_FLAGS,
            ) catch |err| {
                if (net_utils.isWouldBlock(err)) return;
                return err;
            };

            self.send_pos += @intCast(sent);
            self.stats.bytes_sent += sent;
        }

        // Reset buffer when fully flushed
        if (self.send_pos == self.send_len) {
            self.send_pos = 0;
            self.send_len = 0;
        }

        self.touch();
    }

    /// Check if there's pending data to send.
    pub fn hasPendingSend(self: *const Self) bool {
        return self.send_pos < self.send_len;
    }

    /// Get send buffer fill percentage.
    pub fn getSendBufferUsage(self: *const Self) u32 {
        return (self.send_len * 100) / SEND_BUFFER_SIZE;
    }

    /// Record successful message send (for stats).
    pub fn recordMessageSent(self: *Self) void {
        self.stats.messages_sent += 1;
    }

    // ========================================================================
    // Protocol Detection
    // ========================================================================

    /// Detect protocol from received data.
    /// Should be called once when first data arrives.
    pub fn detectProtocol(self: *Self) void {
        if (self.protocol != .unknown) return;
        if (self.recv_len == 0) return;

        const recv_buf = self.recv_buf orelse return;
        self.protocol = codec.detectProtocol(recv_buf[0..self.recv_len]);
    }

    /// Get detected protocol.
    pub fn getProtocol(self: *const Self) codec.Protocol {
        return self.protocol;
    }

    // ========================================================================
    // Connection Info
    // ========================================================================

    /// Get connection duration in seconds.
    pub fn getConnectionDuration(self: *const Self) i64 {
        if (self.connect_time == 0) return 0;
        return std.time.timestamp() - self.connect_time;
    }

    /// Get idle duration in seconds.
    pub fn getIdleDuration(self: *const Self) i64 {
        if (self.last_active == 0) return 0;
        return std.time.timestamp() - self.last_active;
    }

    /// Get client statistics.
    pub fn getStats(self: *const Self) ClientStats {
        return self.stats;
    }
};

// ============================================================================
// Client Pool
// ============================================================================

/// Pre-allocated pool of client slots.
/// Provides O(1) allocation and lookup by index.
///
/// Note: Client slots are lightweight (~100 bytes each) since buffers
/// are heap-allocated only when a connection is established.
///
/// P10 Note: All loops bounded by `capacity` parameter.
pub fn ClientPool(comptime capacity: u32) type {
    comptime {
        std.debug.assert(capacity > 0);
        std.debug.assert(capacity <= 65536); // Reasonable limit
    }

    return struct {
        clients: [capacity]TcpClient = [_]TcpClient{.{}} ** capacity,
        active_count: u32 = 0,

        const Self = @This();

        /// Find a free client slot.
        ///
        /// P10 Rule 2: O(n) scan bounded by `capacity`.
        pub fn allocate(self: *Self) ?*TcpClient {
            // P10 Rule 2: Bounded by capacity
            for (&self.clients) |*client| {
                if (client.isDisconnected()) {
                    return client;
                }
            }
            return null;
        }

        /// Find client by file descriptor.
        ///
        /// P10 Rule 2: O(n) scan bounded by `capacity`.
        pub fn findByFd(self: *Self, fd: posix.fd_t) ?*TcpClient {
            std.debug.assert(fd >= 0);

            // P10 Rule 2: Bounded by capacity
            for (&self.clients) |*client| {
                if (client.fd == fd and client.state.isActive()) {
                    return client;
                }
            }
            return null;
        }

        /// Find client by ID.
        ///
        /// P10 Rule 2: O(n) scan bounded by `capacity`.
        pub fn findById(self: *Self, client_id: config.ClientId) ?*TcpClient {
            std.debug.assert(client_id != 0);

            // P10 Rule 2: Bounded by capacity
            for (&self.clients) |*client| {
                if (client.client_id == client_id and client.state.isActive()) {
                    return client;
                }
            }
            return null;
        }

        /// Get all active clients.
        pub fn getActive(self: *Self) ActiveIterator {
            return .{ .pool = self, .index = 0 };
        }

        /// Iterator over active clients.
        ///
        /// P10 Rule 2: Iteration bounded by `capacity`.
        pub const ActiveIterator = struct {
            pool: *Self,
            index: u32,

            pub fn next(self: *ActiveIterator) ?*TcpClient {
                // P10 Rule 2: Bounded by capacity
                while (self.index < capacity) {
                    const client = &self.pool.clients[self.index];
                    self.index += 1;
                    if (client.state.isActive()) {
                        return client;
                    }
                }
                return null;
            }
        };

        /// Get aggregate statistics.
        ///
        /// P10 Rule 2: O(n) scan bounded by `capacity`.
        pub fn getAggregateStats(self: *const Self) AggregateStats {
            var stats = AggregateStats{};

            // P10 Rule 2: Bounded by capacity
            for (self.clients) |client| {
                if (!client.state.isActive()) continue;

                stats.active_clients += 1;
                stats.total_messages_in += client.stats.messages_received;
                stats.total_messages_out += client.stats.messages_sent;
                stats.total_bytes_in += client.stats.bytes_received;
                stats.total_bytes_out += client.stats.bytes_sent;
                stats.total_decode_errors += client.stats.decode_errors;
            }

            return stats;
        }

        pub const AggregateStats = struct {
            active_clients: u32 = 0,
            total_messages_in: u64 = 0,
            total_messages_out: u64 = 0,
            total_bytes_in: u64 = 0,
            total_bytes_out: u64 = 0,
            total_decode_errors: u64 = 0,
        };
    };
}

// ============================================================================
// Tests
// ============================================================================

test "TcpClient frame extraction - complete frame" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    const recv_buf = client.recv_buf.?;

    // Write a complete frame: length=5, payload="hello"
    std.mem.writeInt(u32, recv_buf[0..4], 5, .big);
    @memcpy(recv_buf[4..9], "hello");
    client.recv_len = 9;

    const result = client.extractFrame();
    switch (result) {
        .frame => |payload| {
            try std.testing.expectEqualStrings("hello", payload);
            client.consumeFrame(payload.len);
            try std.testing.expectEqual(@as(u32, 0), client.recv_len);
        },
        else => return error.ExpectedFrame,
    }
}

test "TcpClient frame extraction - incomplete" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    const recv_buf = client.recv_buf.?;

    // Write partial frame: length=10, but only 5 bytes of payload
    std.mem.writeInt(u32, recv_buf[0..4], 10, .big);
    @memcpy(recv_buf[4..9], "hello");
    client.recv_len = 9;

    const result = client.extractFrame();
    try std.testing.expect(result == .incomplete);
}

test "TcpClient frame extraction - oversized" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    const recv_buf = client.recv_buf.?;

    // Write oversized frame length
    std.mem.writeInt(u32, recv_buf[0..4], MAX_MESSAGE_SIZE + 1, .big);
    client.recv_len = 4;

    const result = client.extractFrame();
    switch (result) {
        .oversized => |size| {
            try std.testing.expectEqual(MAX_MESSAGE_SIZE + 1, size);
            try std.testing.expectEqual(@as(u64, 1), client.stats.frames_dropped);
        },
        else => return error.ExpectedOversized,
    }
}

test "TcpClient frame extraction - multiple frames" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    const recv_buf = client.recv_buf.?;

    // Write two frames: "AB" and "XYZ"
    std.mem.writeInt(u32, recv_buf[0..4], 2, .big);
    @memcpy(recv_buf[4..6], "AB");
    std.mem.writeInt(u32, recv_buf[6..10], 3, .big);
    @memcpy(recv_buf[10..13], "XYZ");
    client.recv_len = 13;

    // Extract first frame
    const result1 = client.extractFrame();
    switch (result1) {
        .frame => |payload| {
            try std.testing.expectEqualStrings("AB", payload);
            client.consumeFrame(payload.len);
        },
        else => return error.ExpectedFrame,
    }

    // Extract second frame
    const result2 = client.extractFrame();
    switch (result2) {
        .frame => |payload| {
            try std.testing.expectEqualStrings("XYZ", payload);
            client.consumeFrame(payload.len);
        },
        else => return error.ExpectedFrame,
    }

    // Buffer should be empty
    try std.testing.expectEqual(@as(u32, 0), client.recv_len);
}

test "TcpClient queue framed send" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    const success = client.queueFramedSend("hello");
    try std.testing.expect(success);

    const send_buf = client.send_buf.?;

    // Verify frame structure
    const len = std.mem.readInt(u32, send_buf[0..4], .big);
    try std.testing.expectEqual(@as(u32, 5), len);
    try std.testing.expectEqualStrings("hello", send_buf[4..9]);
    try std.testing.expectEqual(@as(u32, 9), client.send_len);
}

test "TcpClient queue raw send" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    const success = client.queueRawSend("hello");
    try std.testing.expect(success);

    const send_buf = client.send_buf.?;
    try std.testing.expectEqualStrings("hello", send_buf[0..5]);
    try std.testing.expectEqual(@as(u32, 5), client.send_len);
}

test "TcpClient buffer overflow detection" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    // Fill send buffer
    client.send_len = SEND_BUFFER_SIZE - 5;

    // Try to queue more than fits
    const success = client.queueFramedSend("this is too long to fit");
    try std.testing.expect(!success);
    try std.testing.expectEqual(@as(u64, 1), client.stats.buffer_overflows);
}

test "TcpClient consecutive error tracking" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    // Record errors up to threshold
    for (0..MAX_CONSECUTIVE_ERRORS - 1) |_| {
        try std.testing.expect(!client.recordDecodeError());
        try std.testing.expect(!client.shouldDisconnect());
    }

    // One more triggers disconnect
    try std.testing.expect(client.recordDecodeError());
    try std.testing.expect(client.shouldDisconnect());
    try std.testing.expectEqual(MAX_CONSECUTIVE_ERRORS, client.consecutive_errors);
}

test "TcpClient error reset on success" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 1);
    defer client.reset();

    // Accumulate some errors
    _ = client.recordDecodeError();
    _ = client.recordDecodeError();
    _ = client.recordDecodeError();
    try std.testing.expectEqual(@as(u32, 3), client.consecutive_errors);

    // Reset on success
    client.resetErrors();
    try std.testing.expectEqual(@as(u32, 0), client.consecutive_errors);
}

test "ClientPool allocation" {
    const allocator = std.testing.allocator;

    var pool = ClientPool(4){};

    // Allocate all slots
    const c1 = pool.allocate();
    try std.testing.expect(c1 != null);
    c1.?.* = try TcpClient.init(allocator, 5, 1);

    const c2 = pool.allocate();
    try std.testing.expect(c2 != null);
    c2.?.* = try TcpClient.init(allocator, 6, 2);

    const c3 = pool.allocate();
    try std.testing.expect(c3 != null);
    c3.?.* = try TcpClient.init(allocator, 7, 3);

    const c4 = pool.allocate();
    try std.testing.expect(c4 != null);
    c4.?.* = try TcpClient.init(allocator, 8, 4);

    // Pool should be full
    try std.testing.expect(pool.allocate() == null);

    // Free one and allocate again
    c2.?.reset();
    const c5 = pool.allocate();
    try std.testing.expect(c5 != null);
    c5.?.* = try TcpClient.init(allocator, 9, 5);

    // Clean up
    c1.?.reset();
    c3.?.reset();
    c4.?.reset();
    c5.?.reset();
}

test "TcpClient init validation" {
    const allocator = std.testing.allocator;

    var client = try TcpClient.init(allocator, 5, 100);
    defer client.reset();

    try std.testing.expectEqual(@as(posix.fd_t, 5), client.fd);
    try std.testing.expectEqual(@as(config.ClientId, 100), client.client_id);
    try std.testing.expectEqual(ClientState.connected, client.state);
    try std.testing.expectEqual(@as(u32, 0), client.recv_len);
    try std.testing.expectEqual(@as(u32, 0), client.send_len);
    try std.testing.expect(client.recv_buf != null);
    try std.testing.expect(client.send_buf != null);
    try std.testing.expect(client.allocator != null);
}

test "TcpClient disconnected has no buffers" {
    var client = TcpClient{};
    try std.testing.expect(client.isDisconnected());
    try std.testing.expect(client.recv_buf == null);
    try std.testing.expect(client.send_buf == null);
    try std.testing.expect(client.allocator == null);
}

test "ClientPool size is reasonable" {
    // Verify that the pool struct itself is small (buffers are heap-allocated)
    const pool_size = @sizeOf(ClientPool(64));
    // Each TcpClient should be ~100-200 bytes without embedded buffers
    // 64 clients * ~150 bytes = ~10KB, plus some overhead
    try std.testing.expect(pool_size < 20 * 1024); // Should be well under 20KB
}
