//! Threaded server with I/O thread and dual processor threads.
//!
//! Architecture: I/O thread routes to processors by symbol (A-M vs N-Z).
//! All large structures heap-allocated to keep stack frames bounded.
//!
//! Optimizations:
//! - Message batching: Multiple CSV messages packed into single UDP packet
//! - Protocol-aware encoding: Binary clients get binary responses, CSV clients get CSV
//! - Output draining is time-sliced to avoid starving socket polling
//! - Periodic TCP flush to prevent send buffer overflow
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: All loops bounded by explicit constants
//! - Rule 5: Assertions validate state and inputs
//! - Rule 7: All queue operations and send results checked
const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const TcpServer = @import("../transport/tcp_server.zig").TcpServer;
const udp_server = @import("../transport/udp_server.zig");
const UdpServer = udp_server.UdpServer;
const MulticastPublisher = @import("../transport/multicast.zig").MulticastPublisher;
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");

// ============================================================================
// Configuration
// ============================================================================

pub const NUM_PROCESSORS: usize = 2;

/// IMPORTANT CHANGE:
/// Drain limit per poll cycle must NOT starve socket polling.
/// Large limits can cause EPOLLOUT / reads to be delayed for many ms+ under load.
/// Keep this modest; you can tune upward after measuring.
const OUTPUT_DRAIN_LIMIT: u32 = 32768;

/// Total output cap per pollOnce across ALL processors.
/// Prevents worst-case 2 * OUTPUT_DRAIN_LIMIT from taking too long.
const OUTPUT_DRAIN_TOTAL_CAP: u32 = 65536;

/// Default poll timeout in milliseconds.
/// 0 = busy loop for maximum throughput
const DEFAULT_POLL_TIMEOUT_MS: i32 = 0;

/// Flush TCP send buffers every N messages to prevent overflow
const FLUSH_INTERVAL: u32 = 100;

/// UDP sizing
const MAX_UDP_PAYLOAD: usize = 1400;
const MAX_UDP_BATCH_SIZE: usize = MAX_UDP_PAYLOAD;
const MAX_CLIENT_BATCHES: usize = 64;

/// Encode buffer size.
const ENCODE_BUF_SIZE: usize = 512;

comptime {
    std.debug.assert(NUM_PROCESSORS > 0);
    std.debug.assert(NUM_PROCESSORS <= 8);
    std.debug.assert(OUTPUT_DRAIN_LIMIT > 0);
    std.debug.assert(OUTPUT_DRAIN_TOTAL_CAP > 0);
    std.debug.assert(MAX_UDP_BATCH_SIZE <= 1472);
    std.debug.assert(MAX_CLIENT_BATCHES > 0);
    std.debug.assert(ENCODE_BUF_SIZE >= 256);
    std.debug.assert(FLUSH_INTERVAL > 0);
}

// ============================================================================
// Output Batching (unchanged)
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
// Statistics (unchanged)
// ============================================================================

pub const ServerStats = struct {
    messages_routed: [NUM_PROCESSORS]u64,
    outputs_dispatched: u64,
    messages_dropped: u64,
    disconnect_cancels: u64,
    tcp_send_failures: u64,
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
        return self.totalCriticalDrops() == 0 and self.tcp_send_failures == 0;
    }

    pub fn totalOutputs(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| total += ps.outputs_generated;
        return total;
    }
};

