//! Threaded server with I/O thread and dual processor threads.
//!
//! Architecture: I/O thread routes to processors by symbol (A-M vs N-Z).
//! All large structures heap-allocated to keep stack frames bounded.
//!
//! Optimizations:
//! - Message batching: Multiple CSV messages packed into single UDP packet
//! - Protocol-aware encoding: Binary clients get binary responses, CSV clients get CSV
//! - Aggressive output draining: Process up to 16384 outputs per poll cycle

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const TcpServer = @import("../transport/tcp_server.zig").TcpServer;
const udp_server = @import("../transport/udp_server.zig");
const UdpServer = udp_server.UdpServer;
const UdpProtocol = udp_server.Protocol;
const MulticastPublisher = @import("../transport/multicast.zig").MulticastPublisher;
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");

// ============================================================================
// Configuration
// ============================================================================

pub const NUM_PROCESSORS: usize = 2;

/// Output drain limit per poll cycle
/// At 200K orders/sec generating 2 outputs each = 400K outputs/sec
/// At 1000 polls/sec, need to drain 400 outputs per poll minimum
const OUTPUT_DRAIN_LIMIT: u32 = 131072;

const DEFAULT_POLL_TIMEOUT_MS: i32 = 2;

/// Maximum UDP payload size (stay under typical MTU of 1500)
const MAX_UDP_BATCH_SIZE: usize = 10000;

/// Maximum number of client batches to track simultaneously
const MAX_CLIENT_BATCHES: usize = 16;

// ============================================================================
// Output Batching
// ============================================================================

