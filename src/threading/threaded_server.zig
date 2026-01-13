//! Threaded server with I/O thread, dual processor threads, and dedicated output sender.
//!
//! VERSION v6 - Architecture mirrors C matching engine
//!
//! Thread Architecture:
//! ```
//!   ┌─────────────────────────────────────────────────────────────────┐
//!   │                        I/O Thread                               │
//!   │  - TCP/UDP accept & receive                                     │
//!   │  - Parse input messages                                         │
//!   │  - Route to processor input queues                              │
//!   │  - NO output handling (delegated to OutputSender)               │
//!   └──────────────────────────┬──────────────────────────────────────┘
//!                              │
//!              ┌───────────────┴───────────────┐
//!              ▼                               ▼
//!   ┌─────────────────────┐         ┌─────────────────────┐
//!   │   Processor 0       │         │   Processor 1       │
//!   │   (Symbols A-M)     │         │   (Symbols N-Z)     │
//!   │                     │         │                     │
//!   │   InputQueue ────►  │         │   InputQueue ────►  │
//!   │   MatchingEngine    │         │   MatchingEngine    │
//!   │   ────► OutputQueue │         │   ────► OutputQueue │
//!   └──────────┬──────────┘         └──────────┬──────────┘
//!              │                               │
//!              └───────────────┬───────────────┘
//!                              ▼
//!   ┌─────────────────────────────────────────────────────────────────┐
//!   │                    Output Sender Thread                         │
//!   │  - Drains ALL processor output queues                           │
//!   │  - Encodes messages (binary/CSV per client)                     │
//!   │  - Routes to per-client output queues                           │
//!   │  - Sends via blocking I/O (dedicated thread = OK)               │
//!   │  - Handles multicast publishing                                 │
//!   └─────────────────────────────────────────────────────────────────┘
//! ```
//!
//! Key Changes from v5:
//! 1. I/O thread no longer drains output queues or flushes TCP
//! 2. New OutputSender thread handles all output processing
//! 3. Blocking sends are acceptable since OutputSender is dedicated
//! 4. Cleaner separation of concerns
//! 5. Better backpressure handling via per-client queues
//!
//! Benefits:
//! - I/O thread can focus purely on input processing
//! - Output processing doesn't block input handling
//! - Blocking sends simplify the code (no EPOLLOUT complexity)
//! - Per-client queues isolate slow clients
//! - Matches proven C architecture
const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const TcpServer = @import("../transport/tcp_server.zig").TcpServer;
const TcpClient = @import("../transport/tcp_client.zig").TcpClient;
const udp_server = @import("../transport/udp_server.zig");
const UdpServer = udp_server.UdpServer;
const MulticastPublisher = @import("../transport/multicast.zig").MulticastPublisher;
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");
const OutputSender = @import("output_sender.zig").OutputSender;

// ============================================================================
// Configuration
// ============================================================================

pub const NUM_PROCESSORS: usize = 2;

/// Poll timeout - 0 for maximum input throughput
const DEFAULT_POLL_TIMEOUT_MS: i32 = 0;

/// UDP sizing
const MAX_UDP_PAYLOAD: usize = 1400;
const MAX_UDP_BATCH_SIZE: usize = MAX_UDP_PAYLOAD;
const MAX_CLIENT_BATCHES: usize = 64;

/// Encode buffer size
const ENCODE_BUF_SIZE: usize = 512;

comptime {
    std.debug.assert(NUM_PROCESSORS > 0);
    std.debug.assert(NUM_PROCESSORS <= 8);
    std.debug.assert(MAX_UDP_BATCH_SIZE <= 1472);
    std.debug.assert(MAX_CLIENT_BATCHES > 0);
    std.debug.assert(ENCODE_BUF_SIZE >= 256);
}

// ============================================================================
// Output Batching for UDP (unchanged from v5)
// ============================================================================

