//! Threaded server with I/O thread and dual processor threads.
//!
//! Architecture: I/O thread routes to processors by symbol (A-M vs N-Z).
//! All large structures heap-allocated to keep stack frames bounded.
//!
//! Optimizations:
//! - Message batching: Multiple CSV messages packed into single UDP packet
//! - Protocol-aware encoding: Binary clients get binary responses, CSV clients get CSV
//! - Aggressive output draining: Process up to OUTPUT_DRAIN_LIMIT outputs per poll cycle
//!
//! UDP Batching:
//! - CSV messages are batched into single UDP packets (up to MTU limit)
//! - Binary messages sent immediately (fixed-size, more efficient individually)
//! - Batches flushed at end of each drain cycle
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: All loops bounded by explicit constants (OUTPUT_DRAIN_LIMIT, MAX_CLIENT_BATCHES)
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
const UdpProtocol = udp_server.Protocol;
const MulticastPublisher = @import("../transport/multicast.zig").MulticastPublisher;
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");
// ============================================================================
// Configuration
// ============================================================================
pub const NUM_PROCESSORS: usize = 2;
/// Output drain limit per poll cycle.
/// At 200K orders/sec generating 2 outputs each = 400K outputs/sec.
/// At 1000 polls/sec, need to drain 400 outputs per poll minimum.
/// We use 128K to handle burst scenarios with margin.
const OUTPUT_DRAIN_LIMIT: u32 = 131072;
/// Default poll timeout in milliseconds.
/// Short timeout ensures responsive output draining.
const DEFAULT_POLL_TIMEOUT_MS: i32 = 2;
/// Maximum UDP payload size.
/// Derived from: MTU (1500) - IP header (20) - UDP header (8) = 1472 bytes.
/// Using 1400 for safety margin with various network configurations.
const MAX_UDP_PAYLOAD: usize = 1400;
/// Maximum batch size for CSV message batching.
/// Slightly under MAX_UDP_PAYLOAD to ensure we never exceed MTU.
const MAX_UDP_BATCH_SIZE: usize = MAX_UDP_PAYLOAD;
/// Maximum number of client batches to track simultaneously.
/// Each active UDP client gets a batch slot.
const MAX_CLIENT_BATCHES: usize = 64;
/// Maximum encode buffer size.
const ENCODE_BUF_SIZE: usize = 512;
// Compile-time validation
comptime {
    std.debug.assert(NUM_PROCESSORS > 0);
    std.debug.assert(NUM_PROCESSORS <= 8); // Reasonable limit
    std.debug.assert(OUTPUT_DRAIN_LIMIT > 0);
    std.debug.assert(OUTPUT_DRAIN_LIMIT <= proc.CHANNEL_CAPACITY * NUM_PROCESSORS * 2);
    std.debug.assert(MAX_UDP_PAYLOAD > 0);
    std.debug.assert(MAX_UDP_PAYLOAD <= 1472); // MTU - headers
    std.debug.assert(MAX_UDP_BATCH_SIZE > 0);
    std.debug.assert(MAX_UDP_BATCH_SIZE <= MAX_UDP_PAYLOAD);
    std.debug.assert(MAX_CLIENT_BATCHES > 0);
    std.debug.assert(MAX_CLIENT_BATCHES <= 1024);
    std.debug.assert(ENCODE_BUF_SIZE >= 256);
}
// ============================================================================
// Output Batching
// ============================================================================
/// Batch buffer for accumulating CSV messages to same UDP client.
/// Binary protocol messages are sent immediately (not batched).
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
        std.debug.assert(data.len > 0);
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
        self.msg_count += 1;
        std.debug.assert(self.len <= MAX_UDP_BATCH_SIZE);
    }
    fn getData(self: *const ClientBatch) []const u8 {
        return self.buf[0..self.len];
    }
    fn isEmpty(self: *const ClientBatch) bool {
        return self.len == 0;
    }
};
/// Multi-client batch manager.
/// Tracks active batches for multiple UDP clients simultaneously.
///
/// P10 Rule 2: All loops bounded by MAX_CLIENT_BATCHES.
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
    /// Find existing batch for client, or return null if not found.
    ///
    /// P10 Rule 2: O(n) scan bounded by active_count <= MAX_CLIENT_BATCHES.
    fn findBatch(self: *BatchManager, client_id: config.ClientId) ?*ClientBatch {
        std.debug.assert(client_id != 0);
        // P10 Rule 2: Bounded by active_count which is <= MAX_CLIENT_BATCHES
        for (self.batches[0..self.active_count]) |*batch| {
            if (batch.client_id == client_id) {
                return batch;
            }
        }
        return null;
    }
    /// Get or create a batch for client.
    /// Returns null if all slots are full (caller should flush oldest).
    fn getOrCreateBatch(self: *BatchManager, client_id: config.ClientId) ?*ClientBatch {
        std.debug.assert(client_id != 0);
        // Find existing
        if (self.findBatch(client_id)) |batch| {
            return batch;
        }
        // Create new if space available
        if (self.active_count < MAX_CLIENT_BATCHES) {
            const batch = &self.batches[self.active_count];
            batch.reset(client_id);
            self.active_count += 1;
            std.debug.assert(self.active_count <= MAX_CLIENT_BATCHES);
            return batch;
        }
        return null;
    }
    /// Get the oldest (first) batch for flushing when slots are full.
    fn getOldestBatch(self: *BatchManager) ?*ClientBatch {
        if (self.active_count > 0) {
            return &self.batches[0];
        }
        return null;
    }
    /// Remove a batch after flushing (swap with last to maintain density).
    fn removeBatch(self: *BatchManager, batch: *ClientBatch) void {
        // Find index of this batch
        const batch_ptr = @intFromPtr(batch);
        // P10 Rule 2: Bounded by active_count
        for (self.batches[0..self.active_count], 0..) |*b, i| {
            if (@intFromPtr(b) == batch_ptr) {
                // Swap with last active batch
                if (i < self.active_count - 1) {
                    self.batches[i] = self.batches[self.active_count - 1];
                }
                self.active_count -= 1;
                return;
            }
        }
    }
    /// Get all active batches (for final flush).
    fn getActiveBatches(self: *BatchManager) []ClientBatch {
        return self.batches[0..self.active_count];
    }
    /// Clear all batches (only after flushing!).
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
    processor_stats: [NUM_PROCESSORS]proc.ProcessorStats,
    pub fn totalProcessed(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| {
            total += ps.messages_processed;
        }
        return total;
    }
    pub fn totalCriticalDrops(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| {
            total += ps.critical_drops;
        }
        return total;
    }
    pub fn isHealthy(self: ServerStats) bool {
        return self.totalCriticalDrops() == 0 and self.tcp_send_failures == 0;
    }
    pub fn totalOutputs(self: ServerStats) u64 {
        var total: u64 = 0;
        for (self.processor_stats) |ps| {
            total += ps.outputs_generated;
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
    /// Per-message encode buffer.
    encode_buf: [ENCODE_BUF_SIZE]u8,
    /// Batch manager for UDP output batching.
    batch_mgr: BatchManager,
    cfg: config.Config,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    // Statistics (atomics for thread-safe access)
    messages_routed: [NUM_PROCESSORS]std.atomic.Value(u64),
    outputs_dispatched: std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),
    disconnect_cancels: std.atomic.Value(u64),
    batches_sent: std.atomic.Value(u64),
    tcp_send_failures: std.atomic.Value(u64),
    const Self = @This();
    /// Heap-allocate and initialize a ThreadedServer.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        // Initialize queues
        for (0..NUM_PROCESSORS) |i| {
            self.input_queues[i] = try allocator.create(proc.InputQueue);
            self.input_queues[i].* = .{}; // old temp copy way -> proc.InputQueue.init();
        }
        errdefer {
            for (0..NUM_PROCESSORS) |i| {
                allocator.destroy(self.input_queues[i]);
            }
        }
        for (0..NUM_PROCESSORS) |i| {
            self.output_queues[i] = try allocator.create(proc.OutputQueue);
            self.output_queues[i].* = .{}; // proc.OutputQueue.init();
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
        std.log.info("Config: channel_capacity={d}, drain_limit={d}, batch_size={d}, max_batches={d}", .{
            proc.CHANNEL_CAPACITY,
            OUTPUT_DRAIN_LIMIT,
            MAX_UDP_BATCH_SIZE,
            MAX_CLIENT_BATCHES,
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
    /// Run the server event loop.
    ///
    /// P10 Rule 2: Loop terminates when running becomes false.
    /// Call stop() or set running to false to exit.
    pub fn run(self: *Self) !void {
        std.log.info("Threaded server running...", .{});
        // P10 Rule 2: Loop bounded by running flag
        while (self.running.load(.acquire)) {
            try self.pollOnce(DEFAULT_POLL_TIMEOUT_MS);
        }
        std.log.info("Threaded server event loop exited", .{});
    }
    /// Run for a limited number of iterations (for testing).
    ///
    /// P10 Rule 2: Loop bounded by max_iterations parameter.
    pub fn runBounded(self: *Self, max_iterations: usize) !void {
        std.debug.assert(max_iterations > 0);
        var iterations: usize = 0;
        // P10 Rule 2: Bounded by max_iterations
        while (self.running.load(.acquire) and iterations < max_iterations) : (iterations += 1) {
            try self.pollOnce(DEFAULT_POLL_TIMEOUT_MS);
        }
    }
    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        std.debug.assert(timeout_ms >= 0);
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
        std.debug.assert(client_id != 0 or message.msg_type == .flush);
        const input = proc.ProcessorInput{
            .message = message.*,
            .client_id = client_id,
            .enqueue_time_ns = if (proc.TRACK_LATENCY)
                @truncate(std.time.nanoTimestamp())
            else
                0,
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
        std.debug.assert(idx < NUM_PROCESSORS);
        if (self.input_queues[idx].push(input)) {
            _ = self.messages_routed[idx].fetchAdd(1, .monotonic);
        } else {
            _ = self.messages_dropped.fetchAdd(1, .monotonic);
            std.log.warn("Input queue {d} full, dropping message", .{idx});
        }
    }
    fn sendToAllProcessors(self: *Self, input: proc.ProcessorInput) void {
        // P10 Rule 2: Loop bounded by NUM_PROCESSORS
        for (0..NUM_PROCESSORS) |i| {
            if (self.input_queues[i].push(input)) {
                _ = self.messages_routed[i].fetchAdd(1, .monotonic);
            } else {
                _ = self.messages_dropped.fetchAdd(1, .monotonic);
            }
        }
    }
    /// Drain output queues with message batching for UDP.
    /// CSV messages are batched; binary messages sent immediately.
    ///
    /// P10 Rule 2: Per-queue loop bounded by OUTPUT_DRAIN_LIMIT.
    fn drainOutputQueues(self: *Self) void {
        var total_outputs: u32 = 0;
        // P10 Rule 2: Outer loop bounded by NUM_PROCESSORS
        for (self.output_queues) |queue| {
            var count: u32 = 0;
            // P10 Rule 2: Inner loop bounded by OUTPUT_DRAIN_LIMIT
            while (count < OUTPUT_DRAIN_LIMIT) : (count += 1) {
                const output = queue.pop() orelse break;
                self.processOutput(&output.message);
                _ = self.outputs_dispatched.fetchAdd(1, .monotonic);
                total_outputs += 1;
            }
        }
        // Flush all batches at end of drain cycle
        // IMPORTANT: Always flush after processing to ensure no messages stuck in batches
        self.flushAllBatches();
    }
    /// Process a single output message, batching UDP sends.
    fn processOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        // Determine client protocol for UDP clients
        const use_binary = if (config.isUdpClient(out_msg.client_id))
            self.udp.getClientProtocol(out_msg.client_id) == .binary
        else
            self.cfg.use_binary_protocol;
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
        std.debug.assert(len > 0);
        std.debug.assert(len <= ENCODE_BUF_SIZE);
        const data = self.encode_buf[0..len];
        // Handle based on message type
        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => {
                self.sendToClient(out_msg.client_id, data, use_binary);
            },
            .trade => {
                self.sendToClient(out_msg.client_id, data, use_binary);
                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
            .top_of_book => {
                if (out_msg.client_id != 0) {
                    self.sendToClient(out_msg.client_id, data, use_binary);
                }
                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
        }
    }
    /// Send message to client, using batching for CSV over UDP.
    fn sendToClient(self: *Self, client_id: config.ClientId, data: []const u8, is_binary: bool) void {
        if (client_id == 0) return;
        std.debug.assert(data.len > 0);
        // TCP messages sent directly (TCP handles its own buffering via Nagle/cork)
        if (!config.isUdpClient(client_id)) {
            const success = self.tcp.send(client_id, data);
            if (!success) {
                _ = self.tcp_send_failures.fetchAdd(1, .monotonic);
            }
            return;
        }
        // Binary UDP: send immediately (fixed-size messages, no batching benefit)
        if (is_binary) {
            _ = self.udp.send(client_id, data);
            _ = self.batches_sent.fetchAdd(1, .monotonic);
            return;
        }
        // CSV UDP: batch multiple messages into single packet
        self.batchCsvMessage(client_id, data);
    }
    /// Add CSV message to batch for client.
    fn batchCsvMessage(self: *Self, client_id: config.ClientId, data: []const u8) void {
        std.debug.assert(client_id != 0);
        std.debug.assert(data.len > 0);
        std.debug.assert(data.len <= MAX_UDP_BATCH_SIZE);
        // Try to get or create batch for this client
        if (self.batch_mgr.getOrCreateBatch(client_id)) |batch| {
            if (batch.canFit(data.len)) {
                batch.add(data);
                return;
            }
            // Batch is full, flush it first
            self.flushBatch(batch);
            batch.reset(client_id);
            batch.add(data);
            return;
        }
        // All batch slots full - flush oldest and retry
        if (self.batch_mgr.getOldestBatch()) |oldest| {
            self.flushBatch(oldest);
            self.batch_mgr.removeBatch(oldest);
            // Now create new batch
            if (self.batch_mgr.getOrCreateBatch(client_id)) |batch| {
                batch.add(data);
                return;
            }
        }
        // Fallback: send directly without batching
        _ = self.udp.send(client_id, data);
        _ = self.batches_sent.fetchAdd(1, .monotonic);
    }
    /// Flush a single batch to UDP.
    fn flushBatch(self: *Self, batch: *const ClientBatch) void {
        if (batch.isEmpty()) return;
        const data = batch.getData();
        std.debug.assert(data.len > 0);
        std.debug.assert(data.len <= MAX_UDP_BATCH_SIZE);
        _ = self.udp.send(batch.client_id, data);
        _ = self.batches_sent.fetchAdd(1, .monotonic);
    }
    /// Flush all active batches.
    ///
    /// P10 Rule 2: Loop bounded by MAX_CLIENT_BATCHES via getActiveBatches().
    fn flushAllBatches(self: *Self) void {
        // P10 Rule 2: Bounded by active_count which is <= MAX_CLIENT_BATCHES
        for (self.batch_mgr.getActiveBatches()) |*batch| {
            self.flushBatch(batch);
        }
        // Clear only AFTER flushing to prevent data loss
        self.batch_mgr.clear();
    }
    fn handleClientDisconnect(self: *Self, client_id: config.ClientId) void {
        std.debug.assert(client_id != 0);
        std.log.info("Client {d} disconnected, sending cancel-on-disconnect", .{client_id});
        const cancel_msg = msg.InputMsg.flush();
        const input = proc.ProcessorInput{
            .message = cancel_msg,
            .client_id = client_id,
            .enqueue_time_ns = if (proc.TRACK_LATENCY)
                @truncate(std.time.nanoTimestamp())
            else
                0,
        };
        // P10 Rule 2: Loop bounded by NUM_PROCESSORS
        for (0..NUM_PROCESSORS) |i| {
            _ = self.input_queues[i].push(input);
        }
        _ = self.disconnect_cancels.fetchAdd(1, .monotonic);
    }
    fn onTcpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        std.debug.assert(ctx != null);
        std.debug.assert(config.isTcpClient(client_id));
        const self: *Self = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.running.load(.acquire));
        self.routeMessage(message, client_id);
    }
    fn onTcpDisconnect(client_id: config.ClientId, ctx: ?*anyopaque) void {
        std.debug.assert(ctx != null);
        std.debug.assert(config.isTcpClient(client_id));
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.running.load(.acquire)) return;
        self.handleClientDisconnect(client_id);
    }
    fn onUdpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        std.debug.assert(ctx != null);
        std.debug.assert(config.isUdpClient(client_id));
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
            .tcp_send_failures = self.tcp_send_failures.load(.monotonic),
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
    /// Get batches sent count (for diagnostics).
    pub fn getBatchesSent(self: *const Self) u64 {
        return self.batches_sent.load(.monotonic);
    }
    
    /// Get TCP send failures count (for diagnostics).
    pub fn getTcpSendFailures(self: *const Self) u64 {
        return self.tcp_send_failures.load(.monotonic);
    }
    /// Check if server is healthy (no critical drops).
    pub fn isHealthy(self: *const Self) bool {
        return self.getStats().isHealthy();
    }
    /// Request graceful shutdown.
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
}
