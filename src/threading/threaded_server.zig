//! Threaded server with I/O thread and dual processor threads.
//!
//! Architecture:
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

pub const ThreadedServer = struct {
    // Network I/O
    tcp: TcpServer,
    udp: UdpServer,
    multicast: MulticastPublisher,

    // Channels (I/O → Processors)
    input_channels: [2]proc.InputChannel,

    // Channels (Processors → I/O)
    output_channels: [2]proc.OutputChannel,

    // Processor threads
    processors: [2]?proc.Processor,

    // Send buffer for encoding
    send_buf: [4096]u8 = undefined,

    cfg: config.Config,
    allocator: std.mem.Allocator,

    // Statistics
    messages_routed: [2]u64 = .{ 0, 0 },
    outputs_dispatched: u64 = 0,

    const Self = @This();

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

    pub fn deinit(self: *Self) void {
        self.stop();
        self.tcp.deinit();
        self.udp.deinit();
        self.multicast.deinit();
    }

    pub fn start(self: *Self) !void {
        // Start processor threads first
        for (0..2) |i| {
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
        }

        if (self.cfg.udp_enabled) {
            self.udp.on_message = onUdpMessage;
            self.udp.callback_ctx = self;
            try self.udp.start(self.cfg.udp_addr, self.cfg.udp_port);
        }

        if (self.cfg.mcast_enabled) {
            try self.multicast.start(self.cfg.mcast_group, self.cfg.mcast_port, self.cfg.mcast_ttl);
        }

        std.log.info("Threaded server started (2 processors)", .{});
    }

    pub fn stop(self: *Self) void {
        // Stop network first
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
    }

    /// Main event loop
    pub fn run(self: *Self) !void {
        std.log.info("Threaded server running...", .{});

        while (true) {
            try self.pollOnce(1); // 1ms timeout for responsiveness
        }
    }

    /// Single poll iteration
    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        // Poll network I/O
        if (self.cfg.tcp_enabled) {
            _ = try self.tcp.poll(timeout_ms);
        }

        if (self.cfg.udp_enabled) {
            _ = self.udp.poll() catch 0;
        }

        // Drain output channels from processors
        self.drainOutputChannels();
    }

    /// Route message to appropriate processor based on symbol
    fn routeMessage(self: *Self, message: *const msg.InputMsg, client_id: config.ClientId) void {
        const input = proc.ProcessorInput{
            .message = message.*,
            .client_id = client_id,
        };

        switch (message.msg_type) {
            .new_order => {
                // Route by symbol
                const processor_id = proc.routeSymbol(message.data.new_order.symbol);
                const idx = @intFromEnum(processor_id);

                if (self.input_channels[idx].send(input)) {
                    self.messages_routed[idx] += 1;
                } else {
                    std.log.warn("Input channel {} full, dropping message", .{idx});
                }
            },
            .cancel => {
                // Cancel goes to BOTH processors (don't know which has the order)
                _ = self.input_channels[0].send(input);
                _ = self.input_channels[1].send(input);
                self.messages_routed[0] += 1;
                self.messages_routed[1] += 1;
            },
            .flush => {
                // Flush goes to BOTH processors
                _ = self.input_channels[0].send(input);
                _ = self.input_channels[1].send(input);
                self.messages_routed[0] += 1;
                self.messages_routed[1] += 1;
            },
        }
    }

    /// Drain output channels and dispatch responses
    fn drainOutputChannels(self: *Self) void {
        // Check both output channels
        for (&self.output_channels) |*channel| {
            // Drain up to 100 messages per poll to avoid starvation
            var count: usize = 0;
            while (count < 100) : (count += 1) {
                if (channel.tryRecv()) |output| {
                    self.dispatchOutput(&output.message);
                    self.outputs_dispatched += 1;
                } else {
                    break;
                }
            }
        }
    }

    /// Dispatch a single output message
    fn dispatchOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        // Encode message
        const len = csv_codec.encodeOutput(out_msg, &self.send_buf) catch return;
        const data = self.send_buf[0..len];

        // Route based on message type
        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => {
                // Send to originating client only
                if (config.isUdpClient(out_msg.client_id)) {
                    _ = self.udp.send(out_msg.client_id, data);
                } else if (out_msg.client_id != 0) {
                    _ = self.tcp.send(out_msg.client_id, data);
                }
            },
            .trade => {
                // Send to originating client + multicast
                if (config.isUdpClient(out_msg.client_id)) {
                    _ = self.udp.send(out_msg.client_id, data);
                } else if (out_msg.client_id != 0) {
                    _ = self.tcp.send(out_msg.client_id, data);
                }

                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
            .top_of_book => {
                // Multicast only
                if (self.cfg.mcast_enabled) {
                    _ = self.multicast.publish(out_msg);
                }
            },
        }
    }

    // TCP callback
    fn onTcpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.routeMessage(message, client_id);
    }

    // TCP disconnect callback
    fn onTcpDisconnect(client_id: config.ClientId, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self;
        _ = client_id;
        // TODO: Send cancel-on-disconnect to both processors
        // For now, orders remain until explicitly cancelled
    }

    // UDP callback
    fn onUdpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.routeMessage(message, client_id);
    }

    /// Get statistics
    pub fn getStats(self: *const Self) struct {
        routed_p0: u64,
        routed_p1: u64,
        dispatched: u64,
        p0_processed: u64,
        p1_processed: u64,
    } {
        var p0_stats: struct { processed: u64, outputs: u64 } = .{ .processed = 0, .outputs = 0 };
        var p1_stats: struct { processed: u64, outputs: u64 } = .{ .processed = 0, .outputs = 0 };

        if (self.processors[0]) |*p| {
            p0_stats = p.getStats();
        }
        if (self.processors[1]) |*p| {
            p1_stats = p.getStats();
        }

        return .{
            .routed_p0 = self.messages_routed[0],
            .routed_p1 = self.messages_routed[1],
            .dispatched = self.outputs_dispatched,
            .p0_processed = p0_stats.processed,
            .p1_processed = p1_stats.processed,
        };
    }
};
