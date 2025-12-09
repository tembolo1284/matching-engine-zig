//! Bidirectional UDP server for ultra-low latency trading.
//!
//! Features:
//! - Connectionless request/response
//! - Client address tracking for response routing with O(1) hash lookup
//! - Protocol auto-detection per client (binary vs CSV)
//! - LRU eviction for client table
//! - Large kernel buffers to prevent packet loss
//! - sendmmsg batching on Linux for reduced syscall overhead
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
// Platform Detection
// ============================================================================

const is_linux = builtin.os.tag == .linux;

// ============================================================================
// Configuration
// ============================================================================

const RECV_BUFFER_SIZE: u32 = 65536;

/// Maximum UDP clients. Must be power of 2 for hash table efficiency.
const MAX_UDP_CLIENTS: u32 = 4096;

/// Hash table size (2x clients for good load factor).
const HASH_TABLE_SIZE: u32 = MAX_UDP_CLIENTS * 2;

/// Kernel socket buffer sizes.
/// macOS default is ~256KB, Linux default varies.
/// We request 8MB to handle burst traffic without drops.
const SOCKET_RECV_BUF_SIZE: u32 = 8 * 1024 * 1024;
const SOCKET_SEND_BUF_SIZE: u32 = 4 * 1024 * 1024;

/// Maximum packets to batch in sendmmsg (Linux only).
const MAX_SENDMMSG_BATCH: usize = 64;

// Compile-time validation
comptime {
    std.debug.assert(MAX_UDP_CLIENTS > 0);
    std.debug.assert((MAX_UDP_CLIENTS & (MAX_UDP_CLIENTS - 1)) == 0); // Power of 2
    std.debug.assert(HASH_TABLE_SIZE >= MAX_UDP_CLIENTS);
}

// ============================================================================
// Protocol Detection
// ============================================================================

/// Protocol type for client communication.
pub const Protocol = enum {
    binary,
    csv,
    unknown,
};

// ============================================================================
// Client Tracking with O(1) Hash Lookup
// ============================================================================

const UdpClientEntry = struct {
    addr: config.UdpClientAddr,
    client_id: config.ClientId,
    last_seen: i64,
    protocol: Protocol = .unknown,
    active: bool = false,
};

