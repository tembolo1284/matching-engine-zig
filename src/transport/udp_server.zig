//! Bidirectional UDP server for ultra-low latency trading.
//!
//! Features:
//! - Tracks client addresses for response routing
//! - No connection state - pure request/response
//! - Protocol auto-detection per packet
//! - Optional client address caching for repeated interactions

const std = @import("std");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const config = @import("config.zig");

// ============================================================================
// Constants
// ============================================================================

const RECV_BUFFER_SIZE = 65536;
const MAX_UDP_CLIENTS = 4096;

// ============================================================================
// UDP Client Tracking
// ============================================================================

/// Tracks recent UDP clients for response routing
const UdpClientEntry = struct {
    addr: config.UdpClientAddr,
    client_id: config.ClientId,
    last_seen: i64, // Timestamp
    active: bool = false,
};

const UdpClientMap = struct {
    entries: [MAX_UDP_CLIENTS]UdpClientEntry = [_]UdpClientEntry{.{
        .addr = .{ .addr = 0, .port = 0 },
        .client_id = 0,
        .last_seen = 0,
    }} ** MAX_UDP_CLIENTS,
    count: usize = 0,
    next_id: config.ClientId = config.CLIENT_ID_UDP_BASE + 1,

    const Self = @This();

    /// Get or create client ID for address
    fn getOrCreate(self: *Self, addr: config.UdpClientAddr) config.ClientId {
        // Search existing
        for (&self.entries) |*entry| {
            if (entry.active and entry.addr.addr == addr.addr and entry.addr.port == addr.port) {
                entry.last_seen = std.time.timestamp();
                return entry.client_id;
            }
        }
        
        // Create new
        for (&self.entries) |*entry| {
            if (!entry.active) {
                entry.addr = addr;
                entry.client_id = self.next_id;
                entry.last_seen = std.time.timestamp();
                entry.active = true;
                
                self.next_id +%= 1;
                if (self.next_id < config.CLIENT_ID_UDP_BASE) {
                    self.next_id = config.CLIENT_ID_UDP_BASE + 1;
                }
                self.count += 1;
                
                return entry.client_id;
            }
        }
        
        // Table full - evict oldest
        var oldest_idx: usize = 0;
        var oldest_time: i64 = std.math.maxInt(i64);
        for (self.entries, 0..) |entry, i| {
            if (entry.active and entry.last_seen < oldest_time) {
                oldest_time = entry.last_seen;
                oldest_idx = i;
            }
        }
        
        self.entries[oldest_idx] = .{
            .addr = addr,
            .client_id = self.next_id,
            .last_seen = std.time.timestamp(),
            .active = true,
        };
        self.next_id +%= 1;
        
        return self.entries[oldest_idx].client_id;
    }

    /// Find address by client ID
    fn findAddr(self: *const Self, client_id: config.ClientId) ?config.UdpClientAddr {
        for (self.entries) |entry| {
            if (entry.active and entry.client_id == client_id) {
                return entry.addr;
            }
        }
        return null;
    }
};

// ============================================================================
// UDP Server
// ============================================================================

