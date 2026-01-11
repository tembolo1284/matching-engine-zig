//! TCP client connection state and buffer management.
//!
//! OPTIMIZED VERSION - Key change:
//! flushSend() now does a SINGLE send() call instead of looping.
//! This prevents blocking behavior and lets EPOLLOUT drive multiple sends.
//!
//! Each TcpClient represents a single TCP connection with:
//! - Receive buffer with frame extraction (heap-allocated)
//! - Send buffer with optional length-prefix framing (heap-allocated)
//! - Protocol auto-detection
//! - Per-connection statistics
//! - Consecutive error tracking for disconnect decision
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
const SEND_FLAGS: u32 = if (is_linux) posix.MSG.NOSIGNAL else 0;

// ============================================================================
// Configuration
// ============================================================================
pub const RECV_BUFFER_SIZE: u32 = 16 * 1024 * 1024;
pub const SEND_BUFFER_SIZE: u32 = 16 * 1024 * 1024;
pub const FRAME_HEADER_SIZE: u32 = 4;
pub const MAX_MESSAGE_SIZE: u32 = 4 * 16384;
pub const MAX_CONSECUTIVE_ERRORS: u32 = 10;
const RECV_COMPACT_THRESHOLD: u32 = RECV_BUFFER_SIZE / 2;

comptime {
    std.debug.assert(RECV_BUFFER_SIZE >= MAX_MESSAGE_SIZE + FRAME_HEADER_SIZE);
    std.debug.assert(SEND_BUFFER_SIZE >= MAX_MESSAGE_SIZE + FRAME_HEADER_SIZE);
    std.debug.assert(MAX_MESSAGE_SIZE > 0);
    std.debug.assert(MAX_MESSAGE_SIZE <= (4 * 65535));
    std.debug.assert(MAX_CONSECUTIVE_ERRORS > 0);
    std.debug.assert(FRAME_HEADER_SIZE == 4);
    std.debug.assert(RECV_COMPACT_THRESHOLD > 0);
}

// ============================================================================
// Client State
// ============================================================================
pub const ClientState = enum(u8) {
    disconnected,
    connected,
    draining,

    pub fn isActive(self: ClientState) bool {
        return self != .disconnected;
    }
};

// ============================================================================
// Client Statistics
// ============================================================================
pub const ClientStats = struct {
    messages_received: u64,
    messages_sent: u64,
    bytes_received: u64,
    bytes_sent: u64,
    frames_dropped: u64,
    buffer_overflows: u64,
    decode_errors: u64,
    send_calls: u64,        // NEW: track syscall count
    send_would_block: u64,  // NEW: track WouldBlock events

    pub fn init() ClientStats {
        return .{
            .messages_received = 0,
            .messages_sent = 0,
            .bytes_received = 0,
            .bytes_sent = 0,
            .frames_dropped = 0,
            .buffer_overflows = 0,
            .decode_errors = 0,
            .send_calls = 0,
            .send_would_block = 0,
        };
    }
};

// ============================================================================
// Frame Result
// ============================================================================
pub const FrameResult = union(enum) {
    frame: []const u8,
    incomplete,
    oversized: u32,
    empty,
};

