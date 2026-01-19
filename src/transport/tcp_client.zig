//! TCP client connection state and buffer management.
//!
//! FIXED VERSION v7 - C Server Architecture Match (Write-Side)
//!
//! Key fixes vs your v6:
//! 1) Replaced 16MB multi-message send buffer with C-style per-message write_state.
//!    - ONE framed message pending at a time (header+payload)
//!    - Partial writes resume via EPOLLOUT
//!    - No "pop then drop because send buffer is full"
//! 2) drainOutputQueueOne() now:
//!    - Does NOTHING if a write is pending
//!    - Pops exactly ONE message and initializes write_state
//! 3) encode_buf increased to 4096 (matches C MAX_FRAMED_MESSAGE_SIZE)
//! 4) Added strict framing payload max (4096) to match C message_framing.
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
pub const OutputQueue = @import("../threading/output_router.zig").ClientOutputQueue;
pub const ClientOutput = @import("../threading/output_router.zig").ClientOutput;

// ============================================================================
// Platform Detection
// ============================================================================

const is_linux = builtin.os.tag == .linux;
const SEND_FLAGS: u32 = if (is_linux) posix.MSG.NOSIGNAL else 0;

// ============================================================================
// Configuration (Receive-side stays flexible; Write-side matches C framing)
// ============================================================================

pub const RECV_BUFFER_SIZE: u32 = 16 * 1024 * 1024; // 16MB receive buffer (fine)
pub const FRAME_HEADER_SIZE: u32 = 4;

// Receive-side max message size (your protocol frames are small; keep large if you want)
pub const MAX_MESSAGE_SIZE: u32 = 4 * 16384; // 65536

// Write-side framing: MATCH C EXACTLY
pub const MAX_FRAMED_MESSAGE_SIZE: u32 = 4096; // C: MAX_FRAMED_MESSAGE_SIZE
pub const FRAMING_BUFFER_SIZE: u32 = MAX_FRAMED_MESSAGE_SIZE + FRAME_HEADER_SIZE + 256; // C: FRAMING_BUFFER_SIZE

pub const MAX_CONSECUTIVE_ERRORS: u32 = 10;

/// NOTE: With C-style write_state, we don't batch-drain into a giant send buffer.
/// We keep this constant for compatibility; it's no longer used for write buffering.
pub const MAX_OUTPUT_DRAIN_PER_WRITE: u32 = 1024;

const RECV_COMPACT_THRESHOLD: u32 = RECV_BUFFER_SIZE / 2;

