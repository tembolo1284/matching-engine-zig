//! Unified server combining TCP, UDP, and Multicast transports.
//!
//! Handles:
//! - Message routing to matching engine
//! - Response routing back to correct client/transport
//! - Market data broadcasting via multicast

const std = @import("std");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const cfg = @import("config.zig");
const TcpServer = @import("tcp_server.zig").TcpServer;
const UdpServer = @import("udp_server.zig").UdpServer;
const MulticastPublisher = @import("multicast.zig").MulticastPublisher;
const MatchingEngine = @import("../core/matching_engine.zig").MatchingEngine;
const OutputBuffer = @import("../core/order_book.zig").OutputBuffer;
const MemoryPools = @import("../core/memory_pool.zig").MemoryPools;

// ============================================================================
// Server
// ============================================================================

pub const Server = struct {
    tcp: TcpServer,
    udp: UdpServer,
    mcast: MulticastPublisher,
    
    engine: *MatchingEngine,
    output: OutputBuffer,
    
    // Response encoding buffer
    encode_buf: [4096]u8 = undefined,
    
    // Protocol preference per transport
    tcp_protocol: codec.Protocol = .csv,
    udp_protocol: codec.Protocol = .binary,
    mcast_protocol: codec.Protocol = .binary,
    
    config: cfg.Config,
    running: bool = false,
    
    // Statistics
    messages_processed: u64 = 0,
    
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, engine: *MatchingEngine, config: cfg.Config) Self {
        var server = Self{
            .tcp = TcpServer.init(allocator),
            .udp = UdpServer.init(),
            .mcast = MulticastPublisher.init(),
            .engine = engine,
            .output = OutputBuffer.init(),
            .config = config,
            .allocator = allocator,
        };
        
        // Set callbacks
        server.tcp.on_message = onTcpMessage;
        server.tcp.on_disconnect = onTcpDisconnect;
        server.tcp.callback_ctx = &server;
        
        server.udp.on_message = onUdpMessage;
        server.udp.callback_ctx = &server;
        
        return server;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.tcp.deinit();
        self.udp.deinit();
        self.mcast.deinit();
    }

    /// Start all enabled transports
    pub fn start(self: *Self) !void {
        if (self.config.tcp_enabled) {
            try self.tcp.start(self.config.tcp_addr, self.config.tcp_port);
        }
        
        if (self.config.udp_enabled) {
            try self.udp.start(self.config.udp_addr, self.config.udp_port);
        }
        
        if (self.config.mcast_enabled) {
            try self.mcast.start(
                self.config.mcast_group,
                self.config.mcast_port,
                self.config.mcast_interface,
                self.config.mcast_ttl,
            );
        }
        
        self.running = true;
        std.log.info("Server started", .{});
    }

    /// Stop all transports
    pub fn stop(self: *Self) void {
        self.running = false;
        self.tcp.stop();
        self.udp.stop();
        self.mcast.stop();
    }

    /// Run the main event loop
    pub fn run(self: *Self) !void {
        while (self.running) {
            try self.pollOnce(100); // 100ms timeout
        }
    }

    /// Poll once for events
    pub fn pollOnce(self: *Self, timeout_ms: i32) !void {
        // Poll TCP
        if (self.config.tcp_enabled) {
            _ = try self.tcp.poll(timeout_ms);
        }
        
        // Poll UDP (non-blocking)
        if (self.config.udp_enabled) {
            _ = try self.udp.poll();
        }
    }

    // ========================================================================
    // Message Handling
    // ========================================================================

    fn onTcpMessage(client_id: cfg.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.processMessage(client_id, message, .tcp);
    }

    fn onUdpMessage(client_id: cfg.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.processMessage(client_id, message, .udp);
    }

    fn onTcpDisconnect(client_id: cfg.ClientId, ctx: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        
        // Cancel all orders for this client
        _ = self.engine.cancelClientOrders(client_id, &self.output);
        self.dispatchOutputs(.tcp);
    }

    const Transport = enum { tcp, udp };

    fn processMessage(self: *Self, client_id: cfg.ClientId, message: *const msg.InputMsg, transport: Transport) void {
        self.output.clear();
        
        // Process through matching engine
        self.engine.processMessage(message, client_id, &self.output);
        self.messages_processed += 1;
        
        // Dispatch outputs
        self.dispatchOutputs(transport);
    }

    fn dispatchOutputs(self: *Self, source_transport: Transport) void {
        const protocol = switch (source_transport) {
            .tcp => self.tcp_protocol,
            .udp => self.udp_protocol,
        };
        
        const encoder = codec.Codec.init(protocol);
        
        for (self.output.slice()) |*out_msg| {
            // Encode message
            const len = encoder.encodeOutput(out_msg, &self.encode_buf) catch continue;
            const data = self.encode_buf[0..len];
            
            // Route based on message type and client_id
            switch (out_msg.msg_type) {
                .trade, .top_of_book => {
                    // Broadcast via multicast
                    if (self.config.mcast_enabled) {
                        _ = self.mcast.publish(out_msg);
                    }
                    
                    // Also send to specific client(s) for trade
                    if (out_msg.msg_type == .trade) {
                        self.sendToClient(out_msg.client_id, data, source_transport);
                    }
                },
                .ack, .cancel_ack, .reject => {
                    // Send only to originating client
                    self.sendToClient(out_msg.client_id, data, source_transport);
                },
            }
        }
    }

    fn sendToClient(self: *Self, client_id: cfg.ClientId, data: []const u8, source_transport: Transport) void {
        if (client_id == cfg.CLIENT_ID_BROADCAST) {
            // Broadcast to all
            self.tcp.broadcast(data);
            return;
        }
        
        if (cfg.isUdpClient(client_id)) {
            // UDP client
            _ = self.udp.send(client_id, data);
        } else {
            // TCP client
            _ = self.tcp.send(client_id, data);
        }
        
        _ = source_transport; // May use for protocol selection
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Server init" {
    const allocator = std.testing.allocator;
    
    var pools = try @import("../core/memory_pool.zig").MemoryPools.init(allocator);
    defer pools.deinit();
    
    var engine = MatchingEngine.init(&pools);
    var server = Server.init(allocator, &engine, cfg.Config{});
    defer server.deinit();
}
