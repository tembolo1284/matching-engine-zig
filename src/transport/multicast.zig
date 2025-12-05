//! Multicast publisher and subscriber for market data distribution.
//!
//! Design:
//! - Publisher sends market data to multicast group
//! - Subscriber receives from multicast group
//! - Sequence numbers for gap detection
//! - Protocol-agnostic (CSV or binary encoding)
//!
//! Usage:
//! ```zig
//! var pub = MulticastPublisher.init();
//! try pub.start("239.255.0.1", 9002, 1);
//! _ = pub.publish(&trade_msg);
//! pub.stop();
//! ```

const std = @import("std");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const net_utils = @import("net_utils.zig");

// ============================================================================
// Constants
// ============================================================================

const SEND_BUFFER_SIZE: u32 = 4096;
const RECV_BUFFER_SIZE: u32 = 4096;

// ============================================================================
// Publisher Statistics
// ============================================================================

pub const PublisherStats = struct {
    messages_sent: u64,
    bytes_sent: u64,
    send_errors: u64,
    current_sequence: u64,
};

// ============================================================================
// Multicast Publisher
// ============================================================================

pub const MulticastPublisher = struct {
    /// Socket file descriptor (null if not started).
    fd: ?posix.fd_t = null,

    /// Destination multicast address.
    dest_addr: posix.sockaddr.in = undefined,

    /// Send buffer for encoding.
    send_buf: [SEND_BUFFER_SIZE]u8 = undefined,

    /// Sequence number for gap detection.
    sequence: u64 = 0,

    /// Protocol for encoding.
    protocol: codec.Protocol = .csv,

    // === Statistics ===
    messages_sent: u64 = 0,
    bytes_sent: u64 = 0,
    send_errors: u64 = 0,

    const Self = @This();

    /// Initialize publisher (not yet connected).
    pub fn init() Self {
        return .{};
    }

    /// Cleanup resources.
    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start publishing to multicast group.
    pub fn start(self: *Self, group: []const u8, port: u16, ttl: u8) !void {
        std.debug.assert(self.fd == null);

        // Create UDP socket
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        errdefer posix.close(fd);

        // Set multicast TTL
        try posix.setsockopt(fd, posix.IPPROTO.IP, posix.IP.MULTICAST_TTL, &[1]u8{ttl});

        // Enable loopback for local testing
        try posix.setsockopt(fd, posix.IPPROTO.IP, posix.IP.MULTICAST_LOOP, &[1]u8{1});

        // Parse and store destination address
        self.dest_addr = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = try net_utils.parseIPv4(group),
        };

        self.fd = fd;
        self.sequence = 0;

        std.log.info("Multicast publisher started: {s}:{} (TTL={})", .{ group, port, ttl });
    }

    /// Stop publishing.
    pub fn stop(self: *Self) void {
        if (self.fd) |fd| {
            posix.close(fd);
            self.fd = null;
            std.log.info("Multicast publisher stopped (sent {} messages)", .{self.messages_sent});
        }
    }

    /// Check if publisher is active.
    pub fn isActive(self: *const Self) bool {
        return self.fd != null;
    }

    /// Publish a message to the multicast group.
    pub fn publish(self: *Self, message: *const msg.OutputMsg) bool {
        const fd = self.fd orelse return false;

        // Encode message
        const len = switch (self.protocol) {
            .csv => csv_codec.encodeOutput(message, &self.send_buf) catch {
                self.send_errors += 1;
                return false;
            },
            .binary => binary_codec.encodeOutput(message, &self.send_buf) catch {
                self.send_errors += 1;
                return false;
            },
            else => {
                self.send_errors += 1;
                return false;
            },
        };

        // Send to multicast group
        const dest_ptr: *const posix.sockaddr = @ptrCast(&self.dest_addr);
        const sent = posix.sendto(
            fd,
            self.send_buf[0..len],
            0,
            dest_ptr,
            @sizeOf(@TypeOf(self.dest_addr)),
        ) catch {
            self.send_errors += 1;
            return false;
        };

        self.sequence += 1;
        self.messages_sent += 1;
        self.bytes_sent += sent;

        return true;
    }

    /// Set encoding protocol.
    pub fn setProtocol(self: *Self, protocol: codec.Protocol) void {
        std.debug.assert(protocol == .csv or protocol == .binary);
        self.protocol = protocol;
    }

    /// Get statistics.
    pub fn getStats(self: *const Self) PublisherStats {
        return .{
            .messages_sent = self.messages_sent,
            .bytes_sent = self.bytes_sent,
            .send_errors = self.send_errors,
            .current_sequence = self.sequence,
        };
    }
};

// ============================================================================
// Subscriber Statistics
// ============================================================================