comptime {
    std.debug.assert(RECV_BUFFER_SIZE >= MAX_MESSAGE_SIZE + FRAME_HEADER_SIZE);
    std.debug.assert(MAX_MESSAGE_SIZE > 0);
    std.debug.assert(MAX_CONSECUTIVE_ERRORS > 0);
    std.debug.assert(FRAME_HEADER_SIZE == 4);

    // C-style write buffer invariants
    std.debug.assert(FRAMING_BUFFER_SIZE > MAX_FRAMED_MESSAGE_SIZE + FRAME_HEADER_SIZE);
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
    output_queue_drained: u64, // messages drained from output queue

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

    // === Heap-Allocated Buffers (receive only; send is now fixed write_state) ===
    recv_buf: ?[]u8 = null,
    allocator: ?std.mem.Allocator = null,

    // === Receive Buffer Indices ===
    recv_read: u32 = 0,
    recv_write: u32 = 0,

    // === Protocol ===
    protocol: codec.Protocol = .unknown,

    // === Output Queue (from OutputRouter) ===
    output_queue: ?*OutputQueue = null,

    // === Encode buffer (payload only) ===
    encode_buf: [MAX_FRAMED_MESSAGE_SIZE]u8 = undefined,

    // === C-style Write State (ONE framed message pending) ===
    has_pending_write: bool = false,
    write_total_len: u32 = 0,
    write_written: u32 = 0,
    write_buf: [FRAMING_BUFFER_SIZE]u8 = undefined,

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

        const now = std.time.timestamp();

        return .{
            .fd = fd,
            .client_id = client_id,
            .state = .connected,
            .recv_buf = recv_buf,
            .allocator = allocator,
            .recv_read = 0,
            .recv_write = 0,
            .protocol = .unknown,
            .output_queue = null,
            .encode_buf = undefined,

            .has_pending_write = false,
            .write_total_len = 0,
            .write_written = 0,
            .write_buf = undefined,

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
    // Output Queue
    // ========================================================================

    pub fn setOutputQueue(self: *Self, queue: *OutputQueue) void {
        self.output_queue = queue;
    }

    pub fn hasOutputQueueMessages(self: *const Self) bool {
        if (self.output_queue) |queue| {
            return !queue.isEmpty();
        }
        return false;
    }

    // ========================================================================
    // C-style write_state helpers
    // ========================================================================

    fn initWriteState(self: *Self, payload: []const u8) bool {
        if (payload.len == 0) return false;

        if (payload.len > MAX_FRAMED_MESSAGE_SIZE) {
            // This matches C behavior: reject too-large framed payloads.
            self.stats.frames_dropped += 1;
            return false;
        }

        // [4-byte big-endian length][payload]
        std.mem.writeInt(u32, self.write_buf[0..4], @intCast(payload.len), .big);
        @memcpy(self.write_buf[4..][0..payload.len], payload);

        self.write_total_len = FRAME_HEADER_SIZE + @as(u32, @intCast(payload.len));
        self.write_written = 0;
        self.has_pending_write = true;
        return true;
    }

    /// Attempt ONE non-blocking send() for the current pending framed message.
    /// Returns:
    /// - true  if the pending message is complete (no longer pending)
    /// - false if still pending (partial write)
    /// Errors:
    /// - error.WouldBlock on EAGAIN/EWOULDBLOCK
    pub fn flushWriteStateOnce(self: *Self) !bool {
        if (!self.has_pending_write) return true;

        const remaining: u32 = self.write_total_len - self.write_written;
        if (remaining == 0) {
            self.has_pending_write = false;
            self.write_total_len = 0;
            self.write_written = 0;
            return true;
        }

        const slice = self.write_buf[self.write_written..self.write_total_len];

        const sent = posix.send(self.fd, slice, SEND_FLAGS) catch |err| {
            if (net_utils.isWouldBlock(err)) {
                self.stats.send_would_block += 1;
                return error.WouldBlock;
            }
            return err;
        };

        self.stats.send_calls += 1;
        self.write_written += @intCast(sent);
        self.stats.bytes_sent += sent;
        self.touch();

        if (self.write_written >= self.write_total_len) {
            self.has_pending_write = false;
            self.write_total_len = 0;
            self.write_written = 0;
            self.stats.send_full_flushes += 1;
            return true;
        }
        return false;
    }

    /// True if there is a pending write in progress.
    pub fn hasPendingWrite(self: *const Self) bool {
        return self.has_pending_write;
    }

    /// Drain exactly ONE message from output queue into write_state.
    /// IMPORTANT: Does nothing if there is already a pending write.
    /// Returns 1 if a message was dequeued and write_state initialized.
    pub fn drainOutputQueueOne(self: *Self) u32 {
        if (self.has_pending_write) return 0;

        const queue = self.output_queue orelse return 0;

        // Pop ONE message from queue
        const output = queue.pop() orelse return 0;
        const out_msg = &output.message;

        const use_binary = (self.protocol == .binary);

        // Encode payload into encode_buf (payload only; framing in initWriteState)
        const encoded_len = if (use_binary)
            binary_codec.encodeOutput(out_msg, &self.encode_buf) catch {
                self.stats.decode_errors += 1;
                return 0;
            }
        else
            csv_codec.encodeOutput(out_msg, &self.encode_buf) catch {
                self.stats.decode_errors += 1;
                return 0;
            };

        // Initialize write state (C-style). If too large, it's dropped.
        if (!self.initWriteState(self.encode_buf[0..encoded_len])) {
            // Too large or invalid
            self.stats.buffer_overflows += 1;
            return 0;
        }

        self.stats.output_queue_drained += 1;
        self.stats.messages_sent += 1;
        return 1;
    }

    /// Legacy: batch drain (no longer used in C-style design).
    /// Kept for compatibility; now just drains at most 1 because we only allow
    /// one pending write at a time.
    pub fn drainOutputQueue(self: *Self) u32 {
        return self.drainOutputQueueOne();
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
    // Frame Extraction (Receive-side framing)
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
            // Protocol error / oversized input; drop header and move on
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
    // Send Operations (Compatibility wrappers)
    // ========================================================================

    /// Legacy API: queue a framed message for sending.
    /// With C-style write_state, this only succeeds if no pending write exists.
    pub fn queueFramedSend(self: *Self, data: []const u8) bool {
        if (self.has_pending_write) {
            self.stats.buffer_overflows += 1;
            return false;
        }
        return self.initWriteState(data);
    }

    /// Legacy API: queue raw data without framing (rarely used in your engine).
    /// For safety, we still frame it the same way; TCP stream requires framing.
    pub fn queueRawSend(self: *Self, data: []const u8) bool {
        return self.queueFramedSend(data);
    }

    /// Legacy API: flush send buffer once.
    /// Now flushes the pending write_state once.
    pub fn flushSend(self: *Self) !void {
        _ = try self.flushWriteStateOnce();
    }

    /// Legacy API: flush fully (shutdown).
    /// This now loops on the pending message until complete.
    pub fn flushSendFully(self: *Self) !void {
        var attempts: u32 = 0;
        const max_attempts: u32 = 10000;

        while (self.has_pending_write and attempts < max_attempts) : (attempts += 1) {
            const done = self.flushWriteStateOnce() catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(100_000); // 100us
                    continue;
                }
                return err;
            };
            if (done) break;
        }
    }

    /// Legacy API: indicates if socket has pending data to send.
    pub fn hasPendingSend(self: *const Self) bool {
        return self.has_pending_write;
    }

    pub fn hasWorkToDo(self: *const Self) bool {
        if (self.hasPendingWrite()) return true;
        if (self.hasOutputQueueMessages()) return true;
        return false;
    }

    /// Approximate send buffer usage (compat): 0 or 100 depending on pending.
    pub fn getSendBufferUsage(self: *const Self) u32 {
        return if (self.has_pending_write) 100 else 0;
    }

    pub fn getPendingSendBytes(self: *const Self) u32 {
        if (!self.has_pending_write) return 0;
        return self.write_total_len - self.write_written;
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

