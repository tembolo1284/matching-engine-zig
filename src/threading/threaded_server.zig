//! Threaded server with I/O thread and dual processor threads.
//!
//! Architecture:
//! ```
//!   ┌─────────────────────────────────────────────────────────────┐
//!   │                        I/O Thread                           │
//!   │  ┌─────────┐  ┌─────────┐  ┌─────────────────────────────┐ │
//!   │  │   TCP   │  │   UDP   │  │        Multicast            │ │
//!   │  │ Server  │  │ Server  │  │        Publisher            │ │
//!   │  └────┬────┘  └────┬────┘  └─────────────┬───────────────┘ │
//!   │       │            │                      │                 │
//!   │       └─────────┬──┴──────────────────────┘                 │
//!   │                 │                                           │
//!   │          ┌──────▼──────┐                                    │
//!   │          │   Router    │ (A-M → P0, N-Z → P1)               │
//!   │          └──────┬──────┘                                    │
//!   └─────────────────┼───────────────────────────────────────────┘
//!                     │
//!        ┌────────────┴────────────┐
//!        ▼                         ▼
//!   ┌─────────┐               ┌─────────┐
//!   │ Input 0 │               │ Input 1 │  (SPSC Queues)
//!   └────┬────┘               └────┬────┘
//!        ▼                         ▼
//!   ┌─────────────┐           ┌─────────────┐
//!   │ Processor 0 │           │ Processor 1 │  (Matching Threads)
//!   │   (A-M)     │           │   (N-Z)     │
//!   └──────┬──────┘           └──────┬──────┘
//!          ▼                         ▼
//!   ┌──────────┐               ┌──────────┐
//!   │ Output 0 │               │ Output 1 │  (SPSC Queues)
//!   └────┬─────┘               └────┬─────┘
//!        │                          │
//!        └────────────┬─────────────┘
//!                     ▼
//!   ┌─────────────────────────────────────────────────────────────┐
//!   │                    I/O Thread (dispatch)                     │
//!   │         Routes responses back to TCP/UDP/Multicast          │
//!   └─────────────────────────────────────────────────────────────┘
//! ```
//!
//! Key design decisions:
//! - Symbol-based partitioning eliminates cross-processor coordination
//! - SPSC queues provide lock-free, cache-friendly communication
//! - Cancel-on-disconnect ensures no orphaned orders
//! - Multicast for market data, unicast for order responses

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

/// Number of processor threads.
pub const NUM_PROCESSORS: u32 = 2;

/// Maximum messages to drain from output channels per poll cycle.
/// Prevents I/O starvation during high matching activity.
const OUTPUT_DRAIN_LIMIT: u32 = 256;

/// Default poll timeout in milliseconds.
const DEFAULT_POLL_TIMEOUT_MS: i32 = 1;

// ============================================================================
// Statistics
// ============================================================================

