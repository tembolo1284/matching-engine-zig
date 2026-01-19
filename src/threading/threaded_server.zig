//! Threaded server with I/O thread, dual processor threads, and output router.
//!
//! VERSION v8 - C Server Architecture Match
//!
//! Thread Architecture:
//! ```
//!   ┌─────────────────────────────────────────────────────────────────┐
//!   │                        I/O Thread                               │
//!   │  - TCP/UDP accept & receive                                     │
//!   │  - Parse input messages                                         │
//!   │  - Route to processor input queues                              │
//!   │  - Processes output queues BEFORE epoll_wait (C server pattern) │
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
//!   │                    Output Router Thread                         │
//!   │  - Drains ALL processor output queues                           │
//!   │  - Routes to per-client output queues (lock-free SPSC)          │
//!   │  - Handles multicast publishing                                 │
//!   │  - Very fast: queue-to-queue only, no socket I/O                │
//!   └─────────────────────────────────────────────────────────────────┘
//!
//!   Per-client output queues are drained by TcpServer BEFORE epoll_wait.
//! ```
//!
//! Key Changes from v7:
//! 1. TcpServer.poll() now processes output queues BEFORE waiting for events
//! 2. This matches C server's tcp_listener.c exactly
//! 3. No more OUTPUT_DRAIN_INTERVAL - draining happens every poll cycle
//! 4. Output sending is much more responsive
//!
//! Benefits:
//! - Maximum output throughput - no waiting for EPOLLOUT
//! - Matches proven C architecture that achieves 3K+ orders/sec
//! - Simpler code - no periodic drain logic in this file
const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const TcpServer = @import("../transport/tcp_server.zig").TcpServer;
const TcpClient = @import("../transport/tcp_client.zig").TcpClient;
const OutputQueue = @import("../transport/tcp_client.zig").OutputQueue;
const udp_server = @import("../transport/udp_server.zig");
const UdpServer = udp_server.UdpServer;
const MulticastPublisher = @import("../transport/multicast.zig").MulticastPublisher;
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");
const OutputRouter = @import("output_router.zig").OutputRouter;
const RouterStats = @import("output_router.zig").RouterStats;

// ============================================================================
// Configuration
// ============================================================================

pub const NUM_PROCESSORS: usize = 2;

/// Poll timeout - 0 for maximum throughput, small value for responsiveness
/// With C-style output processing, 0 is fine - outputs processed before wait
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
// Output Batching for UDP (unchanged)
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
    router_stats: RouterStats,

    pub fn totalProcessed(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.messages_processed;
        return total;
    }

    pub fn totalCriticalDrops(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.critical_drops;
        total += self.router_stats.critical_drops;
        return total;
    }

    pub fn isHealthy(self: ServerStats) bool {
        return self.totalCriticalDrops() == 0 and
            self.tcp_send_failures == 0;
    }

    pub fn totalOutputs(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.outputs_generated;
        return total;
    }
};

// ============================================================================
// Threaded Server v8 - C Server Architecture Match
// ============================================================================