// ============================================================================
// TCP Client - OPTIMIZED
// ============================================================================
pub const TcpClient = struct {
    // === Connection ===
    fd: posix.fd_t = -1,
    client_id: config.ClientId = 0,
    state: ClientState = .disconnected,

    // === Heap-Allocated Buffers ===
    recv_buf: ?[]u8 = null,
    send_buf: ?[]u8 = null,
    allocator: ?std.mem.Allocator = null,

    // === Receive Buffer Indices ===
    recv_read: u32 = 0,
    recv_write: u32 = 0,

    // === Send Buffer ===
    send_len: u32 = 0,
    send_pos: u32 = 0,

    // === Protocol ===
    protocol: codec.Protocol = .unknown,

    // === Error Tracking ===
    consecutive_errors: u32 = 0,

    // === Statistics ===
    stats: ClientStats = ClientStats.init(),

    // === Timestamps ===
    connect_time: i64 = 0,
    last_active: i64 = 0,

    const Self = @This();

    // ========================================================================
    // Lifecycle
    // ========================================================================
    pub fn init(allocator: std.mem.Allocator, fd: posix.fd_t, client_id: config.ClientId) !Self {
        std.debug.assert(fd >= 0);
        std.debug.assert(client_id != 0);
        std.debug.assert(config.isValidClient(client_id));

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
            .recv_read = 0,
            .recv_write = 0,
            .send_len = 0,
            .send_pos = 0,
            .protocol = .unknown,
            .consecutive_errors = 0,
            .stats = ClientStats.init(),
            .connect_time = now,
            .last_active = now,
        };
    }

    pub fn reset(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
        }
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

    pub fn isConnected(self: *const Self) bool {
        return self.state == .connected;
    }

    pub fn isDisconnected(self: *const Self) bool {
        return self.state == .disconnected;
    }

    pub fn touch(self: *Self) void {
        self.last_active = std.time.timestamp();
    }

    // ========================================================================
    // Error Tracking
    // ========================================================================
    pub fn recordDecodeError(self: *Self) bool {
        self.consecutive_errors += 1;
        self.stats.decode_errors += 1;
        return self.consecutive_errors >= MAX_CONSECUTIVE_ERRORS;
    }

    pub fn resetErrors(self: *Self) void {
        self.consecutive_errors = 0;
    }

    pub fn shouldDisconnect(self: *const Self) bool {
        return self.consecutive_errors >= MAX_CONSECUTIVE_ERRORS;
    }

    // ========================================================================
    // Receive Operations
    // ========================================================================
    pub fn recvDataLen(self: *const Self) u32 {
        std.debug.assert(self.recv_write >= self.recv_read);
        return self.recv_write - self.recv_read;
    }

    fn compactRecv(self: *Self) void {
        const recv_buf = self.recv_buf orelse return;
        const unread = self.recvDataLen();
        if (unread == 0) {
            self.recv_read = 0;
            self.recv_write = 0;
            return;
        }
        if (self.recv_read == 0) return;
        std.mem.copyForwards(
            u8,
            recv_buf[0..unread],
            recv_buf[self.recv_read..self.recv_write],
        );
        self.recv_read = 0;
        self.recv_write = unread;
        std.debug.assert(self.recv_write <= RECV_BUFFER_SIZE);
    }

    fn ensureRecvSpace(self: *Self) bool {
        std.debug.assert(self.recv_write <= RECV_BUFFER_SIZE);
        const avail = RECV_BUFFER_SIZE - self.recv_write;
        if (avail > 0) return true;
        if (self.recv_read > 0) {
            self.compactRecv();
            return (RECV_BUFFER_SIZE - self.recv_write) > 0;
        }
        return false;
    }

    pub fn receive(self: *Self) !usize {
        std.debug.assert(self.state == .connected);
        std.debug.assert(self.fd >= 0);
        std.debug.assert(self.recv_write <= RECV_BUFFER_SIZE);
        std.debug.assert(self.recv_read <= self.recv_write);

        const recv_buf = self.recv_buf orelse return error.BufferNotAllocated;

        if (!self.ensureRecvSpace()) {
            self.stats.buffer_overflows += 1;
            return error.BufferFull;
        }

        const n = posix.recv(
            self.fd,
            recv_buf[self.recv_write..],
            0,
        ) catch |err| {
            if (net_utils.isWouldBlock(err)) return error.WouldBlock;
            return err;
        };

        if (n == 0) return error.ConnectionClosed;

        self.recv_write += @intCast(n);
        self.stats.bytes_received += n;
        self.touch();

        std.debug.assert(self.recv_write <= RECV_BUFFER_SIZE);
        std.debug.assert(self.recv_read <= self.recv_write);

        if (self.recv_read >= RECV_COMPACT_THRESHOLD) {
            self.compactRecv();
        }

        return n;
    }

    pub fn getReceivedData(self: *const Self) []const u8 {
        const recv_buf = self.recv_buf orelse return &[_]u8{};
        std.debug.assert(self.recv_read <= self.recv_write);
        return recv_buf[self.recv_read..self.recv_write];
    }

    pub fn consumeBytes(self: *Self, bytes: u32) void {
        std.debug.assert(bytes <= self.recvDataLen());
        self.recv_read += bytes;
        if (self.recv_read == self.recv_write) {
            self.recv_read = 0;
            self.recv_write = 0;
            return;
        }
        if (self.recv_read >= RECV_COMPACT_THRESHOLD) {
            self.compactRecv();
        }
    }

    pub fn compactRecvBuffer(self: *Self, processed: usize) void {
        std.debug.assert(processed <= self.recvDataLen());
        self.consumeBytes(@intCast(processed));
    }

    pub fn hasReceivedData(self: *const Self) bool {
        return self.recv_write > self.recv_read;
    }

    pub fn getRecvBufferUsage(self: *const Self) u32 {
        const unread = self.recvDataLen();
        return (unread * 100) / RECV_BUFFER_SIZE;
    }

    // ========================================================================
    // Frame Extraction (Length-Prefix Protocol)
    // ========================================================================
    pub fn extractFrame(self: *Self) FrameResult {
        const recv_buf = self.recv_buf orelse return .empty;
        const unread = self.recvDataLen();
        if (unread == 0) return .empty;
        if (unread < FRAME_HEADER_SIZE) return .incomplete;

        const hdr_start = self.recv_read;
        const hdr_end = hdr_start + FRAME_HEADER_SIZE;
        std.debug.assert(hdr_end <= self.recv_write);

        const hdr: *const [4]u8 = @ptrCast(recv_buf[hdr_start..hdr_end].ptr);
        const msg_len = std.mem.readInt(u32, hdr, .big);

        if (msg_len > MAX_MESSAGE_SIZE) {
            std.log.warn("Client {}: oversized frame {} bytes (max {})", .{
                self.client_id,
                msg_len,
                MAX_MESSAGE_SIZE,
            });
            self.recv_read += FRAME_HEADER_SIZE;
            self.stats.frames_dropped += 1;
            if (self.recv_read == self.recv_write) {
                self.recv_read = 0;
                self.recv_write = 0;
            } else if (self.recv_read >= RECV_COMPACT_THRESHOLD) {
                self.compactRecv();
            }
            return .{ .oversized = msg_len };
        }

        const total_len: u32 = FRAME_HEADER_SIZE + msg_len;
        if (unread < total_len) return .incomplete;

        const payload_start = hdr_end;
        const payload_end = payload_start + msg_len;
        std.debug.assert(payload_end <= self.recv_write);

        return .{ .frame = recv_buf[payload_start..payload_end] };
    }

    pub fn consumeFrame(self: *Self, payload_len: usize) void {
        std.debug.assert(payload_len <= MAX_MESSAGE_SIZE);
        const total_len: u32 = FRAME_HEADER_SIZE + @as(u32, @intCast(payload_len));
        std.debug.assert(total_len <= self.recvDataLen());

        self.recv_read += total_len;
        self.stats.messages_received += 1;
        self.resetErrors();

        if (self.recv_read == self.recv_write) {
            self.recv_read = 0;
            self.recv_write = 0;
            return;
        }
        if (self.recv_read >= RECV_COMPACT_THRESHOLD) {
            self.compactRecv();
        }
    }

    // ========================================================================
    // Send Operations
    // ========================================================================
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

    /// OPTIMIZED: Single-shot flush - ONE send() call, then return.
    /// Let EPOLLOUT drive repeated calls if needed.
    /// This is the KEY change for performance.
    pub fn flushSend(self: *Self) !void {
        std.debug.assert(self.state.isActive());
        std.debug.assert(self.fd >= 0);
        std.debug.assert(self.send_pos <= self.send_len);
        std.debug.assert(self.send_len <= SEND_BUFFER_SIZE);

        const send_buf = self.send_buf orelse return error.BufferNotAllocated;

        // Nothing to send?
        if (self.send_pos >= self.send_len) return;

        // SINGLE send() call - this is the optimization!
        const sent = posix.send(
            self.fd,
            send_buf[self.send_pos..self.send_len],
            SEND_FLAGS,
        ) catch |err| {
            if (net_utils.isWouldBlock(err)) {
                self.stats.send_would_block += 1;
                return error.WouldBlock;
            }
            return err;
        };

        self.stats.send_calls += 1;
        self.send_pos += @intCast(sent);
        self.stats.bytes_sent += sent;

        // Compact buffer when fully sent
        if (self.send_pos == self.send_len) {
            self.send_pos = 0;
            self.send_len = 0;
        }

        self.touch();
    }

    /// Aggressive flush - loop until WouldBlock or empty.
    /// Use sparingly (e.g., on disconnect to drain buffer).
    pub fn flushSendFully(self: *Self) !void {
        std.debug.assert(self.state.isActive());
        std.debug.assert(self.fd >= 0);

        const send_buf = self.send_buf orelse return error.BufferNotAllocated;

        while (self.send_pos < self.send_len) {
            const sent = posix.send(
                self.fd,
                send_buf[self.send_pos..self.send_len],
                SEND_FLAGS,
            ) catch |err| {
                if (net_utils.isWouldBlock(err)) {
                    self.stats.send_would_block += 1;
                    return error.WouldBlock;
                }
                return err;
            };

            self.stats.send_calls += 1;
            self.send_pos += @intCast(sent);
            self.stats.bytes_sent += sent;
        }

        if (self.send_pos == self.send_len) {
            self.send_pos = 0;
            self.send_len = 0;
        }

        self.touch();
    }

    pub fn hasPendingSend(self: *const Self) bool {
        return self.send_pos < self.send_len;
    }

    pub fn getSendBufferUsage(self: *const Self) u32 {
        return (self.send_len * 100) / SEND_BUFFER_SIZE;
    }

    /// Get pending bytes to send
    pub fn getPendingSendBytes(self: *const Self) u32 {
        return self.send_len - self.send_pos;
    }

    pub fn recordMessageSent(self: *Self) void {
        self.stats.messages_sent += 1;
    }

    // ========================================================================
    // Protocol Detection
    // ========================================================================
    pub fn detectProtocol(self: *Self) void {
        if (self.protocol != .unknown) return;
        if (!self.hasReceivedData()) return;
        const data = self.getReceivedData();
        self.protocol = codec.detectProtocol(data);
    }

    pub fn getProtocol(self: *const Self) codec.Protocol {
        return self.protocol;
    }

    // ========================================================================
    // Connection Info
    // ========================================================================
    pub fn getConnectionDuration(self: *const Self) i64 {
        if (self.connect_time == 0) return 0;
        return std.time.timestamp() - self.connect_time;
    }

    pub fn getIdleDuration(self: *const Self) i64 {
        if (self.last_active == 0) return 0;
        return std.time.timestamp() - self.last_active;
    }

    pub fn getStats(self: *const Self) ClientStats {
        return self.stats;
    }
};

