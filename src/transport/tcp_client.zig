//! TCP client connection state and buffer management.
//!
//! OPTIMIZED VERSION v5 - OutputRouter Integration
//!
//! Key changes from v4:
//! 1. Added output_queue pointer for per-client output queue (from OutputRouter)
//! 2. TCP server drains output queue during EPOLLOUT, encodes messages, sends
//! 3. This matches the C server architecture for high throughput
//!
//! Data flow:
//!   Processor → OutputRouter → Client.output_queue → TcpServer drains → socket
//!
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const config = @import("config.zig");
const codec = @import("../protocol/codec.zig");
const net_utils = @import("net_utils.zig");
const msg = @import("../protocol/message_types.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");

// Import OutputRouter types (forward declaration to avoid circular deps)
// The actual queue is set by ThreadedServer after OutputRouter registration
pub const OutputQueue = @import("../threading/output_router.zig").ClientOutputQueue;
pub const ClientOutput = @import("../threading/output_router.zig").ClientOutput;

// ============================================================================
// Platform Detection
// ============================================================================

const is_linux = builtin.os.tag == .linux;
const SEND_FLAGS: u32 = if (is_linux) posix.MSG.NOSIGNAL else 0;

// ============================================================================
// Configuration
// ============================================================================

pub const RECV_BUFFER_SIZE: u32 = 16 * 1024 * 1024; // 16MB receive buffer
pub const SEND_BUFFER_SIZE: u32 = 16 * 1024 * 1024; // 16MB send buffer for burst handling
pub const FRAME_HEADER_SIZE: u32 = 4;
pub const MAX_MESSAGE_SIZE: u32 = 4 * 16384;
pub const MAX_CONSECUTIVE_ERRORS: u32 = 10;

/// Maximum messages to drain from output queue per write event
pub const MAX_OUTPUT_DRAIN_PER_WRITE: u32 = 1024;

const RECV_COMPACT_THRESHOLD: u32 = RECV_BUFFER_SIZE / 2;