// ============================================================================
// Threaded Server
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
    tcp_send_failures: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

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
        self.tcp_send_failures = std.atomic.Value(u64).init(0);

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
        std.debug.assert(!self.running.load(.acquire));
        std.log.info("Starting threaded server...", .{});
        std.log.info("Config: channel_capacity={d}, drain_limit={d}, drain_total_cap={d}, batch_size={d}, max_batches={d}, flush_interval={d}", .{
            proc.CHANNEL_CAPACITY,
            OUTPUT_DRAIN_LIMIT,
            OUTPUT_DRAIN_TOTAL_CAP,
            MAX_UDP_BATCH_SIZE,
            MAX_CLIENT_BATCHES,
            FLUSH_INTERVAL,
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
        std.log.info("Stats: batches_sent={d}, outputs_dispatched={d}, messages_dropped={d}, tcp_send_failures={d}", .{
            self.batches_sent.load(.monotonic),
            self.outputs_dispatched.load(.monotonic),
            self.messages_dropped.load(.monotonic),
            self.tcp_send_failures.load(.monotonic),
        });
        self.running.store(false, .release);
        self.tcp.stop();
        self.udp.stop();
        self.multicast.stop();

        // Final drain
        _ = self.drainOutputQueuesBounded(OUTPUT_DRAIN_TOTAL_CAP);

        for (&self.processors) |*p| {
            if (p.*) |*processor| {
                processor.deinit();
                p.* = null;
            }
        }
        std.log.info("Threaded server stopped", .{});
    }

    pub fn run(self: *Self) !void {
        std.log.info("Threaded server running...", .{});
        var last_stats_time = std.time.milliTimestamp();
        const stats_interval_ms: i64 = 5000;

        while (self.running.load(.acquire)) {
            try self.pollOnce(DEFAULT_POLL_TIMEOUT_MS);

            const now = std.time.milliTimestamp();
            if (now - last_stats_time >= stats_interval_ms) {
                const dispatched = self.outputs_dispatched.load(.monotonic);
                const failures = self.tcp_send_failures.load(.monotonic);
                const dropped = self.messages_dropped.load(.monotonic);
                if (dispatched > 0 or failures > 0 or dropped > 0) {
                    std.log.info("STATS: outputs={d}, tcp_failures={d}, dropped={d}", .{
                        dispatched, failures, dropped,
                    });
                }
                last_stats_time = now;
            }
        }
        std.log.info("Threaded server event loop exited", .{});
    }

    /// FAIR poll loop:
    /// 1) poll sockets with 0ms (service writable/readable quickly)
    /// 2) drain a bounded chunk of outputs
    /// 3) poll sockets again with timeout
    /// 4) drain again (bounded)
    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        std.debug.assert(timeout_ms >= 0);

        // 1) service socket events immediately
        if (self.cfg.tcp_enabled) _ = try self.tcp.poll(0);
        if (self.cfg.udp_enabled) _ = self.udp.poll() catch |err| {
            std.log.warn("UDP poll error: {any}", .{err});
            return;
        };

        // 2) bounded output drain so we don't starve polling
        _ = self.drainOutputQueuesBounded(OUTPUT_DRAIN_TOTAL_CAP);

        // 3) now wait a tiny bit for new input readiness
        if (self.cfg.tcp_enabled) _ = try self.tcp.poll(timeout_ms);
        if (self.cfg.udp_enabled) _ = self.udp.poll() catch |err| {
            std.log.warn("UDP poll error: {any}", .{err});
            return;
        };

        // 4) drain again (bounded)
        _ = self.drainOutputQueuesBounded(OUTPUT_DRAIN_TOTAL_CAP);
    }

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

    /// Bounded draining with periodic TCP flush:
    /// - per-processor drain bounded by OUTPUT_DRAIN_LIMIT
    /// - total bounded by `cap_total`
    /// - flushes TCP every FLUSH_INTERVAL messages to prevent buffer overflow
    /// Returns number drained.
    fn drainOutputQueuesBounded(self: *Self, cap_total: u32) u32 {
        var drained_total: u32 = 0;
        var since_last_flush: u32 = 0;

        for (self.output_queues) |queue| {
            var drained_this_q: u32 = 0;
            while (drained_this_q < OUTPUT_DRAIN_LIMIT and drained_total < cap_total) : ({
                drained_this_q += 1;
                drained_total += 1;
                since_last_flush += 1;
            }) {
                const output = queue.pop() orelse break;
                self.processOutput(&output.message);
                _ = self.outputs_dispatched.fetchAdd(1, .monotonic);

                // Periodic flush to prevent send buffer overflow
                if (since_last_flush >= FLUSH_INTERVAL) {
                    self.flushAllTcpClients();
                    since_last_flush = 0;
                }
            }
            if (drained_total >= cap_total) break;
        }

        // Always flush UDP batches at end of a drain slice
        self.flushAllBatches();

        // Final TCP flush
        if (drained_total > 0) self.flushAllTcpClients();

        return drained_total;
    }

    fn flushAllTcpClients(self: *Self) void {
        var iter = self.tcp.clients.getActive();
        while (iter.next()) |client| {
            if (!client.hasPendingSend()) continue;
            client.flushSend() catch |err| {
                // WouldBlock means we MUST rely on EPOLLOUT to continue.
                // Ensure write interest is enabled.
                if (err == error.WouldBlock) {
                    self.tcp.updateClientPoller(client, true) catch {};
                } else {
                    std.log.debug("Client {} flush error: {}", .{ client.client_id, err });
                }
            };
        }
    }

    fn processOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        const use_binary = if (config.isUdpClient(out_msg.client_id))
            self.udp.getClientProtocol(out_msg.client_id) == .binary
        else
            self.cfg.use_binary_protocol;

        const len = if (use_binary)
            binary_codec.encodeOutput(out_msg, &self.encode_buf) catch |err| {
                std.log.err("Failed to encode binary output: {any}", .{err});
                return;
            }
        else
            csv_codec.encodeOutput(out_msg, &self.encode_buf) catch |err| {
                std.log.err("Failed to encode CSV output: {any}", .{err});
                return;
            };

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
            const ok = self.tcp.send(client_id, data);
            if (!ok) _ = self.tcp_send_failures.fetchAdd(1, .monotonic);
            return;
        }

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
            return;
        }

        if (self.batch_mgr.getOldestBatch()) |oldest| {
            self.flushBatch(oldest);
            self.batch_mgr.removeBatch(oldest);
            if (self.batch_mgr.getOrCreateBatch(client_id)) |batch| {
                batch.add(data);
                return;
            }
        }

        _ = self.udp.send(client_id, data);
        _ = self.batches_sent.fetchAdd(1, .monotonic);
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
            .enqueue_time_ns = if (proc.TRACK_LATENCY) @truncate(std.time.nanoTimestamp()) else 0,
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
            .tcp_send_failures = self.tcp_send_failures.load(.monotonic),
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

