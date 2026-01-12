//! Threaded server with I/O thread and dual processor threads.
//!
//! OPTIMIZED VERSION v3 - Per-client output queues (matches C server pattern)
//!
//! Key architectural change:
//! - Output routing just enqueues to per-client lock-free queue (FAST)
//! - TCP sending happens separately on EPOLLOUT (batched)
//! - This decouples message routing from TCP I/O
//!
//! Flow:
//!   Processor → Output Queue → drainOutputs() → client.queueOutput() [no syscall]
//!                                                       ↓
//!                                              [per-client queue]
//!                                                       ↓
//!                              EPOLLOUT → client.drainToSocket() [batched send]
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

// ============================================================================
// Configuration
// ============================================================================
pub const NUM_PROCESSORS: usize = 2;

/// Drain ALL available outputs per cycle - we're just enqueueing, it's fast
const OUTPUT_DRAIN_LIMIT: u32 = 262144;
const OUTPUT_DRAIN_TOTAL_CAP: u32 = 262144;

/// Poll timeout - 0 for maximum throughput
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
    std.debug.assert(OUTPUT_DRAIN_LIMIT > 0);
    std.debug.assert(OUTPUT_DRAIN_TOTAL_CAP > 0);
    std.debug.assert(MAX_UDP_BATCH_SIZE <= 1472);
    std.debug.assert(MAX_CLIENT_BATCHES > 0);
    std.debug.assert(ENCODE_BUF_SIZE >= 256);
}

