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
const tcp_server = @import("tcp_server.zig");
const TcpServer = tcp_server.TcpServer;
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
    send_buf: [4096]u8,
    cfg: config.Config,
    allocator: std.mem.Allocator,

    // Statistics
    messages_processed: u64 = 0,
    encode_errors: u64 = 0,

    const Self = @This();

    /// Initialize server in-place. Required due to large embedded structs.
    pub fn initInPlace(
        self: *Self,
        allocator: std.mem.Allocator,
        engine: *MatchingEngine,
        cfg_param: config.Config,
    ) void {
        self.tcp = TcpServer.init(allocator);
        self.udp = UdpServer.init();
        self.multicast = MulticastPublisher.init();
        self.engine = engine;
        self.output = OutputBuffer.init();
        self.send_buf = undefined;
        self.cfg = cfg_param;
        self.allocator = allocator;
        self.messages_processed = 0;
        self.encode_errors = 0;
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

        std.log.info("Server stopped: processed {} messages, {} encode errors", .{
            self.messages_processed,
            self.encode_errors,
        });
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
        self.messages_processed += 1;
        self.dispatchOutputs();
    }

    fn dispatchOutputs(self: *Self) void {
        for (self.output.slice()) |*out_msg| {
            const len = csv_codec.encodeOutput(out_msg, &self.send_buf) catch {
                self.encode_errors += 1;
                std.log.debug("Failed to encode output message type {}", .{out_msg.msg_type});
                continue;
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
    }

    /// Send data to client, routing based on client ID type.
    fn sendToClient(self: *Self, client_id: config.ClientId, data: []const u8) void {
        if (config.isUdpClient(client_id)) {
            _ = self.udp.send(client_id, data);
        } else if (config.isValidClient(client_id)) {
            _ = self.tcp.send(client_id, data);
        }
    }

    /// Get server statistics.
    pub fn getStats(self: *const Self) ServerStats {
        return .{
            .messages_processed = self.messages_processed,
            .encode_errors = self.encode_errors,
            .tcp_stats = self.tcp.getStats(),
            .udp_stats = self.udp.getStats(),
            .multicast_stats = self.multicast.getStats(),
        };
    }

    /// Aggregated server statistics from all transports.
    pub const ServerStats = struct {
        messages_processed: u64,
        encode_errors: u64,
        tcp_stats: tcp_server.ServerStats,
        udp_stats: UdpServer.UdpServerStats,
        multicast_stats: MulticastPublisher.PublisherStats,
    };
};
