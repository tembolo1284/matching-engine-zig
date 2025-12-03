//! Multicast publisher for market data distribution.
//!
//! Features:
//! - Configurable multicast group and TTL
//! - Interface binding for multi-homed hosts
//! - Sequence numbering for gap detection
//! - Optional loopback for local testing

const std = @import("std");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const binary = @import("../protocol/binary_codec.zig");
const config = @import("config.zig");

// ============================================================================
// Constants
// ============================================================================

const SEND_BUFFER_SIZE = 65536;

// ============================================================================
// Multicast Publisher
// ============================================================================

pub const MulticastPublisher = struct {
    fd: posix.fd_t = -1,
    dest_addr: posix.sockaddr.in = undefined,
    
    send_buf: [SEND_BUFFER_SIZE]u8 = undefined,
    
    // Sequence number for gap detection
    sequence: u64 = 0,
    
    // Statistics
    packets_sent: u64 = 0,
    bytes_sent: u64 = 0,
    send_errors: u64 = 0,
    
    // Configuration
    protocol: codec.Protocol = .binary,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start the multicast publisher
    pub fn start(self: *Self, group: []const u8, port: u16, interface: []const u8, ttl: u8) !void {
        // Create UDP socket
        self.fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        errdefer posix.close(self.fd);
        
        // Set TTL
        try posix.setsockopt(self.fd, posix.IPPROTO.IP, posix.IP.MULTICAST_TTL, &[_]u8{ttl});
        
        // Set outgoing interface
        const iface_addr = try parseIpAddress(interface);
        try posix.setsockopt(self.fd, posix.IPPROTO.IP, posix.IP.MULTICAST_IF, &std.mem.toBytes(iface_addr));
        
        // Disable loopback by default (enable for testing)
        try posix.setsockopt(self.fd, posix.IPPROTO.IP, posix.IP.MULTICAST_LOOP, &[_]u8{0});
        
        // Parse destination address
        self.dest_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = try parseIpAddress(group),
        };
        
        std.log.info("Multicast publisher started: {s}:{} (TTL={})", .{ group, port, ttl });
    }

    /// Stop the publisher
    pub fn stop(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }
    }

    /// Enable loopback (for testing)
    pub fn setLoopback(self: *Self, enabled: bool) !void {
        try posix.setsockopt(
            self.fd,
            posix.IPPROTO.IP,
            posix.IP.MULTICAST_LOOP,
            &[_]u8{if (enabled) 1 else 0},
        );
    }

    /// Publish an output message
    pub fn publish(self: *Self, message: *const msg.OutputMsg) bool {
        // Encode message
        const len = switch (self.protocol) {
            .binary => binary.encodeOutput(message, &self.send_buf) catch return false,
            .csv => @import("csv_codec.zig").encodeOutput(message, &self.send_buf) catch return false,
            else => return false,
        };
        
        return self.publishRaw(self.send_buf[0..len]);
    }

    /// Publish raw data
    pub fn publishRaw(self: *Self, data: []const u8) bool {
        const sent = posix.sendto(
            self.fd,
            data,
            0,
            @ptrCast(&self.dest_addr),
            @sizeOf(@TypeOf(self.dest_addr)),
        ) catch {
            self.send_errors += 1;
            return false;
        };
        
        self.packets_sent += 1;
        self.bytes_sent += sent;
        self.sequence += 1;
        
        return true;
    }

    /// Get current sequence number
    pub fn getSequence(self: *const Self) u64 {
        return self.sequence;
    }
};

// ============================================================================
// Multicast Subscriber (for testing/clients)
// ============================================================================

pub const MulticastSubscriber = struct {
    fd: posix.fd_t = -1,
    
    recv_buf: [SEND_BUFFER_SIZE]u8 = undefined,
    
    // Callback for received messages
    on_message: ?*const fn (message: *const msg.OutputMsg, ctx: ?*anyopaque) void = null,
    callback_ctx: ?*anyopaque = null,
    
    // Gap detection
    expected_sequence: u64 = 0,
    gaps_detected: u64 = 0,
    
    // Statistics
    packets_received: u64 = 0,
    bytes_received: u64 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Subscribe to multicast group
    pub fn start(self: *Self, group: []const u8, port: u16, interface: []const u8) !void {
        // Create UDP socket
        self.fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(self.fd);
        
        // Allow address reuse
        try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        
        // Bind to port
        var bind_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0, // INADDR_ANY
        };
        try posix.bind(self.fd, @ptrCast(&bind_addr), @sizeOf(@TypeOf(bind_addr)));
        
        // Join multicast group
        const group_addr = try parseIpAddress(group);
        const iface_addr = try parseIpAddress(interface);
        
        const mreq = extern struct {
            imr_multiaddr: u32,
            imr_interface: u32,
        }{
            .imr_multiaddr = group_addr,
            .imr_interface = iface_addr,
        };
        
        try posix.setsockopt(self.fd, posix.IPPROTO.IP, posix.IP.ADD_MEMBERSHIP, std.mem.asBytes(&mreq));
        
        std.log.info("Subscribed to multicast group {s}:{}", .{ group, port });
    }

    /// Leave multicast group and close
    pub fn stop(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }
    }

    /// Poll for incoming packets
    pub fn poll(self: *Self) !usize {
        var count: usize = 0;
        
        while (true) {
            const n = posix.recv(self.fd, &self.recv_buf, 0) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };
            
            if (n == 0) continue;
            
            self.packets_received += 1;
            self.bytes_received += n;
            count += 1;
            
            // Decode and dispatch
            self.processPacket(self.recv_buf[0..n]);
        }
        
        return count;
    }

    /// Get socket fd for epoll integration
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.fd;
    }

    fn processPacket(self: *Self, data: []const u8) void {
        const result = codec.Codec.decodeOutput(data) catch |err| {
            std.log.debug("Multicast decode error: {}", .{err});
            return;
        };
        
        if (self.on_message) |callback| {
            callback(&result.message, self.callback_ctx);
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn parseIpAddress(address: []const u8) !u32 {
    if (std.mem.eql(u8, address, "0.0.0.0")) {
        return 0;
    }
    
    var parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, address, '.');
    var i: usize = 0;
    while (iter.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidAddress;
        parts[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }
    if (i != 4) return error.InvalidAddress;
    
    return @bitCast(parts);
}

// ============================================================================
// Tests
// ============================================================================

test "parseIpAddress" {
    const addr = try parseIpAddress("239.255.0.1");
    const bytes: [4]u8 = @bitCast(addr);
    try std.testing.expectEqual(@as(u8, 239), bytes[0]);
    try std.testing.expectEqual(@as(u8, 255), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0), bytes[2]);
    try std.testing.expectEqual(@as(u8, 1), bytes[3]);
}