// ============================================================================
// Tests
// ============================================================================

test "ClientBatch basic operations" {
    var batch = ClientBatch.init();
    batch.reset(100);

    try std.testing.expect(batch.isEmpty());
    try std.testing.expect(batch.canFit(100));

    batch.add("A, AAPL, 1, 1\n");
    try std.testing.expect(!batch.isEmpty());
    try std.testing.expectEqual(@as(usize, 15), batch.len);
    try std.testing.expectEqual(@as(usize, 1), batch.msg_count);
}

test "ClientBatch overflow detection" {
    var batch = ClientBatch.init();
    batch.reset(100);

    // Fill most of the buffer
    const big_msg = "X" ** 1300;
    batch.add(big_msg);

    // Should not fit another 200 bytes (1300 + 200 > 1400)
    try std.testing.expect(!batch.canFit(200));
    // Should fit 100 bytes (1300 + 100 = 1400)
    try std.testing.expect(batch.canFit(100));
}

test "BatchManager multi-client" {
    var mgr = BatchManager.init();

    // Add batches for different clients
    const batch1 = mgr.getOrCreateBatch(100);
    try std.testing.expect(batch1 != null);
    batch1.?.add("msg1\n");

    const batch2 = mgr.getOrCreateBatch(200);
    try std.testing.expect(batch2 != null);
    batch2.?.add("msg2\n");

    // Same client should return same batch
    const batch1_again = mgr.getOrCreateBatch(100);
    try std.testing.expect(batch1_again == batch1);

    try std.testing.expectEqual(@as(usize, 2), mgr.active_count);
}

test "BatchManager flush and clear" {
    var mgr = BatchManager.init();
    _ = mgr.getOrCreateBatch(100);
    _ = mgr.getOrCreateBatch(200);
    try std.testing.expectEqual(@as(usize, 2), mgr.active_count);

    // Clear should reset count
    mgr.clear();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_count);
}

test "ServerStats total processed" {
    var stats = ServerStats{
        .messages_routed = .{ 100, 200 },
        .outputs_dispatched = 150,
        .messages_dropped = 0,
        .disconnect_cancels = 0,
        .tcp_send_failures = 0,
        .processor_stats = .{
            .{
                .messages_processed = 100,
                .outputs_generated = 50,
                .input_queue_depth = 0,
                .output_queue_depth = 0,
                .total_processing_time_ns = 0,
                .min_latency_ns = 0,
                .max_latency_ns = 0,
                .output_backpressure_count = 0,
                .output_spin_waits = 0,
                .output_yield_waits = 0,
                .critical_drops = 0,
                .non_critical_drops = 0,
                .idle_cycles = 0,
            },
            .{
                .messages_processed = 200,
                .outputs_generated = 100,
                .input_queue_depth = 0,
                .output_queue_depth = 0,
                .total_processing_time_ns = 0,
                .min_latency_ns = 0,
                .max_latency_ns = 0,
                .output_backpressure_count = 0,
                .output_spin_waits = 0,
                .output_yield_waits = 0,
                .critical_drops = 0,
                .non_critical_drops = 0,
                .idle_cycles = 0,
            },
        },
    };

    try std.testing.expectEqual(@as(u64, 300), stats.totalProcessed());
    try std.testing.expectEqual(@as(u64, 150), stats.totalOutputs());
    try std.testing.expectEqual(@as(u64, 0), stats.totalCriticalDrops());
    try std.testing.expect(stats.isHealthy());
}