/// Hash map for UDP client address → client ID mapping.
/// Uses open addressing with linear probing for cache-friendly lookups.
const UdpClientMap = struct {
    /// Client entries (hash table with open addressing).
    entries: [HASH_TABLE_SIZE]UdpClientEntry = undefined,

    /// Active client count.
    count: u32 = 0,

    /// Next client ID to assign.
    next_id: config.ClientId = config.CLIENT_ID_UDP_BASE + 1,

    const Self = @This();

    fn init() Self {
        @setEvalBranchQuota(20000);
        var self = Self{};
        for (&self.entries) |*entry| {
            entry.active = false;
        }
        return self;
    }

    /// Hash function for UDP address.
    fn hashAddr(addr: config.UdpClientAddr) u32 {
        // FNV-1a inspired hash combining addr and port
        var h: u32 = 2166136261;
        h ^= addr.addr;
        h *%= 16777619;
        h ^= addr.port;
        h *%= 16777619;
        return h;
    }

    /// Find slot for address (existing or empty).
    /// Returns index and whether it's an existing entry.
    fn findSlot(self: *Self, addr: config.UdpClientAddr) struct { idx: u32, exists: bool } {
        const hash = hashAddr(addr);
        var idx = hash & (HASH_TABLE_SIZE - 1);
        var first_empty: ?u32 = null;

        // Linear probing
        var probes: u32 = 0;
        while (probes < HASH_TABLE_SIZE) : (probes += 1) {
            const entry = &self.entries[idx];

            if (entry.active) {
                if (entry.addr.eql(addr)) {
                    return .{ .idx = idx, .exists = true };
                }
            } else {
                if (first_empty == null) {
                    first_empty = idx;
                }
                // In open addressing, we can stop at first empty if no tombstones
                // Since we don't use tombstones, first empty means not found
                break;
            }

            idx = (idx + 1) & (HASH_TABLE_SIZE - 1);
        }

        // Not found, return first empty slot
        return .{ .idx = first_empty orelse 0, .exists = false };
    }

    /// Get or create client ID for address. O(1) average case.
    fn getOrCreate(self: *Self, addr: config.UdpClientAddr) config.ClientId {
        const now = std.time.timestamp();
        const slot = self.findSlot(addr);

        if (slot.exists) {
            // Update last seen
            self.entries[slot.idx].last_seen = now;
            return self.entries[slot.idx].client_id;
        }

        // Need to create new entry
        if (self.count >= MAX_UDP_CLIENTS) {
            // Table full - evict oldest entry
            self.evictOldest();
        }

        // Insert new entry
        const entry = &self.entries[slot.idx];
        entry.* = .{
            .addr = addr,
            .client_id = self.allocateId(),
            .last_seen = now,
            .protocol = .unknown,
            .active = true,
        };
        self.count += 1;

        return entry.client_id;
    }

    /// Evict oldest (LRU) entry.
    fn evictOldest(self: *Self) void {
        var oldest_idx: u32 = 0;
        var oldest_time: i64 = std.math.maxInt(i64);

        for (self.entries, 0..) |entry, i| {
            if (entry.active and entry.last_seen < oldest_time) {
                oldest_time = entry.last_seen;
                oldest_idx = @intCast(i);
            }
        }

        if (self.entries[oldest_idx].active) {
            self.entries[oldest_idx].active = false;
            self.count -= 1;

            // Note: With open addressing, we'd normally use tombstones.
            // For simplicity, we accept that this may require rehashing.
            // In practice, eviction is rare with reasonable MAX_UDP_CLIENTS.
        }
    }

    /// Find entry by client ID. O(n) but rarely called (only for send).
    fn findByClientId(self: *Self, client_id: config.ClientId) ?*UdpClientEntry {
        for (&self.entries) |*entry| {
            if (entry.active and entry.client_id == client_id) {
                return entry;
            }
        }
        return null;
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

    /// Get protocol for client ID.
    fn getProtocol(self: *const Self, client_id: config.ClientId) Protocol {
        for (self.entries) |entry| {
            if (entry.active and entry.client_id == client_id) {
                return entry.protocol;
            }
        }
        return .unknown;
    }

    /// Set protocol for address. O(1) average.
    fn setProtocolForAddr(self: *Self, addr: config.UdpClientAddr, protocol: Protocol) void {
        const slot = self.findSlot(addr);
        if (slot.exists) {
            const entry = &self.entries[slot.idx];
            // Only set if unknown (first packet determines protocol)
            if (entry.protocol == .unknown) {
                entry.protocol = protocol;
            }
        }
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
    sendmmsg_calls: u64,
    hash_collisions: u64,
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
    sendmmsg_calls: u64 = 0,

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

            // Get client ID (O(1) hash lookup)
            const client_addr = config.UdpClientAddr{
                .addr = self.last_recv_addr.addr,
                .port = self.last_recv_addr.port,
            };
            const client_id = self.clients.getOrCreate(client_addr);

            // Process packet (also detects and stores protocol)
            self.processPacket(self.recv_buf[0..n], client_id, client_addr);
        }

        return count;
    }

    /// Get protocol for a client.
    pub fn getClientProtocol(self: *const Self, client_id: config.ClientId) Protocol {
        return self.clients.getProtocol(client_id);
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

    fn processPacket(self: *Self, data: []const u8, client_id: config.ClientId, client_addr: config.UdpClientAddr) void {
        // Detect protocol from raw data BEFORE decoding using codec's detection
        const codec_protocol = codec.detectProtocol(data);
        const detected_protocol: Protocol = switch (codec_protocol) {
            .binary => .binary,
            .csv => .csv,
            else => .unknown,
        };
        self.clients.setProtocolForAddr(client_addr, detected_protocol);

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
            .sendmmsg_calls = self.sendmmsg_calls,
            .hash_collisions = 0, // Could track if needed
        };
    }
};

// ============================================================================
// Batch Sender (for future sendmmsg optimization)
// ============================================================================