const ClientBatch = struct {
    client_id: config.ClientId,
    buf: [MAX_UDP_BATCH_SIZE]u8,
    len: usize,
    msg_count: usize,

    fn init() ClientBatch {
        return .{ .client_id = 0, .buf = undefined, .len = 0, .msg_count = 0 };
    }

    fn reset(self: *ClientBatch, client_id: config.ClientId) void {
        std.debug.assert(client_id != 0);
        self.client_id = client_id;
        self.len = 0;
        self.msg_count = 0;
    }

    fn canFit(self: *const ClientBatch, data_len: usize) bool {
        return self.len + data_len <= MAX_UDP_BATCH_SIZE;
    }

    fn add(self: *ClientBatch, data: []const u8) void {
        std.debug.assert(self.canFit(data.len));
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
        self.msg_count += 1;
    }

    fn getData(self: *const ClientBatch) []const u8 {
        return self.buf[0..self.len];
    }

    fn isEmpty(self: *const ClientBatch) bool {
        return self.len == 0;
    }
};

const BatchManager = struct {
    batches: [MAX_CLIENT_BATCHES]ClientBatch,
    active_count: usize,

    fn init() BatchManager {
        var self = BatchManager{ .batches = undefined, .active_count = 0 };
        for (&self.batches) |*b| b.* = ClientBatch.init();
        return self;
    }

    fn findBatch(self: *BatchManager, client_id: config.ClientId) ?*ClientBatch {
        for (self.batches[0..self.active_count]) |*batch| {
            if (batch.client_id == client_id) return batch;
        }
        return null;
    }

    fn getOrCreateBatch(self: *BatchManager, client_id: config.ClientId) ?*ClientBatch {
        if (self.findBatch(client_id)) |batch| return batch;
        if (self.active_count < MAX_CLIENT_BATCHES) {
            const batch = &self.batches[self.active_count];
            batch.reset(client_id);
            self.active_count += 1;
            return batch;
        }
        return null;
    }

    fn getOldestBatch(self: *BatchManager) ?*ClientBatch {
        if (self.active_count > 0) return &self.batches[0];
        return null;
    }

    fn removeBatch(self: *BatchManager, batch: *ClientBatch) void {
        const batch_ptr = @intFromPtr(batch);
        for (self.batches[0..self.active_count], 0..) |*b, i| {
            if (@intFromPtr(b) == batch_ptr) {
                if (i < self.active_count - 1) {
                    self.batches[i] = self.batches[self.active_count - 1];
                }
                self.active_count -= 1;
                return;
            }
        }
    }

    fn getActiveBatches(self: *BatchManager) []ClientBatch {
        return self.batches[0..self.active_count];
    }

    fn clear(self: *BatchManager) void {
        self.active_count = 0;
    }
};

// ============================================================================
// Statistics
// ============================================================================

pub const ServerStats = struct {
    messages_routed: [NUM_PROCESSORS]u64,
    outputs_dispatched: u64,
    messages_dropped: u64,
    disconnect_cancels: u64,
    tcp_send_failures: u64,
    tcp_queue_failures: u64,
    processor_stats: [NUM_PROCESSORS]proc.ProcessorStats,
    output_sender_stats: OutputSender.OutputSenderStats,

    pub fn totalProcessed(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.messages_processed;
        return total;
    }

    pub fn totalCriticalDrops(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.critical_drops;
        total += self.output_sender_stats.critical_drops;
        return total;
    }

    pub fn isHealthy(self: ServerStats) bool {
        return self.totalCriticalDrops() == 0 and
            self.tcp_send_failures == 0 and
            self.output_sender_stats.isHealthy();
    }

    pub fn totalOutputs(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.outputs_generated;
        return total;
    }
};

// ============================================================================
// Threaded Server v6 - With Dedicated Output Sender
// ============================================================================