comptime {
    std.debug.assert(RECV_BUFFER_SIZE >= MAX_MESSAGE_SIZE + FRAME_HEADER_SIZE);
    std.debug.assert(SEND_BUFFER_SIZE >= MAX_MESSAGE_SIZE + FRAME_HEADER_SIZE);
    std.debug.assert(MAX_MESSAGE_SIZE > 0);
    std.debug.assert(MAX_CONSECUTIVE_ERRORS > 0);
    std.debug.assert(FRAME_HEADER_SIZE == 4);
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
    send_calls: u64,
    send_would_block: u64,
    send_full_flushes: u64,
    output_queue_drained: u64,  // NEW: messages drained from output queue

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
            .send_full_flushes = 0,
            .output_queue_drained = 0,
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
// TCP Client
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

    // === Send Buffer Indices ===
    send_len: u32 = 0,
    send_pos: u32 = 0,

    // === Protocol ===
    protocol: codec.Protocol = .unknown,

    // === Output Queue (from OutputRouter) ===
    /// Pointer to this client's output queue in OutputRouter
    /// Set by ThreadedServer when client connects
    output_queue: ?*OutputQueue = null,

    // === Encode buffer for output queue draining ===
    encode_buf: [256]u8 = undefined,

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
            .output_queue = null,
            .encode_buf = undefined,
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
            if (self.recv_buf) |buf| alloc.free(buf);
            if (self.send_buf) |buf| alloc.free(buf);
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
    // Output Queue (NEW)
    // ========================================================================

    /// Set the output queue pointer (called by ThreadedServer on connect)
    pub fn setOutputQueue(self: *Self, queue: *OutputQueue) void {
        self.output_queue = queue;
    }

    /// Check if there are messages in the output queue
    pub fn hasOutputQueueMessages(self: *const Self) bool {
        if (self.output_queue) |queue| {
            return !queue.isEmpty();
        }
        return false;
    }

    /// Drain output queue into send buffer.
    /// Encodes messages and queues them for sending.
    /// Returns number of messages drained.
    pub fn drainOutputQueue(self: *Self) u32 {
        const queue = self.output_queue orelse return 0;
        const send_buf = self.send_buf orelse return 0;

        var drained: u32 = 0;
        const use_binary = (self.protocol == .binary);

        while (drained < MAX_OUTPUT_DRAIN_PER_WRITE) {
            // Pop message from queue
            const output = queue.pop() orelse break;
            const out_msg = &output.message;

            // Encode message
            const encoded_len = if (use_binary)
                binary_codec.encodeOutput(out_msg, &self.encode_buf) catch {
                    // Encode error - skip this message
                    continue;
                }
            else
                csv_codec.encodeOutput(out_msg, &self.encode_buf) catch {
                    continue;
                };

            // Check if we have space in send buffer (with framing)
            const frame_size: u32 = FRAME_HEADER_SIZE + @as(u32, @intCast(encoded_len));
            const available = SEND_BUFFER_SIZE - self.send_len;

            if (frame_size > available) {
                // Send buffer full - can't drain more
                // Note: This message is lost! In production, we'd want to
                // put it back or handle this better. For now, log it.
                std.log.warn("TcpClient: Send buffer full, dropping message for client {}", .{self.client_id});
                self.stats.buffer_overflows += 1;
                break;
            }

            // Write frame header (4-byte big-endian length)
            const hdr = send_buf[self.send_len..][0..4];
            std.mem.writeInt(u32, hdr, @intCast(encoded_len), .big);
            self.send_len += FRAME_HEADER_SIZE;

            // Write encoded payload
            @memcpy(send_buf[self.send_len..][0..encoded_len], self.encode_buf[0..encoded_len]);
            self.send_len += @intCast(encoded_len);

            drained += 1;
            self.stats.output_queue_drained += 1;
            self.stats.messages_sent += 1;
        }

        return drained;
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

        std.mem.copyForwards(u8, recv_buf[0..unread], recv_buf[self.recv_read..self.recv_write]);
        self.recv_read = 0;
        self.recv_write = unread;
    }

    fn ensureRecvSpace(self: *Self) bool {
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

        const recv_buf = self.recv_buf orelse return error.BufferNotAllocated;

        if (!self.ensureRecvSpace()) {
            self.stats.buffer_overflows += 1;
            return error.BufferFull;
        }

        const n = posix.recv(self.fd, recv_buf[self.recv_write..], 0) catch |err| {
            if (net_utils.isWouldBlock(err)) return error.WouldBlock;
            return err;
        };

        if (n == 0) return error.ConnectionClosed;

        self.recv_write += @intCast(n);
        self.stats.bytes_received += n;
        self.touch();

        if (self.recv_read >= RECV_COMPACT_THRESHOLD) {
            self.compactRecv();
        }

        return n;
    }

    pub fn getReceivedData(self: *const Self) []const u8 {
        const recv_buf = self.recv_buf orelse return &[_]u8{};
        return recv_buf[self.recv_read..self.recv_write];
    }

    pub fn consumeBytes(self: *Self, bytes: u32) void {
        std.debug.assert(bytes <= self.recvDataLen());
        self.recv_read += bytes;

        if (self.recv_read == self.recv_write) {
            self.recv_read = 0;
            self.recv_write = 0;
        } else if (self.recv_read >= RECV_COMPACT_THRESHOLD) {
            self.compactRecv();
        }
    }

    pub fn compactRecvBuffer(self: *Self, processed: usize) void {
        self.consumeBytes(@intCast(processed));
    }

    pub fn hasReceivedData(self: *const Self) bool {
        return self.recv_write > self.recv_read;
    }

    pub fn getRecvBufferUsage(self: *const Self) u32 {
        return (self.recvDataLen() * 100) / RECV_BUFFER_SIZE;
    }

    // ========================================================================
    // Frame Extraction
    // ========================================================================

    pub fn extractFrame(self: *Self) FrameResult {
        const recv_buf = self.recv_buf orelse return .empty;
        const unread = self.recvDataLen();

        if (unread == 0) return .empty;
        if (unread < FRAME_HEADER_SIZE) return .incomplete;

        const hdr_start = self.recv_read;
        const hdr: *const [4]u8 = @ptrCast(recv_buf[hdr_start..][0..4].ptr);
        const msg_len = std.mem.readInt(u32, hdr, .big);

        if (msg_len > MAX_MESSAGE_SIZE) {
            self.recv_read += FRAME_HEADER_SIZE;
            self.stats.frames_dropped += 1;
            if (self.recv_read == self.recv_write) {
                self.recv_read = 0;
                self.recv_write = 0;
            }
            return .{ .oversized = msg_len };
        }

        const total_len: u32 = FRAME_HEADER_SIZE + msg_len;
        if (unread < total_len) return .incomplete;

        const payload_start = hdr_start + FRAME_HEADER_SIZE;
        return .{ .frame = recv_buf[payload_start..][0..msg_len] };
    }

    pub fn consumeFrame(self: *Self, payload_len: usize) void {
        const total_len: u32 = FRAME_HEADER_SIZE + @as(u32, @intCast(payload_len));
        self.recv_read += total_len;
        self.stats.messages_received += 1;
        self.resetErrors();

        if (self.recv_read == self.recv_write) {
            self.recv_read = 0;
            self.recv_write = 0;
        }
    }

    // ========================================================================
    // Send Operations
    // ========================================================================

    /// Queue a framed message for sending.
    /// Returns false if buffer is full.
    pub fn queueFramedSend(self: *Self, data: []const u8) bool {
        const send_buf = self.send_buf orelse return false;
        const frame_size: u32 = FRAME_HEADER_SIZE + @as(u32, @intCast(data.len));
        const available = SEND_BUFFER_SIZE - self.send_len;

        if (frame_size > available) {
            self.stats.buffer_overflows += 1;
            return false;
        }

        // Write length header
        const hdr = send_buf[self.send_len..][0..4];
        std.mem.writeInt(u32, hdr, @intCast(data.len), .big);
        self.send_len += FRAME_HEADER_SIZE;

        // Write payload
        @memcpy(send_buf[self.send_len..][0..data.len], data);
        self.send_len += @intCast(data.len);

        return true;
    }

    /// Queue raw data without framing.
    pub fn queueRawSend(self: *Self, data: []const u8) bool {
        const send_buf = self.send_buf orelse return false;
        const available = SEND_BUFFER_SIZE - self.send_len;

        if (data.len > available) {
            self.stats.buffer_overflows += 1;
            return false;
        }

        @memcpy(send_buf[self.send_len..][0..data.len], data);
        self.send_len += @intCast(data.len);

        return true;
    }

    /// Flush send buffer - SINGLE send() call, non-blocking.
    /// Returns WouldBlock if socket isn't ready (caller should enable EPOLLOUT).
    /// Returns normally when some data was sent (may still have pending data).
    pub fn flushSend(self: *Self) !void {
        if (self.send_pos >= self.send_len) return; // Nothing to send

        const send_buf = self.send_buf orelse return;

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
        self.touch();

        // Check if we sent everything
        if (self.send_pos == self.send_len) {
            // Buffer fully sent, reset
            self.send_pos = 0;
            self.send_len = 0;
            self.stats.send_full_flushes += 1;
        }
        // If not fully sent, caller should enable EPOLLOUT and call again later
    }

    /// Flush send buffer completely (blocking-style, for shutdown).
    /// Loops until all data sent or error.
    pub fn flushSendFully(self: *Self) !void {
        const send_buf = self.send_buf orelse return;

        var attempts: u32 = 0;
        const max_attempts: u32 = 10000;

        while (self.send_pos < self.send_len and attempts < max_attempts) : (attempts += 1) {
            const sent = posix.send(
                self.fd,
                send_buf[self.send_pos..self.send_len],
                SEND_FLAGS,
            ) catch |err| {
                if (net_utils.isWouldBlock(err)) {
                    self.stats.send_would_block += 1;
                    std.Thread.sleep(100_000); // 100us
                    continue;
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
    }

    pub fn hasPendingSend(self: *const Self) bool {
        return self.send_pos < self.send_len;
    }

    /// Check if there's work to do (pending send OR output queue messages)
    pub fn hasWorkToDo(self: *const Self) bool {
        if (self.hasPendingSend()) return true;
        if (self.hasOutputQueueMessages()) return true;
        return false;
    }

    pub fn getSendBufferUsage(self: *const Self) u32 {
        return (self.send_len * 100) / SEND_BUFFER_SIZE;
    }

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
        self.protocol = codec.detectProtocol(self.getReceivedData());
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
// Client Pool
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
                if (client.isDisconnected()) return client;
            }
            return null;
        }

        pub fn findByFd(self: *Self, fd: posix.fd_t) ?*TcpClient {
            for (&self.clients) |*client| {
                if (client.fd == fd and client.state.isActive()) return client;
            }
            return null;
        }

        pub fn findById(self: *Self, client_id: config.ClientId) ?*TcpClient {
            for (&self.clients) |*client| {
                if (client.client_id == client_id and client.state.isActive()) return client;
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
                    if (client.state.isActive()) return client;
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
                stats.total_full_flushes += client.stats.send_full_flushes;
                stats.total_output_queue_drained += client.stats.output_queue_drained;
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
            total_full_flushes: u64 = 0,
            total_output_queue_drained: u64 = 0,
        };
    };
}
