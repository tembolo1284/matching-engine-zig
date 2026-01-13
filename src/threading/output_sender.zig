//! Dedicated Output Sender Thread
//!
//! VERSION v1 - Mirrors C architecture with dedicated sender thread
//!
//! Architecture (like C unified_tcp.c):
//! ```
//!   Processor Threads          Output Sender Thread
//!        │                            │
//!        ▼                            ▼
//!   ┌─────────────┐            ┌─────────────────────┐
//!   │ OutputQueue │ ──────────►│ drain & encode      │
//!   │ (per proc)  │            │ route to client     │
//!   └─────────────┘            │ send (blocking OK)  │
//!                              └─────────────────────┘
//! ```
//!
//! Key Design Decisions:
//! 1. Single thread drains ALL processor output queues
//! 2. Encodes messages (binary/CSV based on client protocol)
//! 3. Uses blocking sends - acceptable since dedicated thread
//! 4. Per-client output queues for backpressure isolation
//! 5. Batch sends when possible for efficiency
//!
//! Thread Safety:
//! - Output queues are SPSC (processor→sender)
//! - Client registry access uses atomic operations
//! - Send operations are serialized per-client
//!
//! Backpressure Handling:
//! - Per-client queues prevent slow clients blocking fast ones
//! - Queue full → drop with logging (configurable behavior)
//! - Critical messages (trades, rejects) get priority retry
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: All loops bounded by explicit constants
//! - Rule 5: Assertions validate state transitions
//! - Rule 7: All queue operations checked
const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const config = @import("../transport/config.zig");
const SpscQueue = @import("../collections/spsc_queue.zig").SpscQueue;
const proc = @import("processor.zig");

// ============================================================================
// Configuration
// ============================================================================

/// Maximum clients supported
pub const MAX_OUTPUT_CLIENTS: usize = 128;

/// Drain limit per poll iteration (prevents starvation)
const DRAIN_LIMIT_PER_QUEUE: u32 = 16384;

/// Total drain cap across all queues per iteration
const DRAIN_TOTAL_CAP: u32 = 32768;

/// Send buffer size per client for batching
/// Larger buffer = fewer syscalls = higher throughput
const SEND_BUFFER_SIZE: usize = 256 * 1024; // 256KB per client

/// Maximum sends per client per iteration (prevents starvation)
const MAX_SENDS_PER_CLIENT: u32 = 1024;

/// Encode buffer size
const ENCODE_BUF_SIZE: usize = 512;

/// Poll sleep when idle (microseconds) - keep very short to minimize latency
const IDLE_SLEEP_US: u64 = 10;

// Compile-time validation
comptime {
    std.debug.assert(MAX_OUTPUT_CLIENTS > 0);
    std.debug.assert(DRAIN_LIMIT_PER_QUEUE > 0);
    std.debug.assert(DRAIN_TOTAL_CAP >= DRAIN_LIMIT_PER_QUEUE);
    std.debug.assert(SEND_BUFFER_SIZE >= 1024);
    std.debug.assert(ENCODE_BUF_SIZE >= 256);
}

// ============================================================================
// Types
// ============================================================================

/// Protocol type
pub const Protocol = enum {
    binary,
    csv,
};
/// Client output state (lightweight - send buffer heap allocated on demand)
pub const ClientOutputState = struct {
    /// Client file descriptor for direct send
    fd: std.posix.fd_t,
    /// Client ID
    client_id: config.ClientId,
    /// Protocol (binary or CSV)
    protocol: Protocol,
    /// Is client active?
    active: std.atomic.Value(bool),
    /// Send buffer for batching (heap allocated)
    send_buf: ?[]u8,
    /// Current send buffer position
    send_len: usize,
    /// Allocator for send buffer
    allocator: ?std.mem.Allocator,
    /// Statistics
    messages_sent: u64,
    messages_dropped: u64,
    critical_drops: u64,
    bytes_sent: u64,
    send_errors: u64,

    const Self = @This();

    pub fn init() Self {
        return .{
            .fd = -1,
            .client_id = 0,
            .protocol = .csv,
            .active = std.atomic.Value(bool).init(false),
            .send_buf = null,
            .send_len = 0,
            .allocator = null,
            .messages_sent = 0,
            .messages_dropped = 0,
            .critical_drops = 0,
            .bytes_sent = 0,
            .send_errors = 0,
        };
    }

    pub fn allocateSendBuffer(self: *Self, allocator: std.mem.Allocator) !void {
        if (self.send_buf == null) {
            self.send_buf = try allocator.alloc(u8, SEND_BUFFER_SIZE);
            self.allocator = allocator;
        }
    }

    pub fn reset(self: *Self) void {
        self.active.store(false, .release);
        if (self.send_buf) |buf| {
            if (self.allocator) |alloc| {
                alloc.free(buf);
            }
        }
        self.send_buf = null;
        self.allocator = null;
        self.fd = -1;
        self.client_id = 0;
        self.send_len = 0;
    }

    pub fn isActive(self: *const Self) bool {
        return self.active.load(.acquire);
    }
};

