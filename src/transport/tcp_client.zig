//! TCP client connection state and buffer management.
//!
//! Matches the C server semantics in tcp_listener.c:
//! - process_output_queues(): for each client, if active and NOT has_pending_write,
//!   dequeue ONE output message, frame+format it, attempt immediate write.
//! - If partial or EAGAIN: enable EPOLLOUT and continue later.
//! - Only count "messages_sent" when a framed write fully completes.
//!
//! Critical correctness fix vs old Zig:
//! - Never "pop then drop" from output queue if send buffer is full.
//!   We stash ONE pending output message and retry later.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const config = @import("config.zig");
const codec = @import("../protocol/codec.zig");
const net_utils = @import("net_utils.zig");
const msg = @import("../protocol/message_types.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");

pub const OutputQueue = @import("../threading/output_router.zig").ClientOutputQueue;
pub const ClientOutput = @import("../threading/output_router.zig").ClientOutput;

// ============================================================================
// Platform
// ============================================================================

const is_linux = builtin.os.tag == .linux;
const SEND_FLAGS: u32 = if (is_linux) posix.MSG.NOSIGNAL else 0;

// ============================================================================
// Configuration
// ============================================================================

pub const RECV_BUFFER_SIZE: u32 = 16 * 1024 * 1024; // 16MB
pub const SEND_BUFFER_SIZE: u32 = 16 * 1024 * 1024; // 16MB
pub const FRAME_HEADER_SIZE: u32 = 4;
pub const MAX_MESSAGE_SIZE: u32 = 4 * 16384;
pub const MAX_CONSECUTIVE_ERRORS: u32 = 10;

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
// Stats
// ============================================================================