// ============================================================================
// Client Pool (unchanged)
// ============================================================================
pub fn ClientPool(comptime capacity: u32) type {
    comptime {
        std.debug.assert(capacity > 0);
        std.debug.assert(capacity <= 65536);
    }

    return struct {
        clients: [capacity]TcpClient = [_]TcpClient{.{}} ** capacity,
        active_count: u32 = 0,

        const Self = @This();

        pub fn allocate(self: *Self) ?*TcpClient {
            for (&self.clients) |*client| {
                if (client.isDisconnected()) {
                    return client;
                }
            }
            return null;
        }

        pub fn findByFd(self: *Self, fd: posix.fd_t) ?*TcpClient {
            std.debug.assert(fd >= 0);
            for (&self.clients) |*client| {
                if (client.fd == fd and client.state.isActive()) {
                    return client;
                }
            }
            return null;
        }

        pub fn findById(self: *Self, client_id: config.ClientId) ?*TcpClient {
            std.debug.assert(client_id != 0);
            for (&self.clients) |*client| {
                if (client.client_id == client_id and client.state.isActive()) {
                    return client;
                }
            }
            return null;
        }

        pub fn getActive(self: *Self) ActiveIterator {
            return .{ .pool = self, .index = 0 };
        }

        pub const ActiveIterator = struct {
            pool: *Self,
            index: u32,

            pub fn next(self: *ActiveIterator) ?*TcpClient {
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

        pub fn getAggregateStats(self: *const Self) AggregateStats {
            var stats = AggregateStats{};
            for (self.clients) |client| {
                if (!client.state.isActive()) continue;
                stats.active_clients += 1;
                stats.total_messages_in += client.stats.messages_received;
                stats.total_messages_out += client.stats.messages_sent;
                stats.total_bytes_in += client.stats.bytes_received;
                stats.total_bytes_out += client.stats.bytes_sent;
                stats.total_decode_errors += client.stats.decode_errors;
                stats.total_send_calls += client.stats.send_calls;
                stats.total_would_block += client.stats.send_would_block;
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
            total_send_calls: u64 = 0,
            total_would_block: u64 = 0,
        };
    };
}