/// Batch sender for sending multiple packets efficiently.
/// On Linux, uses sendmmsg to reduce syscall overhead.
/// On other platforms, falls back to individual sendto calls.
///
/// SAFETY: Data pointers passed to add() MUST remain valid until flush() is called.
/// The batch sender stores raw pointers and does NOT copy data.
pub const BatchSender = struct {
    server: *UdpServer,

    // Batch buffers (Linux sendmmsg)
    addrs: [MAX_SENDMMSG_BATCH]posix.sockaddr.in,
    iovecs: [MAX_SENDMMSG_BATCH]std.posix.iovec_const,
    count: usize,

    const Self = @This();

    pub fn init(server: *UdpServer) Self {
        return .{
            .server = server,
            .addrs = undefined,
            .iovecs = undefined,
            .count = 0,
        };
    }

    /// Add a packet to the batch.
    ///
    /// SAFETY: `data` must remain valid and unchanged until flush() is called.
    /// The batch sender stores a raw pointer to data, not a copy.
    pub fn add(self: *Self, client_id: config.ClientId, data: []const u8) void {
        const addr = self.server.clients.findAddr(client_id) orelse return;

        if (self.count >= MAX_SENDMMSG_BATCH) {
            self.flush();
        }

        self.addrs[self.count] = .{
            .family = posix.AF.INET,
            .port = addr.port,
            .addr = addr.addr,
        };
        self.iovecs[self.count] = .{
            .base = data.ptr,
            .len = data.len,
        };
        self.count += 1;
    }

    /// Flush all pending packets.
    pub fn flush(self: *Self) void {
        if (self.count == 0) return;

        const fd = self.server.fd orelse return;

        if (is_linux) {
            self.flushLinux(fd);
        } else {
            self.flushFallback(fd);
        }

        self.count = 0;
    }

    fn flushLinux(self: *Self, fd: posix.fd_t) void {
        // Build mmsghdr array
        var msghdrs: [MAX_SENDMMSG_BATCH]std.os.linux.mmsghdr_const = undefined;

        for (0..self.count) |i| {
            msghdrs[i] = .{
                .msg_hdr = .{
                    .name = @ptrCast(&self.addrs[i]),
                    .namelen = @sizeOf(posix.sockaddr.in),
                    .iov = @ptrCast(&self.iovecs[i]),
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                },
                .msg_len = 0,
            };
        }

        const sent = std.os.linux.sendmmsg(fd, &msghdrs, self.count, 0);
        if (sent > 0) {
            self.server.packets_sent += sent;
            self.server.sendmmsg_calls += 1;

            // Count bytes sent
            for (0..sent) |i| {
                self.server.bytes_sent += msghdrs[i].msg_len;
            }
        }

        // Count errors for unsent packets
        if (sent < self.count) {
            self.server.send_errors += self.count - sent;
        }
    }

    fn flushFallback(self: *Self, fd: posix.fd_t) void {
        for (0..self.count) |i| {
            const sent = posix.sendto(
                fd,
                @ptrCast(self.iovecs[i].base),
                0,
                @ptrCast(&self.addrs[i]),
                @sizeOf(posix.sockaddr.in),
            ) catch {
                self.server.send_errors += 1;
                continue;
            };

            self.server.packets_sent += 1;
            self.server.bytes_sent += sent;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "UdpClientMap hash lookup" {
    var map = UdpClientMap.init();

    const addr1 = config.UdpClientAddr.init(0x0100007F, 1234);
    const addr2 = config.UdpClientAddr.init(0x0100007F, 1235);
    const addr3 = config.UdpClientAddr.init(0x0200007F, 1234);

    // First lookup creates
    const id1 = map.getOrCreate(addr1);
    try std.testing.expectEqual(@as(u32, 1), map.count);

    // Second lookup returns same
    const id1_again = map.getOrCreate(addr1);
    try std.testing.expectEqual(id1, id1_again);
    try std.testing.expectEqual(@as(u32, 1), map.count);

    // Different address creates new
    const id2 = map.getOrCreate(addr2);
    try std.testing.expect(id1 != id2);
    try std.testing.expectEqual(@as(u32, 2), map.count);

    // Third address
    const id3 = map.getOrCreate(addr3);
    try std.testing.expect(id1 != id3);
    try std.testing.expect(id2 != id3);
    try std.testing.expectEqual(@as(u32, 3), map.count);

    // All are UDP clients
    try std.testing.expect(config.isUdpClient(id1));
    try std.testing.expect(config.isUdpClient(id2));
    try std.testing.expect(config.isUdpClient(id3));
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

test "UdpClientMap protocol tracking" {
    var map = UdpClientMap.init();

    const addr = config.UdpClientAddr.init(0x0100007F, 8080);
    const id = map.getOrCreate(addr);

    // Initially unknown
    try std.testing.expectEqual(Protocol.unknown, map.getProtocol(id));

    // Set to binary
    map.setProtocolForAddr(addr, .binary);
    try std.testing.expectEqual(Protocol.binary, map.getProtocol(id));

    // Can't change once set
    map.setProtocolForAddr(addr, .csv);
    try std.testing.expectEqual(Protocol.binary, map.getProtocol(id));
}

test "UdpClientMap hash distribution" {
    // Verify hash function produces different values
    const addr1 = config.UdpClientAddr.init(0x0100007F, 1234);
    const addr2 = config.UdpClientAddr.init(0x0100007F, 1235);
    const addr3 = config.UdpClientAddr.init(0x0200007F, 1234);

    const h1 = UdpClientMap.hashAddr(addr1);
    const h2 = UdpClientMap.hashAddr(addr2);
    const h3 = UdpClientMap.hashAddr(addr3);

    try std.testing.expect(h1 != h2);
    try std.testing.expect(h1 != h3);
    try std.testing.expect(h2 != h3);
}
