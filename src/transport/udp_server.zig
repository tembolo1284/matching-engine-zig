//! Bidirectional UDP server for ultra-low latency trading.
//!
//! Features:
//! - Connectionless request/response
//! - Client address tracking for response routing
//! - Protocol auto-detection per packet
//! - LRU eviction for client table
//! - Large kernel buffers to prevent packet loss
//!
//! Thread Safety:
//! - NOT thread-safe. Use from I/O thread only.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const config = @import("config.zig");
const net_utils = @import("net_utils.zig");

// ============================================================================
// Configuration
// ============================================================================

const RECV_BUFFER_SIZE: u32 = 65536;
const MAX_UDP_CLIENTS: u32 = 4096;

/// Kernel socket buffer sizes
/// macOS default is ~256KB, Linux default varies
/// We request 8MB to handle burst traffic without drops
const SOCKET_RECV_BUF_SIZE: u32 = 8 * 1024 * 1024; // 8MB
const SOCKET_SEND_BUF_SIZE: u32 = 4 * 1024 * 1024; // 4MB

// ============================================================================
// Client Tracking
// ============================================================================

const UdpClientEntry = struct {
    addr: config.UdpClientAddr,
    client_id: config.ClientId,
    last_seen: i64,
    active: bool = false,
};

/// Hash map for UDP client address → client ID mapping.
const UdpClientMap = struct {
    entries: [MAX_UDP_CLIENTS]UdpClientEntry = undefined,
    count: u32 = 0,
    next_id: config.ClientId = config.CLIENT_ID_UDP_BASE + 1,

    const Self = @This();

    fn init() Self {
        @setEvalBranchQuota(50000);
        var self = Self{};
        for (&self.entries) |*entry| {
            entry.active = false;
        }
        return self;
    }

    /// Get or create client ID for address.
    fn getOrCreate(self: *Self, addr: config.UdpClientAddr) config.ClientId {
        const now = std.time.timestamp();

        // Search existing
        for (&self.entries) |*entry| {
            if (entry.active and entry.addr.eql(addr)) {
                entry.last_seen = now;
                return entry.client_id;
            }
        }

        // Find free slot
        for (&self.entries) |*entry| {
            if (!entry.active) {
                entry.* = .{
                    .addr = addr,
                    .client_id = self.allocateId(),
                    .last_seen = now,
                    .active = true,
                };
                self.count += 1;
                return entry.client_id;
            }
        }

        // Evict oldest (LRU)
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
            .client_id = self.allocateId(),
            .last_seen = now,
            .active = true,
        };
        return self.entries[oldest_idx].client_id;
    }

    /// Find address by client ID.
    fn findAddr(self: *const Self, client_id: config.ClientId) ?config.UdpClientAddr {
        for (self.entries) |entry| {
            if (entry.active and entry.client_id == client_id) {
                return entry.addr;
            }
        }
        return null;
    }

    fn allocateId(self: *Self) config.ClientId {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id < config.CLIENT_ID_UDP_BASE) {
            self.next_id = config.CLIENT_ID_UDP_BASE + 1;
        }
        return id;
    }
};

// ============================================================================
// Server Statistics
// ============================================================================

pub const UdpServerStats = struct {
    packets_received: u64,
    packets_sent: u64,
    bytes_received: u64,
    bytes_sent: u64,
    decode_errors: u64,
    send_errors: u64,
    active_clients: u32,
};

// ============================================================================
// UDP Server
// ============================================================================