pub const SubscriberStats = struct {
    messages_received: u64,
    bytes_received: u64,
    gaps_detected: u64,
    last_sequence: u64,
};

// ============================================================================
// Multicast Subscriber
// ============================================================================

pub const MulticastSubscriber = struct {
    /// Socket file descriptor (null if not started).
    fd: ?posix.fd_t = null,

    /// Receive buffer.
    recv_buf: [RECV_BUFFER_SIZE]u8 = undefined,

    /// Last received sequence for gap detection.
    last_sequence: u64 = 0,

    /// Whether we've received first message (for gap detection).
    first_received: bool = false,

    // === Statistics ===
    messages_received: u64 = 0,
    bytes_received: u64 = 0,
    gaps_detected: u64 = 0,

    const Self = @This();

    /// Initialize subscriber (not yet connected).
    pub fn init() Self {
        return .{};
    }

    /// Cleanup resources.
    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start receiving from multicast group.
    pub fn start(self: *Self, group: []const u8, port: u16) !void {
        std.debug.assert(self.fd == null);

        // Create UDP socket
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        // Allow address reuse
        try net_utils.setReuseAddr(fd);

        // Bind to port
        const bind_addr = try net_utils.parseSockAddr("0.0.0.0", port);
        try posix.bind(fd, @ptrCast(&bind_addr), @sizeOf(@TypeOf(bind_addr)));

        // Join multicast group
        const group_addr = try net_utils.parseIPv4(group);
        const mreq = extern struct {
            multiaddr: u32,
            interface: u32,
        }{
            .multiaddr = group_addr,
            .interface = 0, // INADDR_ANY
        };
        try posix.setsockopt(fd, posix.IPPROTO.IP, posix.IP.ADD_MEMBERSHIP, std.mem.asBytes(&mreq));

        self.fd = fd;
        self.first_received = false;

        std.log.info("Multicast subscriber joined: {s}:{}", .{ group, port });
    }

    /// Stop receiving.
    pub fn stop(self: *Self) void {
        if (self.fd) |fd| {
            posix.close(fd);
            self.fd = null;
            std.log.info("Multicast subscriber stopped (received {} messages, {} gaps)", .{
                self.messages_received,
                self.gaps_detected,
            });
        }
    }

    /// Check if subscriber is active.
    pub fn isActive(self: *const Self) bool {
        return self.fd != null;
    }

    /// Receive next message (non-blocking).
    /// Returns null if no message available.
    pub fn receive(self: *Self) ?[]const u8 {
        const fd = self.fd orelse return null;

        const n = posix.recv(fd, &self.recv_buf, 0) catch |err| {
            if (net_utils.isWouldBlock(err)) return null;
            std.log.warn("Multicast recv error: {}", .{err});
            return null;
        };

        if (n == 0) return null;

        self.messages_received += 1;
        self.bytes_received += n;

        return self.recv_buf[0..n];
    }

    /// Record received sequence number and detect gaps.
    pub fn recordSequence(self: *Self, seq: u64) void {
        if (!self.first_received) {
            self.first_received = true;
            self.last_sequence = seq;
            return;
        }

        const expected = self.last_sequence + 1;
        if (seq != expected and seq > self.last_sequence) {
            const gap_size = seq - self.last_sequence - 1;
            self.gaps_detected += gap_size;
            std.log.warn("Multicast gap detected: expected {}, got {} ({} missing)", .{
                expected,
                seq,
                gap_size,
            });
        }

        if (seq > self.last_sequence) {
            self.last_sequence = seq;
        }
    }

    /// Get statistics.
    pub fn getStats(self: *const Self) SubscriberStats {
        return .{
            .messages_received = self.messages_received,
            .bytes_received = self.bytes_received,
            .gaps_detected = self.gaps_detected,
            .last_sequence = self.last_sequence,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MulticastPublisher lifecycle" {
    var pub = MulticastPublisher.init();
    defer pub.deinit();

    try std.testing.expect(!pub.isActive());

    // Note: Actually starting requires network access
    // This just tests the init/deinit cycle
}

test "MulticastSubscriber gap detection" {
    var sub = MulticastSubscriber.init();

    // First message
    sub.recordSequence(100);
    try std.testing.expectEqual(@as(u64, 0), sub.gaps_detected);

    // Sequential
    sub.recordSequence(101);
    try std.testing.expectEqual(@as(u64, 0), sub.gaps_detected);

    // Gap of 2
    sub.recordSequence(104);
    try std.testing.expectEqual(@as(u64, 2), sub.gaps_detected);

    // Out of order (late arrival) - shouldn't count as gap
    sub.recordSequence(102);
    try std.testing.expectEqual(@as(u64, 2), sub.gaps_detected);
}