// ============================================================================
// Output Batching (for UDP)
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
        self.client_id = client_id;
        self.len = 0;
        self.msg_count = 0;
    }

    fn canFit(self: *const ClientBatch, data_len: usize) bool {
        return self.len + data_len <= MAX_UDP_BATCH_SIZE;
    }

    fn add(self: *ClientBatch, data: []const u8) void {
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

    fn getOrCreateBatch(self: *BatchManager, client_id: config.ClientId) ?*ClientBatch {
        for (self.batches[0..self.active_count]) |*batch| {
            if (batch.client_id == client_id) return batch;
        }
        if (self.active_count < MAX_CLIENT_BATCHES) {
            const batch = &self.batches[self.active_count];
            batch.reset(client_id);
            self.active_count += 1;
            return batch;
        }
        return null;
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
    tcp_queue_failures: u64,
    processor_stats: [NUM_PROCESSORS]proc.ProcessorStats,

    pub fn totalProcessed(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.messages_processed;
        return total;
    }

    pub fn totalCriticalDrops(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.critical_drops;
        return total;
    }

    pub fn isHealthy(self: ServerStats) bool {
        return self.totalCriticalDrops() == 0 and self.tcp_queue_failures == 0;
    }

    pub fn totalOutputs(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.outputs_generated;
        return total;
    }
};

// ============================================================================
// Threaded Server - v3 with per-client queues
// ============================================================================
pub const ThreadedServer = struct {
    tcp: TcpServer,
    udp: UdpServer,
    multicast: MulticastPublisher,
    input_queues: [NUM_PROCESSORS]*proc.InputQueue,
    output_queues: [NUM_PROCESSORS]*proc.OutputQueue,
    processors: [NUM_PROCESSORS]?proc.Processor,
    encode_buf: [ENCODE_BUF_SIZE]u8,
    batch_mgr: BatchManager,
    cfg: config.Config,
    allocator: std.mem.Allocator,

    running: std.atomic.Value(bool),
    messages_routed: [NUM_PROCESSORS]std.atomic.Value(u64),
    outputs_dispatched: std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),
    disconnect_cancels: std.atomic.Value(u64),
    batches_sent: std.atomic.Value(u64),
    tcp_queue_failures: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        for (0..NUM_PROCESSORS) |i| {
            self.input_queues[i] = try allocator.create(proc.InputQueue);
            self.input_queues[i].* = .{};
        }

        for (0..NUM_PROCESSORS) |i| {
            self.output_queues[i] = try allocator.create(proc.OutputQueue);
            self.output_queues[i].* = .{};
        }

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
        self.outputs_dispatched = std.atomic.Value(u64).init(0);
        self.messages_dropped = std.atomic.Value(u64).init(0);
        self.disconnect_cancels = std.atomic.Value(u64).init(0);
        self.batches_sent = std.atomic.Value(u64).init(0);
        self.tcp_queue_failures = std.atomic.Value(u64).init(0);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.tcp.deinit();
        self.udp.deinit();
        self.multicast.deinit();
        for (0..NUM_PROCESSORS) |i| {
            self.allocator.destroy(self.input_queues[i]);
            self.allocator.destroy(self.output_queues[i]);
        }
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        std.log.info("Starting threaded server (v3 - per-client queues)...", .{});
        std.log.info("Config: channel_capacity={d}, drain_limit={d}", .{
            proc.CHANNEL_CAPACITY,
            OUTPUT_DRAIN_LIMIT,
        });

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

        if (self.cfg.tcp_enabled) {
            self.tcp.on_message = onTcpMessage;
            self.tcp.on_disconnect = onTcpDisconnect;
            self.tcp.callback_ctx = self;
            try self.tcp.start(self.cfg.tcp_addr, self.cfg.tcp_port);
        }

        if (self.cfg.udp_enabled) {
            self.udp.on_message = onUdpMessage;
            self.udp.callback_ctx = self;
            try self.udp.start(self.cfg.udp_addr, self.cfg.udp_port);
        }

        if (self.cfg.mcast_enabled) {
            try self.multicast.start(self.cfg.mcast_group, self.cfg.mcast_port, self.cfg.mcast_ttl);
        }

        self.running.store(true, .release);
        std.log.info("Threaded server started ({d} processors)", .{NUM_PROCESSORS});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;
        std.log.info("Stopping threaded server...", .{});
        std.log.info("Stats: outputs_dispatched={d}, messages_dropped={d}, tcp_queue_failures={d}", .{
            self.outputs_dispatched.load(.monotonic),
            self.messages_dropped.load(.monotonic),
            self.tcp_queue_failures.load(.monotonic),
        });

        self.running.store(false, .release);
        
        // Final drain before stopping
        _ = self.drainOutputQueues();
        
        // Force flush all clients
        self.forceFlushAllClients();

        self.tcp.stop();
        self.udp.stop();
        self.multicast.stop();

        for (&self.processors) |*p| {
            if (p.*) |*processor| {
                processor.deinit();
                p.* = null;
            }
        }

        std.log.info("Threaded server stopped", .{});
    }

    pub fn run(self: *Self) !void {
        std.log.info("Threaded server running (v3)...", .{});
        while (self.running.load(.acquire)) {
            try self.pollOnce(DEFAULT_POLL_TIMEOUT_MS);
        }
        std.log.info("Threaded server event loop exited", .{});
    }

    /// v3 poll loop:
    /// 1) Poll sockets - handles reads AND EPOLLOUT (which drains per-client queues)
    /// 2) Drain processor output queues into per-client queues (FAST, no syscalls)
    /// 3) Enable EPOLLOUT for clients with queued output
    /// 4) Poll again to service EPOLLOUT
    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        // 1) Service socket events (EPOLLOUT will drain client queues)
        if (self.cfg.tcp_enabled) _ = try self.tcp.poll(0);
        if (self.cfg.udp_enabled) _ = self.udp.poll() catch {};

        // 2) Drain processor outputs into per-client queues (fast)
        _ = self.drainOutputQueues();

        // 3) Flush UDP batches
        self.flushAllBatches();

        // 4) Enable EPOLLOUT for clients with queued output
        self.enableWriteForClientsWithOutput();

        // 5) Poll again with timeout to service EPOLLOUT
        if (self.cfg.tcp_enabled) _ = try self.tcp.poll(timeout_ms);
        if (self.cfg.udp_enabled) _ = self.udp.poll() catch {};
    }
    
    /// Enable EPOLLOUT for all clients that have queued output
    fn enableWriteForClientsWithOutput(self: *Self) void {
        var iter = self.tcp.clients.getActive();
        while (iter.next()) |client| {
            if (client.hasPendingSend()) {
                self.tcp.updateClientPoller(client, true) catch {};
            }
        }
    }
    
    /// Force flush all clients (for shutdown)
    fn forceFlushAllClients(self: *Self) void {
        var iter = self.tcp.clients.getActive();
        while (iter.next()) |client| {
            // Try to drain everything
            var attempts: u32 = 0;
            while (client.hasPendingSend() and attempts < 100) : (attempts += 1) {
                _ = client.drainToSocket() catch break;
            }
        }
    }

    fn routeMessage(self: *Self, message: *const msg.InputMsg, client_id: config.ClientId) void {
        const input = proc.ProcessorInput{
            .message = message.*,
            .client_id = client_id,
            .enqueue_time_ns = 0,
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

    /// Drain processor outputs into per-client queues.
    /// This is FAST because queueOutput() just pushes to a lock-free queue.
    fn drainOutputQueues(self: *Self) u32 {
        var drained_total: u32 = 0;

        for (self.output_queues) |queue| {
            var drained: u32 = 0;
            while (drained < OUTPUT_DRAIN_LIMIT) : (drained += 1) {
                const output = queue.pop() orelse break;
                self.processOutput(&output.message);
                _ = self.outputs_dispatched.fetchAdd(1, .monotonic);
                drained_total += 1;
            }
        }

        return drained_total;
    }

    fn processOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        const use_binary = if (config.isUdpClient(out_msg.client_id))
            self.udp.getClientProtocol(out_msg.client_id) == .binary
        else
            self.cfg.use_binary_protocol;

        const len = if (use_binary)
            binary_codec.encodeOutput(out_msg, &self.encode_buf) catch return
        else
            csv_codec.encodeOutput(out_msg, &self.encode_buf) catch return;

        const data = self.encode_buf[0..len];

        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => self.sendToClient(out_msg.client_id, data, use_binary),
            .trade => {
                self.sendToClient(out_msg.client_id, data, use_binary);
                if (self.cfg.mcast_enabled) _ = self.multicast.publish(out_msg);
            },
            .top_of_book => {
                if (out_msg.client_id != 0) self.sendToClient(out_msg.client_id, data, use_binary);
                if (self.cfg.mcast_enabled) _ = self.multicast.publish(out_msg);
            },
        }
    }

    fn sendToClient(self: *Self, client_id: config.ClientId, data: []const u8, is_binary: bool) void {
        if (client_id == 0) return;
        
        if (!config.isUdpClient(client_id)) {
            // TCP: Queue to per-client output queue (FAST, no syscall)
            if (self.tcp.clients.findById(client_id)) |client| {
                if (!client.queueOutput(data)) {
                    _ = self.tcp_queue_failures.fetchAdd(1, .monotonic);
                }
            }
            return;
        }

        // UDP handling
        if (is_binary) {
            _ = self.udp.send(client_id, data);
            _ = self.batches_sent.fetchAdd(1, .monotonic);
            return;
        }
        self.batchCsvMessage(client_id, data);
    }

    fn batchCsvMessage(self: *Self, client_id: config.ClientId, data: []const u8) void {
        if (self.batch_mgr.getOrCreateBatch(client_id)) |batch| {
            if (batch.canFit(data.len)) {
                batch.add(data);
                return;
            }
            self.flushBatch(batch);
            batch.reset(client_id);
            batch.add(data);
        }
    }

    fn flushBatch(self: *Self, batch: *const ClientBatch) void {
        if (batch.isEmpty()) return;
        _ = self.udp.send(batch.client_id, batch.getData());
        _ = self.batches_sent.fetchAdd(1, .monotonic);
    }

    fn flushAllBatches(self: *Self) void {
        for (self.batch_mgr.getActiveBatches()) |*batch| self.flushBatch(batch);
        self.batch_mgr.clear();
    }

    fn handleClientDisconnect(self: *Self, client_id: config.ClientId) void {
        std.log.info("Client {d} disconnected, sending cancel-on-disconnect", .{client_id});
        const cancel_msg = msg.InputMsg.flush();
        const input = proc.ProcessorInput{
            .message = cancel_msg,
            .client_id = client_id,
            .enqueue_time_ns = 0,
        };
        for (0..NUM_PROCESSORS) |i| _ = self.input_queues[i].push(input);
        _ = self.disconnect_cancels.fetchAdd(1, .monotonic);
    }

    fn onTcpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.routeMessage(message, client_id);
    }

    fn onTcpDisconnect(client_id: config.ClientId, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        if (!self.running.load(.acquire)) return;
        self.handleClientDisconnect(client_id);
    }

    fn onUdpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.routeMessage(message, client_id);
    }

    pub fn getStats(self: *const Self) ServerStats {
        var stats = ServerStats{
            .messages_routed = undefined,
            .outputs_dispatched = self.outputs_dispatched.load(.monotonic),
            .messages_dropped = self.messages_dropped.load(.monotonic),
            .disconnect_cancels = self.disconnect_cancels.load(.monotonic),
            .tcp_queue_failures = self.tcp_queue_failures.load(.monotonic),
            .processor_stats = undefined,
        };
        for (0..NUM_PROCESSORS) |i| {
            stats.messages_routed[i] = self.messages_routed[i].load(.monotonic);
            if (self.processors[i]) |*p| stats.processor_stats[i] = p.getStats()
            else stats.processor_stats[i] = std.mem.zeroes(proc.ProcessorStats);
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