pub const UdpServer = struct {
    /// Socket file descriptor.
    fd: ?posix.fd_t = null,

    /// Receive buffer.
    recv_buf: [RECV_BUFFER_SIZE]u8 = undefined,

    /// Send buffer.
    send_buf: [RECV_BUFFER_SIZE]u8 = undefined,

    /// Client tracking for response routing.
    clients: UdpClientMap = UdpClientMap.init(),

    /// Last received address (for fast response).
    last_recv_addr: posix.sockaddr.in = undefined,
    last_recv_len: posix.socklen_t = 0,

    /// Message callback.
    on_message: ?*const fn (
        client_id: config.ClientId,
        message: *const msg.InputMsg,
        ctx: ?*anyopaque,
    ) void = null,
    callback_ctx: ?*anyopaque = null,

    // === Statistics ===
    packets_received: u64 = 0,
    packets_sent: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    decode_errors: u64 = 0,
    send_errors: u64 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start listening on address:port.
    pub fn start(self: *Self, address: []const u8, port: u16) !void {
        std.debug.assert(self.fd == null);

        // Create UDP socket
        const fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK,
            0,
        );
        errdefer posix.close(fd);

        // Set socket options
        try net_utils.setReuseAddr(fd);
        
        // Set large kernel buffers to prevent packet loss under load
        const actual_recv = net_utils.setBufferSizes(fd, SOCKET_RECV_BUF_SIZE, SOCKET_SEND_BUF_SIZE);
        
        std.log.info("UDP socket buffers: requested recv={d}KB, actual={d}KB", .{
            SOCKET_RECV_BUF_SIZE / 1024,
            actual_recv / 1024,
        });

        // Bind
        const addr = try net_utils.parseSockAddr(address, port);
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

        self.fd = fd;
        std.log.info("UDP server listening on {s}:{}", .{ address, port });
    }

    /// Stop the server.
    pub fn stop(self: *Self) void {
        if (self.fd) |fd| {
            posix.close(fd);
            self.fd = null;
            std.log.info("UDP server stopped (received {} packets)", .{self.packets_received});
        }
    }

    /// Check if server is running.
    pub fn isRunning(self: *const Self) bool {
        return self.fd != null;
    }

    /// Poll for incoming packets (non-blocking).
    pub fn poll(self: *Self) !usize {
        const fd = self.fd orelse return 0;
        var count: usize = 0;

        while (true) {
            self.last_recv_len = @sizeOf(@TypeOf(self.last_recv_addr));

            const n = posix.recvfrom(
                fd,
                &self.recv_buf,
                0,
                @ptrCast(&self.last_recv_addr),
                &self.last_recv_len,
            ) catch |err| {
                if (net_utils.isWouldBlock(err)) break;
                return err;
            };

            if (n == 0) continue;

            self.packets_received += 1;
            self.bytes_received += n;
            count += 1;

            // Get client ID
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

    /// Send to client by ID.
    pub fn send(self: *Self, client_id: config.ClientId, data: []const u8) bool {
        std.debug.assert(config.isUdpClient(client_id));

        const addr = self.clients.findAddr(client_id) orelse {
            self.send_errors += 1;
            return false;
        };

        return self.sendToAddr(addr, data);
    }

    /// Send to last received address (fastest path).
    pub fn sendToLast(self: *Self, data: []const u8) bool {
        if (self.last_recv_len == 0) return false;

        const fd = self.fd orelse return false;

        const sent = posix.sendto(
            fd,
            data,
            0,
            @ptrCast(&self.last_recv_addr),
            self.last_recv_len,
        ) catch {
            self.send_errors += 1;
            return false;
        };

        self.packets_sent += 1;
        self.bytes_sent += sent;
        return true;
    }

    /// Send to specific address.
    pub fn sendToAddr(self: *Self, addr: config.UdpClientAddr, data: []const u8) bool {
        const fd = self.fd orelse return false;

        var sock_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = addr.port,
            .addr = addr.addr,
        };

        const sent = posix.sendto(
            fd,
            data,
            0,
            @ptrCast(&sock_addr),
            @sizeOf(@TypeOf(sock_addr)),
        ) catch {
            self.send_errors += 1;
            return false;
        };

        self.packets_sent += 1;
        self.bytes_sent += sent;
        return true;
    }

    /// Get socket fd for external polling.
    pub fn getFd(self: *const Self) ?posix.fd_t {
        return self.fd;
    }

    fn processPacket(self: *Self, data: []const u8, client_id: config.ClientId) void {
        const result = codec.Codec.decodeInput(data) catch |err| {
            self.decode_errors += 1;
            std.log.debug("UDP decode error: {}", .{err});
            return;
        };

        if (self.on_message) |callback| {
            callback(client_id, &result.message, self.callback_ctx);
        }
    }

    /// Get statistics.
    pub fn getStats(self: *const Self) UdpServerStats {
        return .{
            .packets_received = self.packets_received,
            .packets_sent = self.packets_sent,
            .bytes_received = self.bytes_received,
            .bytes_sent = self.bytes_sent,
            .decode_errors = self.decode_errors,
            .send_errors = self.send_errors,
            .active_clients = self.clients.count,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "UdpClientMap get or create" {
    var map = UdpClientMap.init();

    const addr1 = config.UdpClientAddr.init(0x0100007F, 1234);
    const addr2 = config.UdpClientAddr.init(0x0100007F, 1235);

    const id1 = map.getOrCreate(addr1);
    const id2 = map.getOrCreate(addr2);
    const id1_again = map.getOrCreate(addr1);

    try std.testing.expect(id1 != id2);
    try std.testing.expectEqual(id1, id1_again);
    try std.testing.expect(config.isUdpClient(id1));
    try std.testing.expect(config.isUdpClient(id2));
}

test "UdpClientMap find addr" {
    var map = UdpClientMap.init();

    const addr = config.UdpClientAddr.init(0x0100007F, 8080);
    const id = map.getOrCreate(addr);

    const found = map.findAddr(id);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.eql(addr));

    // Unknown ID
    try std.testing.expect(map.findAddr(99999) == null);
}