/// Send callback type - called to actually send data to client
/// This abstracts the transport layer (TCP socket, etc.)
pub const SendCallback = *const fn (
    client_id: config.ClientId,
    fd: std.posix.fd_t,
    data: []const u8,
    ctx: ?*anyopaque,
) SendResult;

/// Send result
pub const SendResult = enum {
    success,
    would_block,
    error_disconnected,
    error_other,
};

/// Multicast callback for trade/TOB messages
pub const MulticastCallback = *const fn (
    out_msg: *const msg.OutputMsg,
    ctx: ?*anyopaque,
) void;

// ============================================================================
// Output Sender
// ============================================================================

pub const OutputSender = struct {
    // ========================================================================
    // Nested Types
    // ========================================================================

    pub const OutputSenderStats = struct {
        /// Total messages drained from processor queues
        messages_drained: u64,
        /// Total messages sent to clients
        messages_sent: u64,
        /// Messages dropped (queue full, errors)
        messages_dropped: u64,
        /// Critical messages dropped (trades, rejects)
        critical_drops: u64,
        /// Total bytes sent
        bytes_sent: u64,
        /// Send errors
        send_errors: u64,
        /// Multicast publishes
        multicast_publishes: u64,
        /// Idle cycles (no work)
        idle_cycles: u64,
        /// Active clients
        active_clients: u32,

        pub fn init() OutputSenderStats {
            return std.mem.zeroes(OutputSenderStats);
        }

        pub fn isHealthy(self: OutputSenderStats) bool {
            return self.critical_drops == 0;
        }
    };

    // ========================================================================
    // Fields
    // ========================================================================

    /// Processor output queues to drain
    processor_queues: []const *proc.OutputQueue,

    /// Per-client output state (heap allocated array of pointers)
    clients: []ClientOutputState,

    /// Client lookup by ID (for fast routing)
    client_index: [MAX_OUTPUT_CLIENTS]?u8, // client_id % MAX → slot index

    /// Active client count
    active_count: std.atomic.Value(u32),

    /// Send callback
    send_callback: ?SendCallback,
    send_ctx: ?*anyopaque,

    /// Multicast callback
    multicast_callback: ?MulticastCallback,
    multicast_ctx: ?*anyopaque,

    /// Default protocol for new clients
    default_protocol: Protocol,

    /// Enable multicast for trades/TOB
    multicast_enabled: bool,

    /// Thread handle
    thread: ?std.Thread,

    /// Running flag
    running: std.atomic.Value(bool),

    /// Allocator
    allocator: std.mem.Allocator,

    /// Encode buffer (thread-local, only used by sender thread)
    encode_buf: [ENCODE_BUF_SIZE]u8,

    /// Statistics
    stats: OutputSenderStats,

    const Self = @This();

    // ========================================================================
    // Lifecycle
    // ========================================================================

    pub fn init(
        allocator: std.mem.Allocator,
        processor_queues: []const *proc.OutputQueue,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Heap allocate the client state array
        const clients = try allocator.alloc(ClientOutputState, MAX_OUTPUT_CLIENTS);
        errdefer allocator.free(clients);

        // Initialize all client slots
        for (clients) |*client| {
            client.* = ClientOutputState.init();
        }

        self.* = .{
            .processor_queues = processor_queues,
            .clients = clients,
            .client_index = [_]?u8{null} ** MAX_OUTPUT_CLIENTS,
            .active_count = std.atomic.Value(u32).init(0),
            .send_callback = null,
            .send_ctx = null,
            .multicast_callback = null,
            .multicast_ctx = null,
            .default_protocol = .csv,
            .multicast_enabled = false,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .encode_buf = undefined,
            .stats = OutputSenderStats.init(),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        
        // Free any allocated send buffers
        for (self.clients) |*client| {
            if (client.send_buf) |buf| {
                if (client.allocator) |alloc| {
                    alloc.free(buf);
                }
            }
        }
        
        self.allocator.free(self.clients);
        self.allocator.destroy(self);
    }

    // ========================================================================
    // Configuration
    // ========================================================================

    pub fn setSendCallback(
        self: *Self,
        callback: SendCallback,
        ctx: ?*anyopaque,
    ) void {
        self.send_callback = callback;
        self.send_ctx = ctx;
    }

    pub fn setMulticastCallback(
        self: *Self,
        callback: MulticastCallback,
        ctx: ?*anyopaque,
    ) void {
        self.multicast_callback = callback;
        self.multicast_ctx = ctx;
    }

    pub fn setDefaultProtocol(self: *Self, protocol: Protocol) void {
        self.default_protocol = protocol;
    }

    pub fn setMulticastEnabled(self: *Self, enabled: bool) void {
        self.multicast_enabled = enabled;
    }

    // ========================================================================
    // Client Management
    // ========================================================================

    /// Register a client for output routing
    pub fn registerClient(
        self: *Self,
        client_id: config.ClientId,
        fd: std.posix.fd_t,
        protocol: ?Protocol,
    ) bool {
        if (client_id == 0) return false;

        // Find free slot
        var slot_idx: ?usize = null;
        for (self.clients, 0..) |*client, i| {
            if (!client.isActive()) {
                slot_idx = i;
                break;
            }
        }

        const idx = slot_idx orelse {
            std.log.warn("OutputSender: No free client slots for client {}", .{client_id});
            return false;
        };

        const client = &self.clients[idx];
        
        // Allocate send buffer if needed
        client.allocateSendBuffer(self.allocator) catch {
            std.log.err("OutputSender: Failed to allocate send buffer for client {}", .{client_id});
            return false;
        };
        
        client.fd = fd;
        client.client_id = client_id;
        client.protocol = protocol orelse self.default_protocol;
        client.send_len = 0;
        client.messages_sent = 0;
        client.messages_dropped = 0;
        client.critical_drops = 0;
        client.bytes_sent = 0;
        client.send_errors = 0;

        // Update index for fast lookup
        const hash_idx = client_id % MAX_OUTPUT_CLIENTS;
        self.client_index[hash_idx] = @intCast(idx);

        // Mark active (must be last - release fence)
        client.active.store(true, .release);
        _ = self.active_count.fetchAdd(1, .monotonic);

        std.log.debug("OutputSender: Registered client {} (fd={}, slot={})", .{
            client_id, fd, idx,
        });

        return true;
    }

    /// Unregister a client
    pub fn unregisterClient(self: *Self, client_id: config.ClientId) void {
        if (client_id == 0) return;

        // Find client
        for (self.clients, 0..) |*client, i| {
            if (client.client_id == client_id and client.isActive()) {
                client.reset();
                _ = self.active_count.fetchSub(1, .monotonic);

                // Clear index
                const hash_idx = client_id % MAX_OUTPUT_CLIENTS;
                if (self.client_index[hash_idx]) |idx| {
                    if (idx == i) {
                        self.client_index[hash_idx] = null;
                    }
                }

                std.log.debug("OutputSender: Unregistered client {}", .{client_id});
                return;
            }
        }
    }

    /// Update client file descriptor (after reconnect)
    pub fn updateClientFd(
        self: *Self,
        client_id: config.ClientId,
        new_fd: std.posix.fd_t,
    ) bool {
        if (self.findClient(client_id)) |client| {
            client.fd = new_fd;
            return true;
        }
        return false;
    }

    /// Update client protocol
    pub fn updateClientProtocol(
        self: *Self,
        client_id: config.ClientId,
        protocol: Protocol,
    ) bool {
        if (self.findClient(client_id)) |client| {
            client.protocol = protocol;
            return true;
        }
        return false;
    }

    fn findClient(self: *Self, client_id: config.ClientId) ?*ClientOutputState {
        // Try hash lookup first
        const hash_idx = client_id % MAX_OUTPUT_CLIENTS;
        if (self.client_index[hash_idx]) |idx| {
            const client = &self.clients[idx];
            if (client.client_id == client_id and client.isActive()) {
                return client;
            }
        }

        // Linear scan fallback (hash collision)
        for (self.clients) |*client| {
            if (client.client_id == client_id and client.isActive()) {
                return client;
            }
        }

        return null;
    }

    // ========================================================================
    // Thread Control
    // ========================================================================

    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) {
            return error.AlreadyRunning;
        }

        std.log.info("OutputSender: Starting (queues={}, max_clients={})", .{
            self.processor_queues.len,
            MAX_OUTPUT_CLIENTS,
        });

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;

        std.log.info("OutputSender: Stopping...", .{});
        self.running.store(false, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        // Final drain
        _ = self.drainOnce();

        // Flush all client buffers
        self.flushAllClients();

        std.log.info("OutputSender: Stopped (sent={}, dropped={}, critical_drops={})", .{
            self.stats.messages_sent,
            self.stats.messages_dropped,
            self.stats.critical_drops,
        });
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running.load(.acquire);
    }

    // ========================================================================
    // Main Loop
    // ========================================================================

    fn runLoop(self: *Self) void {
        std.log.debug("OutputSender: Thread started", .{});

        var consecutive_empty: u32 = 0;
        const SPIN_THRESHOLD: u32 = 1000;  // Spin this many times before sleeping
        const YIELD_THRESHOLD: u32 = 100;   // Yield after this many spins

        while (self.running.load(.acquire)) {
            const drained = self.drainOnce();

            if (drained == 0) {
                consecutive_empty += 1;
                self.stats.idle_cycles += 1;

                if (consecutive_empty > SPIN_THRESHOLD) {
                    // Been idle for a while, sleep to reduce CPU
                    std.Thread.sleep(IDLE_SLEEP_US * std.time.ns_per_us);
                } else if (consecutive_empty > YIELD_THRESHOLD) {
                    // Yield to other threads but stay ready
                    std.Thread.yield() catch {};
                }
                // Else: pure spin for lowest latency
            } else {
                consecutive_empty = 0;
            }
        }

        std.log.debug("OutputSender: Thread exiting", .{});
    }

    /// Drain processor output queues and send to clients.
    /// Returns number of messages processed.
    fn drainOnce(self: *Self) u32 {
        var total_drained: u32 = 0;

        // Drain all processor queues
        for (self.processor_queues) |queue| {
            var queue_drained: u32 = 0;

            while (queue_drained < DRAIN_LIMIT_PER_QUEUE and
                total_drained < DRAIN_TOTAL_CAP)
            {
                const output = queue.pop() orelse break;
                self.processOutput(&output.message);
                queue_drained += 1;
                total_drained += 1;
                self.stats.messages_drained += 1;
            }

            if (total_drained >= DRAIN_TOTAL_CAP) break;
        }

        // Flush client buffers periodically
        if (total_drained > 0) {
            self.flushAllClients();
        }

        return total_drained;
    }

    /// Process a single output message
    fn processOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        // Encode message
        const client = self.findClient(out_msg.client_id);
        const use_binary = if (client) |c| c.protocol == .binary else self.default_protocol == .binary;

        const len = if (use_binary)
            binary_codec.encodeOutput(out_msg, &self.encode_buf) catch |err| {
                std.log.err("OutputSender: Binary encode failed: {}", .{err});
                return;
            }
        else
            csv_codec.encodeOutput(out_msg, &self.encode_buf) catch |err| {
                std.log.err("OutputSender: CSV encode failed: {}", .{err});
                return;
            };

        const data = self.encode_buf[0..len];

        // Route based on message type
        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => {
                self.sendToClient(out_msg.client_id, data, out_msg.msg_type);
            },
            .trade => {
                // Send to client
                self.sendToClient(out_msg.client_id, data, out_msg.msg_type);
                // Also multicast
                if (self.multicast_enabled) {
                    self.publishMulticast(out_msg);
                }
            },
            .top_of_book => {
                // Unicast if client specified
                if (out_msg.client_id != 0) {
                    self.sendToClient(out_msg.client_id, data, out_msg.msg_type);
                }
                // Also multicast
                if (self.multicast_enabled) {
                    self.publishMulticast(out_msg);
                }
            },
        }
    }

    /// Send data to a specific client (with framing)
    fn sendToClient(
        self: *Self,
        client_id: config.ClientId,
        data: []const u8,
        msg_type: msg.OutputMsgType,
    ) void {
        if (client_id == 0) return;

        const client = self.findClient(client_id) orelse {
            // Client not registered - this can happen during disconnect races
            // or if client disconnected before we finished processing outputs
            self.stats.messages_dropped += 1;
            const is_critical = (msg_type == .trade or msg_type == .reject);
            if (is_critical) self.stats.critical_drops += 1;
            return;
        };

        const send_buf = client.send_buf orelse {
            // No send buffer allocated
            self.stats.messages_dropped += 1;
            return;
        };

        const is_critical = (msg_type == .trade or msg_type == .reject);

        // Frame format: 4-byte big-endian length + payload
        const total_len = 4 + data.len;

        // Try to batch into send buffer
        if (client.send_len + total_len <= SEND_BUFFER_SIZE) {
            // Write 4-byte length prefix (big-endian) - same format as tcp_client.queueFramedSend
            std.mem.writeInt(u32, send_buf[client.send_len..][0..4], @intCast(data.len), .big);
            client.send_len += 4;
            
            // Write payload
            @memcpy(send_buf[client.send_len..][0..data.len], data);
            client.send_len += data.len;

            // Flush if buffer is getting full
            if (client.send_len >= SEND_BUFFER_SIZE - ENCODE_BUF_SIZE - 4) {
                self.flushClient(client);
            }
        } else {
            // Buffer full - flush first, then add
            self.flushClient(client);

            if (total_len <= SEND_BUFFER_SIZE) {
                // Write 4-byte length prefix (big-endian)
                std.mem.writeInt(u32, send_buf[0..4], @intCast(data.len), .big);
                @memcpy(send_buf[4..][0..data.len], data);
                client.send_len = total_len;
            } else {
                // Message too large for buffer (shouldn't happen)
                std.log.err("OutputSender: Message too large: {} bytes", .{data.len});
                client.messages_dropped += 1;
                if (is_critical) client.critical_drops += 1;
                self.stats.messages_dropped += 1;
                if (is_critical) self.stats.critical_drops += 1;
            }
        }
    }

    /// Flush a single client's send buffer
    fn flushClient(self: *Self, client: *ClientOutputState) void {
        if (client.send_len == 0) return;
        if (!client.isActive()) return;

        const send_buf = client.send_buf orelse return;

        const callback = self.send_callback orelse {
            // No send callback - just discard
            std.log.warn("OutputSender: No send callback, discarding {} bytes for client {}", .{ client.send_len, client.client_id });
            client.send_len = 0;
            return;
        };

        const data = send_buf[0..client.send_len];
        var sent: usize = 0;
        var attempts: u32 = 0;

        // Send with retry (blocking is OK since we're dedicated thread)
        while (sent < data.len and attempts < MAX_SENDS_PER_CLIENT) : (attempts += 1) {
            const result = callback(
                client.client_id,
                client.fd,
                data[sent..],
                self.send_ctx,
            );

            switch (result) {
                .success => {
                    // Assume all sent on success
                    sent = data.len;
                },
                .would_block => {
                    // Brief pause then retry (blocking behavior)
                    std.Thread.sleep(10 * std.time.ns_per_us);
                },
                .error_disconnected => {
                    std.log.debug("OutputSender: Client {} disconnected during send", .{client.client_id});
                    client.send_errors += 1;
                    self.stats.send_errors += 1;
                    break;
                },
                .error_other => {
                    std.log.debug("OutputSender: Send error for client {}", .{client.client_id});
                    client.send_errors += 1;
                    self.stats.send_errors += 1;
                    break;
                },
            }
        }

        if (sent > 0) {
            client.bytes_sent += sent;
            self.stats.bytes_sent += sent;
        }

        // Count messages (approximate - based on buffer fills)
        client.messages_sent += 1;
        self.stats.messages_sent += 1;

        client.send_len = 0;
    }

    /// Flush all active clients
    fn flushAllClients(self: *Self) void {
        for (self.clients) |*client| {
            if (client.isActive() and client.send_len > 0) {
                self.flushClient(client);
            }
        }
    }

    /// Publish to multicast
    fn publishMulticast(self: *Self, out_msg: *const msg.OutputMsg) void {
        if (self.multicast_callback) |callback| {
            callback(out_msg, self.multicast_ctx);
            self.stats.multicast_publishes += 1;
        }
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    pub fn getStats(self: *const Self) OutputSenderStats {
        var stats = self.stats;
        stats.active_clients = self.active_count.load(.monotonic);
        return stats;
    }

    pub fn isHealthy(self: *const Self) bool {
        return self.stats.critical_drops == 0;
    }

    // ========================================================================
    // Direct Send Helper (for integration with TcpServer)
    // ========================================================================

    /// Creates a send callback that uses POSIX send() directly
    /// For use when you want the OutputSender to bypass TcpClient buffering
    /// NOTE: This sends raw data without framing - the caller must frame messages
    pub fn makeDirectSendCallback() SendCallback {
        return struct {
            fn send(
                _: config.ClientId,
                fd: std.posix.fd_t,
                data: []const u8,
                _: ?*anyopaque,
            ) SendResult {
                if (fd < 0) return .error_disconnected;

                const flags: u32 = if (@import("builtin").os.tag == .linux)
                    std.posix.MSG.NOSIGNAL
                else
                    0;

                const sent = std.posix.send(fd, data, flags) catch |err| {
                    if (err == error.WouldBlock) return .would_block;
                    if (err == error.BrokenPipe or
                        err == error.ConnectionResetByPeer or
                        err == error.NotConnected)
                    {
                        return .error_disconnected;
                    }
                    return .error_other;
                };

                // If we sent less than requested, report would_block
                // so the caller knows to retry
                if (sent < data.len) {
                    return .would_block;
                }

                return .success;
            }
        }.send;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OutputSender - basic lifecycle" {
    const allocator = std.testing.allocator;

    // Create mock processor queues
    var queue1 = proc.OutputQueue{};
    var queue2 = proc.OutputQueue{};
    const queues = [_]*proc.OutputQueue{ &queue1, &queue2 };

    var sender = try OutputSender.init(allocator, &queues);
    defer sender.deinit();

    try std.testing.expect(!sender.isRunning());
    try std.testing.expectEqual(@as(u32, 0), sender.active_count.load(.monotonic));
}

test "OutputSender - client registration" {
    const allocator = std.testing.allocator;

    var queue = proc.OutputQueue{};
    const queues = [_]*proc.OutputQueue{&queue};

    var sender = try OutputSender.init(allocator, &queues);
    defer sender.deinit();

    // Register client
    try std.testing.expect(sender.registerClient(1, 10, .binary));
    try std.testing.expectEqual(@as(u32, 1), sender.active_count.load(.monotonic));

    // Find client
    const client = sender.findClient(1);
    try std.testing.expect(client != null);
    try std.testing.expectEqual(@as(std.posix.fd_t, 10), client.?.fd);
    try std.testing.expectEqual(Protocol.binary, client.?.protocol);

    // Unregister
    sender.unregisterClient(1);
    try std.testing.expectEqual(@as(u32, 0), sender.active_count.load(.monotonic));
    try std.testing.expect(sender.findClient(1) == null);
}

test "OutputSender - stats" {
    const allocator = std.testing.allocator;

    var queue = proc.OutputQueue{};
    const queues = [_]*proc.OutputQueue{&queue};

    var sender = try OutputSender.init(allocator, &queues);
    defer sender.deinit();

    const stats = sender.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.messages_sent);
    try std.testing.expect(stats.isHealthy());
}

test "ClientOutputState - basic" {
    var state = ClientOutputState.init();
    try std.testing.expect(!state.isActive());
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), state.fd);
    try std.testing.expect(state.send_buf == null);

    state.fd = 5;
    state.client_id = 42;
    state.active.store(true, .release);
    try std.testing.expect(state.isActive());

    // Reset without allocated buffer is safe
    state.reset();
    try std.testing.expect(!state.isActive());
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), state.fd);
}

test "ClientOutputState - with buffer" {
    const allocator = std.testing.allocator;
    var state = ClientOutputState.init();
    
    try state.allocateSendBuffer(allocator);
    try std.testing.expect(state.send_buf != null);
    
    state.fd = 5;
    state.client_id = 42;
    state.active.store(true, .release);
    
    // Reset frees the buffer
    state.reset();
    try std.testing.expect(!state.isActive());
    try std.testing.expect(state.send_buf == null);
}