/// Batch buffer for accumulating messages to same client
const ClientBatch = struct {
    client_id: config.ClientId,
    buf: [MAX_UDP_BATCH_SIZE]u8,
    len: usize,
    msg_count: usize,

    fn init() ClientBatch {
        return .{
            .client_id = 0,
            .buf = undefined,
            .len = 0,
            .msg_count = 0,
        };
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

/// Multi-client batch manager
const BatchManager = struct {
    batches: [MAX_CLIENT_BATCHES]ClientBatch,
    active_count: usize,

    fn init() BatchManager {
        var self = BatchManager{
            .batches = undefined,
            .active_count = 0,
        };
        for (&self.batches) |*b| {
            b.* = ClientBatch.init();
        }
        return self;
    }

    /// Add data for a client, returns batch if it needs flushing
    fn addOrFlush(self: *BatchManager, client_id: config.ClientId, data: []const u8) ?*const ClientBatch {
        // Find existing batch for this client
        for (self.batches[0..self.active_count]) |*batch| {
            if (batch.client_id == client_id) {
                if (batch.canFit(data.len)) {
                    batch.add(data);
                    return null;
                } else {
                    // Return full batch, will be flushed, then retry
                    return batch;
                }
            }
        }

        // No existing batch, create new one
        if (self.active_count < MAX_CLIENT_BATCHES) {
            const batch = &self.batches[self.active_count];
            batch.reset(client_id);
            batch.add(data);
            self.active_count += 1;
            return null;
        }

        // All slots full, flush oldest (first) batch
        return &self.batches[0];
    }

    /// Mark a batch as flushed and ready for reuse
    fn markFlushed(self: *BatchManager, batch: *const ClientBatch) void {
        // Find the batch index
        const batch_ptr = @intFromPtr(batch);
        for (self.batches[0..self.active_count], 0..) |*b, i| {
            if (@intFromPtr(b) == batch_ptr) {
                // Move last active batch to this slot
                if (i < self.active_count - 1) {
                    self.batches[i] = self.batches[self.active_count - 1];
                }
                self.active_count -= 1;
                return;
            }
        }
    }

    /// Get all active batches for final flush
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
    processor_stats: [NUM_PROCESSORS]proc.ProcessorStats,

    pub fn totalProcessed(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| {
            total += ps.messages_processed;
        }
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

    /// Per-message encode buffer
    encode_buf: [512]u8,

    /// Batch manager for output batching
    batch_mgr: BatchManager,

    cfg: config.Config,
    allocator: std.mem.Allocator,

    running: std.atomic.Value(bool),

    messages_routed: [NUM_PROCESSORS]std.atomic.Value(u64),
    outputs_dispatched: std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),
    disconnect_cancels: std.atomic.Value(u64),
    batches_sent: std.atomic.Value(u64),

    const Self = @This();

    /// Heap-allocate and initialize a ThreadedServer.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Initialize queues
        for (0..NUM_PROCESSORS) |i| {
            self.input_queues[i] = try allocator.create(proc.InputQueue);
            self.input_queues[i].* = proc.InputQueue.init();
        }
        errdefer {
            for (0..NUM_PROCESSORS) |i| {
                allocator.destroy(self.input_queues[i]);
            }
        }

        for (0..NUM_PROCESSORS) |i| {
            self.output_queues[i] = try allocator.create(proc.OutputQueue);
            self.output_queues[i].* = proc.OutputQueue.init();
        }
        errdefer {
            for (0..NUM_PROCESSORS) |i| {
                allocator.destroy(self.output_queues[i]);
            }
        }

        // Initialize embedded structs in-place
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
        std.log.info("Channel capacity: {d}, Output drain limit: {d}, Batch size: {d}", .{
            proc.CHANNEL_CAPACITY,
            OUTPUT_DRAIN_LIMIT,
            MAX_UDP_BATCH_SIZE,
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
            std.log.info("TCP server listening on {s}:{d}", .{ self.cfg.tcp_addr, self.cfg.tcp_port });
        }

        if (self.cfg.udp_enabled) {
            self.udp.on_message = onUdpMessage;
            self.udp.callback_ctx = self;
            try self.udp.start(self.cfg.udp_addr, self.cfg.udp_port);
            std.log.info("UDP server listening on {s}:{d}", .{ self.cfg.udp_addr, self.cfg.udp_port });
        }

        if (self.cfg.mcast_enabled) {
            try self.multicast.start(self.cfg.mcast_group, self.cfg.mcast_port, self.cfg.mcast_ttl);
            std.log.info("Multicast publishing to {s}:{d}", .{ self.cfg.mcast_group, self.cfg.mcast_port });
        }

        self.running.store(true, .release);
        std.log.info("Threaded server started ({d} processors)", .{NUM_PROCESSORS});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) {
            return;
        }

        std.log.info("Stopping threaded server...", .{});
        std.log.info("Batches sent: {d}", .{self.batches_sent.load(.monotonic)});
        self.running.store(false, .release);

        self.tcp.stop();
        self.udp.stop();
        self.multicast.stop();

        // Final drain of output queues
        self.drainOutputQueues();

        for (&self.processors) |*p| {
            if (p.*) |*processor| {
                processor.deinit();
                p.* = null;
            }
        }

        std.log.info("Threaded server stopped", .{});
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running.load(.acquire);
    }

    pub fn run(self: *Self) !void {
        std.log.info("Threaded server running...", .{});

        while (self.running.load(.acquire)) {
            try self.pollOnce(DEFAULT_POLL_TIMEOUT_MS);
        }

        std.log.info("Threaded server event loop exited", .{});
    }

    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        // IMPORTANT: Drain outputs FIRST to make room for new outputs
        self.drainOutputQueues();

        if (self.cfg.tcp_enabled) {
            _ = try self.tcp.poll(timeout_ms);
        }

        if (self.cfg.udp_enabled) {
            _ = self.udp.poll() catch |err| {
                std.log.warn("UDP poll error: {any}", .{err});
                return;
            };
        }

        // Drain again after receiving new messages
        self.drainOutputQueues();
    }

    fn routeMessage(self: *Self, message: *const msg.InputMsg, client_id: config.ClientId) void {
        std.debug.assert(self.running.load(.acquire));

        const input = proc.ProcessorInput{
            .message = message.*,
            .client_id = client_id,
            .enqueue_time_ns = @truncate(std.time.nanoTimestamp()),
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
            .flush => {
                self.sendToAllProcessors(input);
            },
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

    /// Drain output queues with message batching for UDP
    fn drainOutputQueues(self: *Self) void {
        const batches_before = self.batches_sent.load(.monotonic);
        self.batch_mgr.clear();

        var total_outputs: u32 = 0;
        for (self.output_queues) |queue| {
            var count: u32 = 0;
            while (count < OUTPUT_DRAIN_LIMIT) : (count += 1) {
                const output = queue.pop() orelse break;
                self.processOutput(&output.message);
                _ = self.outputs_dispatched.fetchAdd(1, .monotonic);
                total_outputs += 1;
            }
        }

        // Flush all remaining batches
        self.flushAllBatches();

        // Log summary if we sent batches this cycle
        const batches_after = self.batches_sent.load(.monotonic);
        const batches_this_cycle = batches_after - batches_before;
        if (batches_this_cycle > 0 and total_outputs >= 100) {
            std.log.info("Drain cycle: {d} outputs -> {d} UDP batches (total: {d})", .{
                total_outputs,
                batches_this_cycle,
                batches_after,
            });
        }
    }

    /// Process a single output message, batching UDP sends
    fn processOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        // Determine client protocol for UDP clients
        const use_binary = if (config.isUdpClient(out_msg.client_id))
            self.udp.getClientProtocol(out_msg.client_id) == .binary
        else
            false; // TCP always uses CSV for now

        // Encode message based on client protocol
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

        // Handle based on message type
        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => {
                self.batchedSendToClient(out_msg.client_id, data, use_binary);
            },
            .trade => {
                self.batchedSendToClient(out_msg.client_id, data, use_binary);
                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
            .top_of_book => {
                if (out_msg.client_id != 0) {
                    self.batchedSendToClient(out_msg.client_id, data, use_binary);
                }
                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
        }
    }

    /// Add message to batch, flushing if needed
    fn batchedSendToClient(self: *Self, client_id: config.ClientId, data: []const u8, is_binary: bool) void {
        if (client_id == 0) return;

        // TCP messages are not batched (TCP handles its own buffering)
        if (!config.isUdpClient(client_id)) {
            _ = self.tcp.send(client_id, data);
            return;
        }

        // Binary protocol: send immediately (fixed-size messages, no newline delimiter)
        // CSV protocol: batch multiple messages into single UDP packet
        if (is_binary) {
            _ = self.udp.send(client_id, data);
            _ = self.batches_sent.fetchAdd(1, .monotonic);
            return;
        }

        // CSV: Try to add to batch
        while (true) {
            if (self.batch_mgr.addOrFlush(client_id, data)) |full_batch| {
                // Batch is full, flush it
                self.flushBatch(full_batch);
                self.batch_mgr.markFlushed(full_batch);
                // Retry adding to a new/different batch
            } else {
                // Successfully added to batch
                break;
            }
        }
    }

    /// Flush a single batch
    fn flushBatch(self: *Self, batch: *const ClientBatch) void {
        if (batch.isEmpty()) return;

        const data = batch.getData();
        const sent = self.udp.send(batch.client_id, data);
        _ = self.batches_sent.fetchAdd(1, .monotonic);

        // Debug: log first few batches
        const batches_so_far = self.batches_sent.load(.monotonic);
        if (batches_so_far <= 3) {
            std.log.info("Batch {d}: client={d}, len={d}, msgs={d}, sent={}", .{
                batches_so_far, batch.client_id, data.len, batch.msg_count, sent,
            });
        }
    }

    /// Flush all active batches
    fn flushAllBatches(self: *Self) void {
        for (self.batch_mgr.getActiveBatches()) |*batch| {
            self.flushBatch(batch);
        }
        self.batch_mgr.clear();
    }

    fn handleClientDisconnect(self: *Self, client_id: config.ClientId) void {
        std.debug.assert(client_id != 0);

        std.log.info("Client {d} disconnected, sending cancel-on-disconnect", .{client_id});

        const cancel_msg = msg.InputMsg.flush();

        const input = proc.ProcessorInput{
            .message = cancel_msg,
            .client_id = client_id,
            .enqueue_time_ns = @truncate(std.time.nanoTimestamp()),
        };

        for (0..NUM_PROCESSORS) |i| {
            _ = self.input_queues[i].push(input);
        }

        _ = self.disconnect_cancels.fetchAdd(1, .monotonic);
    }

    fn onTcpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.running.load(.acquire));
        self.routeMessage(message, client_id);
    }

    fn onTcpDisconnect(client_id: config.ClientId, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.running.load(.acquire)) return;
        self.handleClientDisconnect(client_id);
    }

    fn onUdpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.running.load(.acquire));
        self.routeMessage(message, client_id);
    }

    pub fn getStats(self: *const Self) ServerStats {
        var stats = ServerStats{
            .messages_routed = undefined,
            .outputs_dispatched = self.outputs_dispatched.load(.monotonic),
            .messages_dropped = self.messages_dropped.load(.monotonic),
            .disconnect_cancels = self.disconnect_cancels.load(.monotonic),
            .processor_stats = undefined,
        };

        for (0..NUM_PROCESSORS) |i| {
            stats.messages_routed[i] = self.messages_routed[i].load(.monotonic);
            if (self.processors[i]) |*p| {
                stats.processor_stats[i] = p.getStats();
            } else {
                stats.processor_stats[i] = std.mem.zeroes(proc.ProcessorStats);
            }
        }

        return stats;
    }

    /// Get batches sent count (for diagnostics)
    pub fn getBatchesSent(self: *const Self) u64 {
        return self.batches_sent.load(.monotonic);
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

    // Should not fit another 200 bytes
    try std.testing.expect(!batch.canFit(200));
    // Should fit 100 bytes
    try std.testing.expect(batch.canFit(100));
}

test "BatchManager multi-client" {
    var mgr = BatchManager.init();

    // Add messages for different clients
    try std.testing.expect(mgr.addOrFlush(100, "msg1\n") == null);
    try std.testing.expect(mgr.addOrFlush(200, "msg2\n") == null);
    try std.testing.expect(mgr.addOrFlush(100, "msg3\n") == null); // Same client

    try std.testing.expectEqual(@as(usize, 2), mgr.active_count);
}

test "ServerStats total processed" {
    var stats = ServerStats{
        .messages_routed = .{ 100, 200 },
        .outputs_dispatched = 150,
        .messages_dropped = 0,
        .disconnect_cancels = 0,
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
                .idle_cycles = 0,
            },
        },
    };

    try std.testing.expectEqual(@as(u64, 300), stats.totalProcessed());
}
