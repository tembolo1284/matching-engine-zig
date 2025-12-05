//! Single-threaded unified server.
//!
//! DEPRECATED: Use ThreadedServer for production.
//! This module is retained for testing and simple use cases.
//!
//! For multi-threaded operation with dual matching engines,
//! see `threading/threaded_server.zig`.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const MatchingEngine = @import("../core/matching_engine.zig").MatchingEngine;
const OutputBuffer = @import("../core/order_book.zig").OutputBuffer;
const TcpServer = @import("tcp_server.zig").TcpServer;
const UdpServer = @import("udp_server.zig").UdpServer;
const MulticastPublisher = @import("multicast.zig").MulticastPublisher;
const config = @import("config.zig");

/// Single-threaded server for testing and simple deployments.
/// For production, use ThreadedServer instead.
pub const Server = struct {
    tcp: TcpServer,
    udp: UdpServer,
    multicast: MulticastPublisher,
    engine: *MatchingEngine,
    output: OutputBuffer,
    send_buf: [4096]u8 = undefined,
    cfg: config.Config,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, engine: *MatchingEngine, cfg: config.Config) Self {
        return .{
            .tcp = TcpServer.init(allocator),
            .udp = UdpServer.init(),
            .multicast = MulticastPublisher.init(),
            .engine = engine,
            .output = OutputBuffer.init(),
            .cfg = cfg,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.tcp.deinit();
        self.udp.deinit();
        self.multicast.deinit();
    }

    pub fn start(self: *Self) !void {
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

        std.log.info("Single-threaded server started (DEPRECATED - use ThreadedServer)", .{});
    }

    pub fn stop(self: *Self) void {
        self.tcp.stop();
        self.udp.stop();
        self.multicast.stop();
    }

    pub fn run(self: *Self) !void {
        while (true) {
            try self.pollOnce(100);
        }
    }

    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        if (self.cfg.tcp_enabled) {
            _ = try self.tcp.poll(timeout_ms);
        }
        if (self.cfg.udp_enabled) {
            _ = self.udp.poll() catch 0;
        }
    }

    fn onTcpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.processAndDispatch(message, client_id);
    }

    fn onUdpMessage(client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.processAndDispatch(message, client_id);
    }

    fn onTcpDisconnect(client_id: config.ClientId, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.output.clear();
        const cancelled = self.engine.cancelClientOrders(client_id, &self.output);
        if (cancelled > 0) {
            std.log.info("Cancelled {} orders for disconnected client {}", .{ cancelled, client_id });
            self.dispatchOutputs();
        }
    }

    fn processAndDispatch(self: *Self, message: *const msg.InputMsg, client_id: config.ClientId) void {
        self.output.clear();
        self.engine.processMessage(message, client_id, &self.output);
        self.dispatchOutputs();
    }

    fn dispatchOutputs(self: *Self) void {
        for (self.output.slice()) |*out_msg| {
            const len = csv_codec.encodeOutput(out_msg, &self.send_buf) catch continue;
            const data = self.send_buf[0..len];

            switch (out_msg.msg_type) {
                .ack, .cancel_ack, .reject => {
                    if (config.isUdpClient(out_msg.client_id)) {
                        _ = self.udp.send(out_msg.client_id, data);
                    } else if (config.isValidClient(out_msg.client_id)) {
                        _ = self.tcp.send(out_msg.client_id, data);
                    }
                },
                .trade => {
                    if (config.isUdpClient(out_msg.client_id)) {
                        _ = self.udp.send(out_msg.client_id, data);
                    } else if (config.isValidClient(out_msg.client_id)) {
                        _ = self.tcp.send(out_msg.client_id, data);
                    }
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
    }
};