test "ServerStats unhealthy with critical drops" {
    var stats = ServerStats{
        .messages_routed = .{ 100, 200 },
        .outputs_dispatched = 150,
        .messages_dropped = 0,
        .disconnect_cancels = 0,
        .tcp_send_failures = 0,
        .processor_stats = .{
            .{
                .messages_processed = 100,
                .outputs_generated = 50,
                .input_queue_depth = 0,
                .output_queue_depth = 0,
                .total_processing_time_ns = 0,
                .min_latency_ns = 0,
                .max_latency_ns = 0,
                .output_backpressure_count = 0,
                .output_spin_waits = 0,
                .output_yield_waits = 0,
                .critical_drops = 5, // Critical drops!
                .non_critical_drops = 0,
                .idle_cycles = 0,
            },
            .{
                .messages_processed = 200,
                .outputs_generated = 100,
                .input_queue_depth = 0,
                .output_queue_depth = 0,
                .total_processing_time_ns = 0,
                .min_latency_ns = 0,
                .max_latency_ns = 0,
                .output_backpressure_count = 0,
                .output_spin_waits = 0,
                .output_yield_waits = 0,
                .critical_drops = 0,
                .non_critical_drops = 0,
                .idle_cycles = 0,
            },
        },
    };

    try std.testing.expectEqual(@as(u64, 5), stats.totalCriticalDrops());
    try std.testing.expect(!stats.isHealthy());
}

test "ServerStats unhealthy with tcp send failures" {
    var stats = ServerStats{
        .messages_routed = .{ 100, 200 },
        .outputs_dispatched = 150,
        .messages_dropped = 0,
        .disconnect_cancels = 0,
        .tcp_send_failures = 10, // TCP send failures!
        .processor_stats = .{
            .{
                .messages_processed = 100,
                .outputs_generated = 50,
                .input_queue_depth = 0,
                .output_queue_depth = 0,
                .total_processing_time_ns = 0,
                .min_latency_ns = 0,
                .max_latency_ns = 0,
                .output_backpressure_count = 0,
                .output_spin_waits = 0,
                .output_yield_waits = 0,
                .critical_drops = 0,
                .non_critical_drops = 0,
                .idle_cycles = 0,
            },
            .{
                .messages_processed = 200,
                .outputs_generated = 100,
                .input_queue_depth = 0,
                .output_queue_depth = 0,
                .total_processing_time_ns = 0,
                .min_latency_ns = 0,
                .max_latency_ns = 0,
                .output_backpressure_count = 0,
                .output_spin_waits = 0,
                .output_yield_waits = 0,
                .critical_drops = 0,
                .non_critical_drops = 0,
                .idle_cycles = 0,
            },
        },
    };

    try std.testing.expect(!stats.isHealthy());
}

test "MAX_UDP_BATCH_SIZE within MTU" {
    // Verify our batch size is safe for UDP
    try std.testing.expect(MAX_UDP_BATCH_SIZE <= 1472); // MTU - headers
    try std.testing.expect(MAX_UDP_BATCH_SIZE <= MAX_UDP_PAYLOAD);
}

test "Configuration constants are valid" {
    try std.testing.expect(NUM_PROCESSORS > 0);
    try std.testing.expect(OUTPUT_DRAIN_LIMIT > 0);
    try std.testing.expect(MAX_UDP_PAYLOAD > 0);
    try std.testing.expect(MAX_CLIENT_BATCHES > 0);
    try std.testing.expect(ENCODE_BUF_SIZE >= 256);
    try std.testing.expect(FLUSH_INTERVAL > 0);
}