pub const ThreadedServerV6 = struct {
    tcp: TcpServer,
    udp: UdpServer,
    multicast: MulticastPublisher,
    input_queues: [NUM_PROCESSORS]*proc.InputQueue,
    output_queues: [NUM_PROCESSORS]*proc.OutputQueue,
    processors: [NUM_PROCESSORS]?proc.Processor,
    output_sender: ?*OutputSender,
    encode_buf: [ENCODE_BUF_SIZE]u8,
    batch_mgr: BatchManager,
    cfg: config.Config,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),

    // Statistics (only for input side now)
    messages_routed: [NUM_PROCESSORS]std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),
    disconnect_cancels: std.atomic.Value(u64),

    // Legacy stats for compatibility (output sender tracks these now)
    outputs_dispatched: std.atomic.Value(u64),
    tcp_send_failures: std.atomic.Value(u64),
    tcp_queue_failures: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Create input/output queues
        for (0..NUM_PROCESSORS) |i| {
            self.input_queues[i] = try allocator.create(proc.InputQueue);
            self.input_queues[i].* = .{};
        }
        errdefer for (0..NUM_PROCESSORS) |i| allocator.destroy(self.input_queues[i]);

        for (0..NUM_PROCESSORS) |i| {
            self.output_queues[i] = try allocator.create(proc.OutputQueue);
            self.output_queues[i].* = .{};
        }
        errdefer for (0..NUM_PROCESSORS) |i| allocator.destroy(self.output_queues[i]);

        // Create output sender (drains processor output queues)
        // Note: The slice points to self.output_queues which lives as long as self
        self.output_sender = try OutputSender.init(allocator, &self.output_queues);
        errdefer if (self.output_sender) |os| os.deinit();

        self.tcp = TcpServer.init(allocator);
        self.udp = UdpServer.init();
        self.multicast = MulticastPublisher.init();
        self.processors = .{ null, null };
        self.encode_buf = undefined;
        self.batch_mgr = BatchManager.init();
        self.cfg = cfg;
        self.allocator = allocator;
        self.running = std.atomic.Value(bool).init(false);
        self.messages_routed = .{
            std.atomic.Value(u64).init(0),
            std.atomic.Value(u64).init(0),
        };
        self.messages_dropped = std.atomic.Value(u64).init(0);
        self.disconnect_cancels = std.atomic.Value(u64).init(0);
        self.outputs_dispatched = std.atomic.Value(u64).init(0);
        self.tcp_send_failures = std.atomic.Value(u64).init(0);
        self.tcp_queue_failures = std.atomic.Value(u64).init(0);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.tcp.deinit();
        self.udp.deinit();
        self.multicast.deinit();

        if (self.output_sender) |os| {
            os.deinit();
            self.output_sender = null;
        }

        for (0..NUM_PROCESSORS) |i| {
            self.allocator.destroy(self.input_queues[i]);
            self.allocator.destroy(self.output_queues[i]);
        }
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        std.debug.assert(!self.running.load(.acquire));

        std.log.info("Starting threaded server v6 (dedicated output sender)...", .{});
        std.log.info("Config: channel_capacity={d}", .{proc.CHANNEL_CAPACITY});

        // Start processors
        for (0..NUM_PROCESSORS) |i| {
            const id: proc.ProcessorId = @enumFromInt(i);
            self.processors[i] = try proc.Processor.init(
                self.allocator,
                id,
                self.input_queues[i],
                self.output_queues[i],
            );
            try self.processors[i].?.start();
        }

        // Configure and start output sender
        if (self.output_sender) |os| {
            // Set up send callback that uses direct POSIX send
            os.setSendCallback(OutputSender.makeDirectSendCallback(), null);

            // Configure multicast if enabled
            if (self.cfg.mcast_enabled) {
                os.setMulticastEnabled(true);
                os.setMulticastCallback(onMulticastPublish, self);
            }

            os.setDefaultProtocol(
                if (self.cfg.use_binary_protocol) .binary else .csv,
            );

            try os.start();
        }

        // Start TCP server
        if (self.cfg.tcp_enabled) {
            self.tcp.on_message = onTcpMessage;
            self.tcp.on_disconnect = onTcpDisconnect;
            self.tcp.on_connect = onTcpConnect;  // NEW: register connect callback
            self.tcp.callback_ctx = self;
            try self.tcp.start(self.cfg.tcp_addr, self.cfg.tcp_port);
        }

        // Start UDP server
        if (self.cfg.udp_enabled) {
            self.udp.on_message = onUdpMessage;
            self.udp.callback_ctx = self;
            try self.udp.start(self.cfg.udp_addr, self.cfg.udp_port);
        }

        // Start multicast publisher
        if (self.cfg.mcast_enabled) {
            try self.multicast.start(
                self.cfg.mcast_group,
                self.cfg.mcast_port,
                self.cfg.mcast_ttl,
            );
        }

        self.running.store(true, .release);
        std.log.info("Threaded server v6 started ({d} processors + output sender)", .{NUM_PROCESSORS});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;

        std.log.info("Stopping threaded server v6...", .{});
        self.running.store(false, .release);

        // Stop output sender first (it needs to drain remaining outputs)
        if (self.output_sender) |os| {
            os.stop();
        }

        // Stop transport
        self.tcp.stop();
        self.udp.stop();
        self.multicast.stop();

        // Stop processors
        for (&self.processors) |*p| {
            if (p.*) |*processor| {
                processor.deinit();
                p.* = null;
            }
        }

        std.log.info("Threaded server v6 stopped", .{});
    }

    pub fn run(self: *Self) !void {
        std.log.info("Threaded server v6 running...", .{});

        while (self.running.load(.acquire)) {
            try self.pollOnce(DEFAULT_POLL_TIMEOUT_MS);
        }

        std.log.info("Threaded server v6 event loop exited", .{});
    }

    /// v6 poll loop - I/O thread only handles input now!
    /// Output processing is handled by dedicated OutputSender thread.
    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        std.debug.assert(timeout_ms >= 0);

        // Service socket events (input only)
        if (self.cfg.tcp_enabled) {
            _ = try self.tcp.poll(timeout_ms);
        }

        if (self.cfg.udp_enabled) {
            _ = self.udp.poll() catch {};
        }

        // NOTE: No output draining here!
        // The OutputSender thread handles all output processing.
        // This keeps the I/O thread focused on input handling.
    }

    // ========================================================================
    // Input Routing (unchanged from v5)
    // ========================================================================

    fn routeMessage(self: *Self, message: *const msg.InputMsg, client_id: config.ClientId) void {
        std.debug.assert(self.running.load(.acquire));
        std.debug.assert(client_id != 0 or message.msg_type == .flush);

        const input = proc.ProcessorInput{
            .message = message.*,
            .client_id = client_id,
            .enqueue_time_ns = if (proc.TRACK_LATENCY) @truncate(std.time.nanoTimestamp()) else 0,
        };

        switch (message.msg_type) {
            .new_order => {
                const processor_id = proc.routeSymbol(message.data.new_order.symbol);
                self.sendToProcessor(processor_id, input);
            },
            .cancel => {
                if (!msg.symbolIsEmpty(&message.data.cancel.symbol)) {
                    const processor_id = proc.routeSymbol(message.data.cancel.symbol);
                    self.sendToProcessor(processor_id, input);
                } else {
                    self.sendToAllProcessors(input);
                }
            },
            .flush => self.sendToAllProcessors(input),
        }
    }

    fn sendToProcessor(self: *Self, processor_id: proc.ProcessorId, input: proc.ProcessorInput) void {
        const idx = @intFromEnum(processor_id);
        if (self.input_queues[idx].push(input)) {
            _ = self.messages_routed[idx].fetchAdd(1, .monotonic);
        } else {
            _ = self.messages_dropped.fetchAdd(1, .monotonic);
            std.log.warn("Input queue {d} full, dropping message", .{idx});
        }
    }

    fn sendToAllProcessors(self: *Self, input: proc.ProcessorInput) void {
        for (0..NUM_PROCESSORS) |i| {
            if (self.input_queues[i].push(input)) {
                _ = self.messages_routed[i].fetchAdd(1, .monotonic);
            } else {
                _ = self.messages_dropped.fetchAdd(1, .monotonic);
            }
        }
    }

    // ========================================================================
    // Client Management Integration
    // ========================================================================

    fn registerClientWithOutputSender(self: *Self, client_id: config.ClientId, fd: std.posix.fd_t) void {
        if (self.output_sender) |os| {
            const registered = os.registerClient(client_id, fd, null);
            if (registered) {
                std.log.debug("Registered client {} with OutputSender (fd={})", .{ client_id, fd });
            } else {
                std.log.warn("Failed to register client {} with OutputSender", .{client_id});
            }
        }
    }

    fn unregisterClientFromOutputSender(self: *Self, client_id: config.ClientId) void {
        if (self.output_sender) |os| {
            os.unregisterClient(client_id);
            std.log.debug("Unregistered client {} from OutputSender", .{client_id});
        }
    }

    // ========================================================================
    // Callbacks
    // ========================================================================

    /// NEW: Called when a TCP client connects
    fn onTcpConnect(client_id: config.ClientId, fd: std.posix.fd_t, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.registerClientWithOutputSender(client_id, fd);
    }

    fn onTcpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.routeMessage(message, client_id);
    }

    fn onTcpDisconnect(client_id: config.ClientId, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (!self.running.load(.acquire)) return;

        std.log.info("Client {d} disconnected, sending cancel-on-disconnect", .{client_id});

        // Unregister from output sender
        self.unregisterClientFromOutputSender(client_id);

        // Send cancel-on-disconnect
        const cancel_msg = msg.InputMsg.flush();
        const input = proc.ProcessorInput{
            .message = cancel_msg,
            .client_id = client_id,
            .enqueue_time_ns = if (proc.TRACK_LATENCY) @truncate(std.time.nanoTimestamp()) else 0,
        };
        for (0..NUM_PROCESSORS) |i| _ = self.input_queues[i].push(input);
        _ = self.disconnect_cancels.fetchAdd(1, .monotonic);
    }

    fn onUdpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.routeMessage(message, client_id);
    }

    fn onMulticastPublish(out_msg: *const msg.OutputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        _ = self.multicast.publish(out_msg);
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    pub fn getStats(self: *const Self) ServerStats {
        var stats = ServerStats{
            .messages_routed = undefined,
            .outputs_dispatched = self.outputs_dispatched.load(.monotonic),
            .messages_dropped = self.messages_dropped.load(.monotonic),
            .disconnect_cancels = self.disconnect_cancels.load(.monotonic),
            .tcp_send_failures = self.tcp_send_failures.load(.monotonic),
            .tcp_queue_failures = self.tcp_queue_failures.load(.monotonic),
            .processor_stats = undefined,
            .output_sender_stats = if (self.output_sender) |os|
                os.getStats()
            else
                OutputSender.OutputSenderStats.init(),
        };

        for (0..NUM_PROCESSORS) |i| {
            stats.messages_routed[i] = self.messages_routed[i].load(.monotonic);
            if (self.processors[i]) |*p|
                stats.processor_stats[i] = p.getStats()
            else
                stats.processor_stats[i] = std.mem.zeroes(proc.ProcessorStats);
        }

        return stats;
    }

    pub fn isHealthy(self: *const Self) bool {
        return self.getStats().isHealthy();
    }

    pub fn requestShutdown(self: *Self) void {
        self.running.store(false, .release);
    }
};

// ============================================================================
// Backward Compatibility Alias
// ============================================================================

/// Alias for backward compatibility - use ThreadedServerV6 for new code
pub const ThreadedServer = ThreadedServerV6;