pub const ThreadedServerV8 = struct {
    tcp: TcpServer,
    udp: UdpServer,
    multicast: MulticastPublisher,
    input_queues: [NUM_PROCESSORS]*proc.InputQueue,
    output_queues: [NUM_PROCESSORS]*proc.OutputQueue,
    processors: [NUM_PROCESSORS]?proc.Processor,
    output_router: ?*OutputRouter,
    encode_buf: [ENCODE_BUF_SIZE]u8,
    batch_mgr: BatchManager,
    cfg: config.Config,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    poll_count: u64,

    // Statistics
    messages_routed: [NUM_PROCESSORS]std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),
    disconnect_cancels: std.atomic.Value(u64),
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

        // Create output router (drains processor output queues to client queues)
        self.output_router = try OutputRouter.init(allocator, &self.output_queues);
        errdefer if (self.output_router) |router| router.deinit();

        self.tcp = TcpServer.init(allocator);
        self.udp = UdpServer.init();
        self.multicast = MulticastPublisher.init();
        self.processors = .{ null, null };
        self.encode_buf = undefined;
        self.batch_mgr = BatchManager.init();
        self.cfg = cfg;
        self.allocator = allocator;
        self.running = std.atomic.Value(bool).init(false);
        self.poll_count = 0;
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
        // Always try to stop, regardless of running state
        self.stopForce();
        
        self.tcp.deinit();
        self.udp.deinit();
        self.multicast.deinit();
        
        if (self.output_router) |router| {
            router.deinit();
            self.output_router = null;
        }
        
        for (0..NUM_PROCESSORS) |i| {
            self.allocator.destroy(self.input_queues[i]);
            self.allocator.destroy(self.output_queues[i]);
        }
        self.allocator.destroy(self);
    }
    
    /// Force stop all components - called by deinit even if start() failed
    fn stopForce(self: *Self) void {
        std.log.debug("stopForce: stopping all components...", .{});
        
        // Signal stop
        self.running.store(false, .release);
        
        // Stop output router first
        if (self.output_router) |router| {
            router.stop();
        }
        
        // Stop transport
        self.tcp.stop();
        self.udp.stop();
        self.multicast.stop();
        
        // Stop ALL processors (even if start() didn't complete)
        for (&self.processors) |*p| {
            if (p.*) |*processor| {
                processor.deinit();
                p.* = null;
            }
        }
        
        std.log.debug("stopForce: all components stopped", .{});
    }

    pub fn start(self: *Self) !void {
        std.debug.assert(!self.running.load(.acquire));
        std.log.info("Starting threaded server v8 (C-style output processing)...", .{});
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
            self.processors[i].?.start() catch |err| {
                std.log.err("Failed to start processor {d}: {any}", .{ i, err });
                // Clean up already-started processors
                for (0..i) |j| {
                    if (self.processors[j]) |*p| {
                        p.deinit();
                        self.processors[j] = null;
                    }
                }
                return err;
            };
        }
        
        // errdefer to stop processors if anything below fails
        errdefer {
            std.log.debug("start() failed, cleaning up processors...", .{});
            for (&self.processors) |*p| {
                if (p.*) |*processor| {
                    processor.deinit();
                    p.* = null;
                }
            }
        }

        // Configure and start output router
        if (self.output_router) |router| {
            // Configure multicast if enabled
            if (self.cfg.mcast_enabled) {
                router.setMulticastEnabled(true);
                router.setMulticastCallback(onMulticastPublish, self);
            }
            try router.start();
        }
        
        // errdefer to stop router if TCP/UDP fails
        errdefer {
            if (self.output_router) |router| {
                router.stop();
            }
        }

        // Start TCP server
        if (self.cfg.tcp_enabled) {
            self.tcp.on_message = onTcpMessage;
            self.tcp.on_disconnect = onTcpDisconnect;
            self.tcp.on_connect = onTcpConnect;
            self.tcp.callback_ctx = self;
            self.tcp.start(self.cfg.tcp_addr, self.cfg.tcp_port) catch |err| {
                std.log.err("Failed to start TCP server on {s}:{d}: {any}", .{ 
                    self.cfg.tcp_addr, self.cfg.tcp_port, err 
                });
                return err;
            };
        } else {
            std.log.info("TCP server disabled by config", .{});
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
        std.log.info("Threaded server v8 started ({d} processors + output router)", .{NUM_PROCESSORS});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;
        std.log.info("Stopping threaded server v8...", .{});
        self.running.store(false, .release);

        // Stop output router first (it needs to drain remaining outputs)
        if (self.output_router) |router| {
            router.stop();
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

        std.log.info("Threaded server v8 stopped", .{});
    }

    pub fn run(self: *Self) !void {
        std.log.info("Threaded server v8 running...", .{});
        while (self.running.load(.acquire)) {
            try self.pollOnce(DEFAULT_POLL_TIMEOUT_MS);
        }
        std.log.info("Threaded server v8 event loop exited", .{});
    }

    /// v8 poll loop - simplified because TcpServer.poll() now handles output
    /// processing internally (before epoll_wait, like C server)
    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        std.debug.assert(timeout_ms >= 0);

        // TCP poll now processes output queues BEFORE waiting for events
        // This matches the C server's tcp_listener.c architecture exactly
        if (self.cfg.tcp_enabled) {
            _ = try self.tcp.poll(timeout_ms);
        }

        if (self.cfg.udp_enabled) {
            _ = self.udp.poll() catch {};
        }

        self.poll_count += 1;
    }

    // ========================================================================
    // Input Routing
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
    // Client Management with Output Router
    // ========================================================================

    fn registerClientWithRouter(self: *Self, client_id: config.ClientId) ?*OutputQueue {
        if (self.output_router) |router| {
            if (router.registerClient(client_id)) |queue| {
                return queue;
            }
        }
        return null;
    }

    fn unregisterClientFromRouter(self: *Self, client_id: config.ClientId) void {
        if (self.output_router) |router| {
            router.unregisterClient(client_id);
        }
    }

    // ========================================================================
    // Callbacks
    // ========================================================================

    /// Called when a TCP client connects
    /// Returns the client's output queue pointer (for TcpClient to drain)
    fn onTcpConnect(client_id: config.ClientId, fd: std.posix.fd_t, ctx: ?*anyopaque) ?*OutputQueue {
        _ = fd;
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        return self.registerClientWithRouter(client_id);
    }

    fn onTcpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.routeMessage(message, client_id);
    }

    fn onTcpDisconnect(client_id: config.ClientId, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (!self.running.load(.acquire)) return;

        std.log.info("Client {d} disconnected, sending cancel-on-disconnect", .{client_id});

        // Unregister from output router
        self.unregisterClientFromRouter(client_id);

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
            .router_stats = if (self.output_router) |router|
                router.getStats()
            else
                RouterStats.init(),
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
// Backward Compatibility Aliases
// ============================================================================

/// Current recommended version
pub const ThreadedServer = ThreadedServerV8;

/// Legacy aliases
pub const ThreadedServerV7 = ThreadedServerV8;
pub const ThreadedServerV6 = ThreadedServerV8;