/// Server statistics snapshot.
pub const ServerStats = struct {
    /// Messages routed to each processor.
    messages_routed: [NUM_PROCESSORS]u64,
    /// Total outputs dispatched to clients.
    outputs_dispatched: u64,
    /// Messages dropped due to full input channel.
    messages_dropped: u64,
    /// Cancel-on-disconnect events processed.
    disconnect_cancels: u64,
    /// Per-processor statistics.
    processor_stats: [NUM_PROCESSORS]proc.ProcessorStats,

    /// Total messages processed across all processors.
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
    // === Network I/O ===
    tcp: TcpServer,
    udp: UdpServer,
    multicast: MulticastPublisher,

    // === Channels ===
    /// Input channels (I/O → Processors)
    input_channels: [NUM_PROCESSORS]proc.InputChannel,
    /// Output channels (Processors → I/O)
    output_channels: [NUM_PROCESSORS]proc.OutputChannel,

    // === Processor Threads ===
    processors: [NUM_PROCESSORS]?proc.Processor,

    // === Buffers ===
    /// Send buffer for encoding output messages.
    send_buf: [4096]u8 = undefined,

    // === Configuration ===
    cfg: config.Config,
    allocator: std.mem.Allocator,

    // === Control ===
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // === Statistics ===
    messages_routed: [NUM_PROCESSORS]std.atomic.Value(u64) = .{
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    },
    outputs_dispatched: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    disconnect_cancels: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const Self = @This();

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Initialize server.
    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) Self {
        return .{
            .tcp = TcpServer.init(allocator),
            .udp = UdpServer.init(),
            .multicast = MulticastPublisher.init(),
            .input_channels = .{ proc.InputChannel.init(), proc.InputChannel.init() },
            .output_channels = .{ proc.OutputChannel.init(), proc.OutputChannel.init() },
            .processors = .{ null, null },
            .cfg = cfg,
            .allocator = allocator,
        };
    }

    /// Cleanup server resources.
    pub fn deinit(self: *Self) void {
        self.stop();
        self.tcp.deinit();
        self.udp.deinit();
        self.multicast.deinit();
    }

    // ========================================================================
    // Server Control
    // ========================================================================

    /// Start server and processor threads.
    pub fn start(self: *Self) !void {
        std.debug.assert(!self.running.load(.acquire));

        std.log.info("Starting threaded server...", .{});

        // Start processor threads first (they need to be ready for messages)
        for (0..NUM_PROCESSORS) |i| {
            const id: proc.ProcessorId = @enumFromInt(i);

            self.processors[i] = try proc.Processor.init(
                self.allocator,
                id,
                &self.input_channels[i],
                &self.output_channels[i],
            );

            try self.processors[i].?.start();
        }

        // Start network I/O
        if (self.cfg.tcp_enabled) {
            self.tcp.on_message = onTcpMessage;
            self.tcp.on_disconnect = onTcpDisconnect;
            self.tcp.callback_ctx = self;
            try self.tcp.start(self.cfg.tcp_addr, self.cfg.tcp_port);
            std.log.info("TCP server listening on {}:{}", .{ self.cfg.tcp_addr, self.cfg.tcp_port });
        }

        if (self.cfg.udp_enabled) {
            self.udp.on_message = onUdpMessage;
            self.udp.callback_ctx = self;
            try self.udp.start(self.cfg.udp_addr, self.cfg.udp_port);
            std.log.info("UDP server listening on {}:{}", .{ self.cfg.udp_addr, self.cfg.udp_port });
        }

        if (self.cfg.mcast_enabled) {
            try self.multicast.start(self.cfg.mcast_group, self.cfg.mcast_port, self.cfg.mcast_ttl);
            std.log.info("Multicast publishing to {}:{}", .{ self.cfg.mcast_group, self.cfg.mcast_port });
        }

        self.running.store(true, .release);
        std.log.info("Threaded server started ({} processors)", .{NUM_PROCESSORS});
    }

    /// Stop server and all processor threads.
    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) {
            return;
        }

        std.log.info("Stopping threaded server...", .{});

        self.running.store(false, .release);

        // Stop network first (no new messages)
        self.tcp.stop();
        self.udp.stop();
        self.multicast.stop();

        // Drain any remaining outputs before stopping processors
        self.drainOutputChannels();

        // Stop processors
        for (&self.processors) |*p| {
            if (p.*) |*processor| {
                processor.deinit();
                p.* = null;
            }
        }

        std.log.info("Threaded server stopped", .{});
    }

    /// Check if server is running.
    pub fn isRunning(self: *const Self) bool {
        return self.running.load(.acquire);
    }

    // ========================================================================
    // Main Event Loop
    // ========================================================================

    /// Main event loop - runs until stop() is called.
    pub fn run(self: *Self) !void {
        std.log.info("Threaded server running...", .{});

        while (self.running.load(.acquire)) {
            try self.pollOnce(DEFAULT_POLL_TIMEOUT_MS);
        }

        std.log.info("Threaded server event loop exited", .{});
    }

    /// Run single poll iteration (for integration with external event loops).
    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        // Poll network I/O
        if (self.cfg.tcp_enabled) {
            _ = try self.tcp.poll(timeout_ms);
        }

        if (self.cfg.udp_enabled) {
            _ = self.udp.poll() catch |err| {
                std.log.warn("UDP poll error: {}", .{err});
                return;
            };
        }

        // Drain output channels from processors
        self.drainOutputChannels();
    }

    // ========================================================================
    // Message Routing
    // ========================================================================

    /// Route message to appropriate processor based on symbol.
    fn routeMessage(self: *Self, message: *const msg.InputMsg, client_id: config.ClientId) void {
        std.debug.assert(self.running.load(.acquire));

        const input = proc.ProcessorInput{
            .message = message.*,
            .client_id = client_id,
            .enqueue_time_ns = std.time.nanoTimestamp(),
        };

        switch (message.msg_type) {
            .new_order => {
                // Route by symbol
                const processor_id = proc.routeSymbol(message.data.new_order.symbol);
                self.sendToProcessor(processor_id, input);
            },

            .cancel => {
                // If symbol is provided, route to specific processor
                if (!msg.symbolIsEmpty(&message.data.cancel.symbol)) {
                    const processor_id = proc.routeSymbol(message.data.cancel.symbol);
                    self.sendToProcessor(processor_id, input);
                } else {
                    // No symbol - must send to both processors
                    // This is less efficient but necessary for compatibility
                    self.sendToAllProcessors(input);
                }
            },

            .flush => {
                // Flush goes to all processors
                self.sendToAllProcessors(input);
            },
        }
    }

    fn sendToProcessor(self: *Self, processor_id: proc.ProcessorId, input: proc.ProcessorInput) void {
        const idx = @intFromEnum(processor_id);

        if (self.input_channels[idx].send(input)) {
            _ = self.messages_routed[idx].fetchAdd(1, .monotonic);
        } else {
            _ = self.messages_dropped.fetchAdd(1, .monotonic);
            std.log.warn("Input channel {} full, dropping message", .{idx});
        }
    }

    fn sendToAllProcessors(self: *Self, input: proc.ProcessorInput) void {
        for (0..NUM_PROCESSORS) |i| {
            if (self.input_channels[i].send(input)) {
                _ = self.messages_routed[i].fetchAdd(1, .monotonic);
            } else {
                _ = self.messages_dropped.fetchAdd(1, .monotonic);
            }
        }
    }

    // ========================================================================
    // Output Dispatch
    // ========================================================================

    /// Drain output channels and dispatch responses.
    fn drainOutputChannels(self: *Self) void {
        for (&self.output_channels) |*channel| {
            var count: u32 = 0;

            while (count < OUTPUT_DRAIN_LIMIT) : (count += 1) {
                if (channel.tryRecv()) |output| {
                    self.dispatchOutput(&output.message);
                    _ = self.outputs_dispatched.fetchAdd(1, .monotonic);
                } else {
                    break;
                }
            }
        }
    }

    /// Dispatch a single output message to appropriate destination.
    fn dispatchOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        // Encode message
        const len = csv_codec.encodeOutput(out_msg, &self.send_buf) catch |err| {
            std.log.err("Failed to encode output message: {}", .{err});
            return;
        };

        const data = self.send_buf[0..len];

        // Route based on message type
        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => {
                // Send to originating client only
                self.sendToClient(out_msg.client_id, data);
            },

            .trade => {
                // Send to originating client + multicast
                self.sendToClient(out_msg.client_id, data);

                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },

            .top_of_book => {
                // Multicast only (no specific client)
                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
        }
    }

    fn sendToClient(self: *Self, client_id: config.ClientId, data: []const u8) void {
        if (client_id == 0) {
            return; // No client to send to
        }

        if (config.isUdpClient(client_id)) {
            _ = self.udp.send(client_id, data);
        } else {
            _ = self.tcp.send(client_id, data);
        }
    }

    // ========================================================================
    // Client Disconnect Handling
    // ========================================================================

    /// Handle client disconnection - cancel all their orders.
    fn handleClientDisconnect(self: *Self, client_id: config.ClientId) void {
        std.debug.assert(client_id != 0);

        std.log.info("Client {} disconnected, sending cancel-on-disconnect", .{client_id});

        // Create a cancel-all message for this client
        // We send to both processors since we don't track client→symbols mapping
        const cancel_msg = msg.InputMsg{
            .msg_type = .flush, // Using flush as cancel-all for client
            // In a production system, you'd have a dedicated cancel_client message type
        };

        // For now, we'll rely on the engine's cancelClientOrders method
        // which will be called by each processor
        const input = proc.ProcessorInput{
            .message = cancel_msg,
            .client_id = client_id,
            .enqueue_time_ns = std.time.nanoTimestamp(),
        };

        // Send cancel request to both processors
        // They will filter by client_id in cancelClientOrders
        for (0..NUM_PROCESSORS) |i| {
            _ = self.input_channels[i].send(input);
        }

        _ = self.disconnect_cancels.fetchAdd(1, .monotonic);
    }

    // ========================================================================
    // Callbacks
    // ========================================================================

    fn onTcpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.running.load(.acquire));
        self.routeMessage(message, client_id);
    }

    fn onTcpDisconnect(client_id: config.ClientId, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (!self.running.load(.acquire)) {
            return;
        }

        self.handleClientDisconnect(client_id);
    }

    fn onUdpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.running.load(.acquire));
        self.routeMessage(message, client_id);
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    /// Get server statistics snapshot.
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