pub const ClientStats = struct {
    messages_received: u64,
    messages_sent: u64, // counts frames fully sent (matches C)
    bytes_received: u64,
    bytes_sent: u64,

    frames_dropped: u64,
    buffer_overflows: u64,
    decode_errors: u64,

    send_calls: u64,
    send_would_block: u64,
    send_full_flushes: u64,

    output_queue_drained: u64, // number of outputs moved into send buffer (enqueued frames)

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
// Frame Extraction
// ============================================================================

pub const FrameResult = union(enum) {
    frame: []const u8,
    incomplete,
    oversized: u32,
    empty,
};

// ============================================================================
// TcpClient
// ============================================================================

pub const TcpClient = struct {
    // Connection
    fd: posix.fd_t = -1,
    client_id: config.ClientId = 0,
    state: ClientState = .disconnected,

    // Buffers
    recv_buf: ?[]u8 = null,
    send_buf: ?[]u8 = null,
    allocator: ?std.mem.Allocator = null,

    // Receive indices
    recv_read: u32 = 0,
    recv_write: u32 = 0,

    // Send indices
    send_len: u32 = 0,
    send_pos: u32 = 0,

    /// Number of framed messages currently buffered in send_buf but not fully sent yet.
    /// This lets us increment stats.messages_sent only when a framed write completes
    /// (matching C tcp_listener.c).
    send_frames_pending: u32 = 0,

    // Protocol
    protocol: codec.Protocol = .unknown,

    // Output queue
    output_queue: ?*OutputQueue = null,

    // Encode scratch
    encode_buf: [256]u8 = undefined,

    // If output queue had a message but we couldn't enqueue it into send_buf yet,
    // we stash it here and retry later (prevents pop-then-drop).
    pending_output: ?ClientOutput = null,

    // Errors / stats
    consecutive_errors: u32 = 0,
    stats: ClientStats = ClientStats.init(),

    // Timestamps
    connect_time: i64 = 0,
    last_active: i64 = 0,

    const Self = @This();

    // ------------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------------

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
            .send_frames_pending = 0,
            .protocol = .unknown,
            .output_queue = null,
            .encode_buf = undefined,
            .pending_output = null,
            .consecutive_errors = 0,
            .stats = ClientStats.init(),
            .connect_time = now,
            .last_active = now,
        };
    }

    pub fn reset(self: *Self) void {
        if (self.fd >= 0) posix.close(self.fd);
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

    // ------------------------------------------------------------------------
    // Output queue
    // ------------------------------------------------------------------------

    pub fn setOutputQueue(self: *Self, queue: *OutputQueue) void {
        self.output_queue = queue;
    }

    pub fn hasOutputQueueMessages(self: *const Self) bool {
        if (self.pending_output != null) return true;
        if (self.output_queue) |q| return !q.isEmpty();
        return false;
    }

    /// Attempt to drain exactly ONE output message into send buffer.
    /// Returns 1 if a message was enqueued into send_buf, 0 otherwise.
    ///
    /// IMPORTANT: This never drops a message just because send buffer is full.
    /// If no space, we stash the message in pending_output and retry later.
    pub fn drainOutputQueueOne(self: *Self) u32 {
        const queue = self.output_queue orelse return 0;
        const send_buf = self.send_buf orelse return 0;

        // Acquire the next output to attempt.
        if (self.pending_output == null) {
            self.pending_output = queue.pop() orelse return 0;
        }

        const output = self.pending_output.?;
        const out_msg = &output.message;

        const use_binary = (self.protocol == .binary);

        // Encode
        const encoded_len = if (use_binary)
            binary_codec.encodeOutput(out_msg, &self.encode_buf) catch {
                // Encoding failed: treat as dropped (consistent with "format failed" skip in C)
                self.pending_output = null;
                return 0;
            }
        else
            csv_codec.encodeOutput(out_msg, &self.encode_buf) catch {
                self.pending_output = null;
                return 0;
            };

        const frame_size: u32 = FRAME_HEADER_SIZE + @as(u32, @intCast(encoded_len));
        const available = SEND_BUFFER_SIZE - self.send_len;

        // If no space, do NOT drop. Keep pending_output and retry later.
        if (frame_size > available) {
            self.stats.buffer_overflows += 1;
            return 0;
        }

        // Write length header (big-endian)
        const hdr = send_buf[self.send_len..][0..4];
        std.mem.writeInt(u32, hdr, @intCast(encoded_len), .big);
        self.send_len += FRAME_HEADER_SIZE;

        // Write payload
        @memcpy(send_buf[self.send_len..][0..encoded_len], self.encode_buf[0..encoded_len]);
        self.send_len += @intCast(encoded_len);

        self.send_frames_pending += 1;
        self.stats.output_queue_drained += 1;

        // Successfully staged; clear pending.
        self.pending_output = null;
        return 1;
    }

    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------

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

    // ------------------------------------------------------------------------
    // Receive
    // ------------------------------------------------------------------------

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

    pub fn hasReceivedData(self: *const Self) bool {
        return self.recv_write > self.recv_read;
    }

    // ------------------------------------------------------------------------
    // Framing extraction
    // ------------------------------------------------------------------------

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

    // ------------------------------------------------------------------------
    // Send
    // ------------------------------------------------------------------------

    pub fn hasPendingSend(self: *const Self) bool {
        return self.send_pos < self.send_len;
    }

    /// Flush send buffer with a SINGLE non-blocking send() call.
    /// - If WouldBlock: caller enables EPOLLOUT.
    /// - If buffer becomes empty: we commit send_frames_pending into stats.messages_sent.
    pub fn flushSend(self: *Self) !void {
        if (self.send_pos >= self.send_len) return;

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

        if (self.send_pos == self.send_len) {
            // Fully flushed
            self.send_pos = 0;
            self.send_len = 0;
            self.stats.send_full_flushes += 1;

            // Now it's safe to say these frames are "sent"
            self.stats.messages_sent += self.send_frames_pending;
            self.send_frames_pending = 0;
        }
    }

    /// Work predicate: pending send OR output queue messages OR pending_output stash
    pub fn hasWorkToDo(self: *const Self) bool {
        if (self.hasPendingSend()) return true;
        if (self.hasOutputQueueMessages()) return true;
        return false;
    }

    // ------------------------------------------------------------------------
    // Protocol detection
    // ------------------------------------------------------------------------

    pub fn detectProtocol(self: *Self) void {
        if (self.protocol != .unknown) return;
        if (!self.hasReceivedData()) return;
        self.protocol = codec.detectProtocol(self.getReceivedData());
    }

    pub fn getProtocol(self: *const Self) codec.Protocol {
        return self.protocol;
    }

    // ------------------------------------------------------------------------
    // Misc
    // ------------------------------------------------------------------------

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
    };
}

