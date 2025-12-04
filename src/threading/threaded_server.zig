//! Threaded server with I/O thread and dual processor threads.
//!
//! Architecture: I/O thread routes to processors by symbol (A-M vs N-Z).
//! All large structures heap-allocated to keep stack frames bounded.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const TcpServer = @import("../transport/tcp_server.zig").TcpServer;
const UdpServer = @import("../transport/udp_server.zig").UdpServer;
const MulticastPublisher = @import("../transport/multicast.zig").MulticastPublisher;
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");

// ============================================================================
// Configuration
// ============================================================================

pub const NUM_PROCESSORS: usize = 2;
const OUTPUT_DRAIN_LIMIT: u32 = 256;
const DEFAULT_POLL_TIMEOUT_MS: i32 = 1;

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

    send_buf: [4096]u8,

    cfg: config.Config,
    allocator: std.mem.Allocator,

    running: std.atomic.Value(bool),

    messages_routed: [NUM_PROCESSORS]std.atomic.Value(u64),
    outputs_dispatched: std.atomic.Value(u64),
    messages_dropped: std.atomic.Value(u64),
    disconnect_cancels: std.atomic.Value(u64),

    const Self = @This();

    /// Heap-allocate and initialize a ThreadedServer.
    /// Returns pointer to avoid stack overflow from large embedded structs.
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
        self.send_buf = undefined;
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
        self.running.store(false, .release);

        self.tcp.stop();
        self.udp.stop();
        self.multicast.stop();

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
        if (self.cfg.tcp_enabled) {
            _ = try self.tcp.poll(timeout_ms);
        }

        if (self.cfg.udp_enabled) {
            _ = self.udp.poll() catch |err| {
                std.log.warn("UDP poll error: {any}", .{err});
                return;
            };
        }

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

    fn drainOutputQueues(self: *Self) void {
        for (self.output_queues) |queue| {
            var count: u32 = 0;
            while (count < OUTPUT_DRAIN_LIMIT) : (count += 1) {
                if (queue.pop()) |output| {
                    self.dispatchOutput(&output.message);
                    _ = self.outputs_dispatched.fetchAdd(1, .monotonic);
                } else {
                    break;
                }
            }
        }
    }

    fn dispatchOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        const len = csv_codec.encodeOutput(out_msg, &self.send_buf) catch |err| {
            std.log.err("Failed to encode output message: {any}", .{err});
            return;
        };

        const data = self.send_buf[0..len];

        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => {
                self.sendToClient(out_msg.client_id, data);
            },
            .trade => {
                self.sendToClient(out_msg.client_id, data);
                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
            .top_of_book => {
                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
        }
    }

    fn sendToClient(self: *Self, client_id: config.ClientId, data: []const u8) void {
        if (client_id == 0) return;

        if (config.isUdpClient(client_id)) {
            _ = self.udp.send(client_id, data);
        } else {
            _ = self.tcp.send(client_id, data);
        }
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
};

// ============================================================================
// Tests
// ============================================================================

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
                .idle_cycles = 0,
            },
        },
    };

    try std.testing.expectEqual(@as(u64, 300), stats.totalProcessed());
}