pub const UdpServer = struct {
    fd: posix.fd_t = -1,
    
    recv_buf: [RECV_BUFFER_SIZE]u8 = undefined,
    send_buf: [RECV_BUFFER_SIZE]u8 = undefined,
    
    // Client tracking for responses
    clients: UdpClientMap = .{},
    
    // Last received address (for immediate response)
    last_recv_addr: posix.sockaddr.in = undefined,
    last_recv_addr_len: posix.socklen_t = 0,
    
    // Callback for processing messages
    on_message: ?*const fn (client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void = null,
    callback_ctx: ?*anyopaque = null,
    
    // Statistics
    packets_received: u64 = 0,
    packets_sent: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    decode_errors: u64 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start listening on the specified address and port
    pub fn start(self: *Self, address: []const u8, port: u16) !void {
        // Create UDP socket
        self.fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(self.fd);
        
        // Set socket options
        try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        
        // Increase buffer sizes for burst handling
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, 1024 * 1024))) catch {};
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 1024 * 1024))) catch {};
        
        // Bind
        var addr = try parseAddress(address, port);
        try posix.bind(self.fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        
        std.log.info("UDP server listening on {s}:{}", .{ address, port });
    }

    /// Stop the server
    pub fn stop(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }
    }

    /// Poll for incoming packets (non-blocking)
    /// Returns number of packets processed
    pub fn poll(self: *Self) !usize {
        var count: usize = 0;
        
        while (true) {
            self.last_recv_addr_len = @sizeOf(@TypeOf(self.last_recv_addr));
            
            const n = posix.recvfrom(
                self.fd,
                &self.recv_buf,
                0,
                @ptrCast(&self.last_recv_addr),
                &self.last_recv_addr_len,
            ) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };
            
            if (n == 0) continue;
            
            self.packets_received += 1;
            self.bytes_received += n;
            count += 1;
            
            // Get/create client ID for this address
            const client_addr = config.UdpClientAddr{
                .addr = self.last_recv_addr.addr,
                .port = self.last_recv_addr.port,
            };
            const client_id = self.clients.getOrCreate(client_addr);
            
            // Process packet
            self.processPacket(self.recv_buf[0..n], client_id);
        }
        
        return count;
    }

    /// Send response to specific client
    pub fn send(self: *Self, client_id: config.ClientId, data: []const u8) bool {
        const addr = self.clients.findAddr(client_id) orelse return false;
        return self.sendToAddr(addr, data);
    }

    /// Send to last received address (fastest path)
    pub fn sendToLast(self: *Self, data: []const u8) bool {
        if (self.last_recv_addr_len == 0) return false;
        
        const sent = posix.sendto(
            self.fd,
            data,
            0,
            @ptrCast(&self.last_recv_addr),
            self.last_recv_addr_len,
        ) catch return false;
        
        self.packets_sent += 1;
        self.bytes_sent += sent;
        return true;
    }

    /// Send to specific address
    pub fn sendToAddr(self: *Self, addr: config.UdpClientAddr, data: []const u8) bool {
        var sock_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = addr.port,
            .addr = addr.addr,
        };
        
        const sent = posix.sendto(
            self.fd,
            data,
            0,
            @ptrCast(&sock_addr),
            @sizeOf(@TypeOf(sock_addr)),
        ) catch return false;
        
        self.packets_sent += 1;
        self.bytes_sent += sent;
        return true;
    }

    /// Get socket fd for epoll integration
    pub fn getFd(self: *const Self) posix.fd_t {
        return self.fd;
    }

    // ========================================================================
    // Private Methods
    // ========================================================================

    fn processPacket(self: *Self, data: []const u8, client_id: config.ClientId) void {
        // Decode message (auto-detect protocol)
        const result = codec.Codec.decodeInput(data) catch |err| {
            self.decode_errors += 1;
            std.log.debug("UDP decode error: {}", .{err});
            return;
        };
        
        // Dispatch to callback
        if (self.on_message) |callback| {
            callback(client_id, &result.message, self.callback_ctx);
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn parseAddress(address: []const u8, port: u16) !posix.sockaddr.in {
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
    };
    
    if (std.mem.eql(u8, address, "0.0.0.0")) {
        addr.addr = 0;
    } else {
        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, address, '.');
        var i: usize = 0;
        while (iter.next()) |part| : (i += 1) {
            if (i >= 4) return error.InvalidAddress;
            parts[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
        }
        if (i != 4) return error.InvalidAddress;
        addr.addr = @bitCast(parts);
    }
    
    return addr;
}

// ============================================================================
// Tests
// ============================================================================

test "UdpClientMap get or create" {
    var map = UdpClientMap{};
    
    const addr1 = config.UdpClientAddr{ .addr = 0x0100007F, .port = 1234 };
    const addr2 = config.UdpClientAddr{ .addr = 0x0100007F, .port = 1235 };
    
    const id1 = map.getOrCreate(addr1);
    const id2 = map.getOrCreate(addr2);
    const id1_again = map.getOrCreate(addr1);
    
    try std.testing.expect(id1 != id2);
    try std.testing.expectEqual(id1, id1_again);
    try std.testing.expect(config.isUdpClient(id1));
}
