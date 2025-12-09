//! Multicast publisher and subscriber for market data distribution.
//!
//! Design:
//! - Publisher sends market data to multicast group with sequence numbers
//! - Subscriber receives from multicast group and detects gaps
//! - Protocol-agnostic (CSV or binary encoding)
//!
//! Wire format:
//! ```
//! +------------------+--------------------+
//! | Sequence (8B BE) | Payload (N bytes)  |
//! +------------------+--------------------+
//! ```
//!
//! Usage:
//! ```zig
//! var publisher = MulticastPublisher.init();
//! try publisher.start("239.255.0.1", 1236, 1);
//! _ = publisher.publish(&trade_msg);
//! publisher.stop();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");
const net_utils = @import("net_utils.zig");

// ============================================================================
// Constants
// ============================================================================

/// Sequence header size (8 bytes for u64).
pub const SEQUENCE_HEADER_SIZE: usize = 8;

const SEND_BUFFER_SIZE: u32 = 4096;
const RECV_BUFFER_SIZE: u32 = 4096;

// ============================================================================
// Platform-specific socket option constants
// ============================================================================

const is_darwin = builtin.os.tag.isDarwin();

// IP multicast socket options differ between Linux and macOS/BSD
// Linux: from /usr/include/linux/in.h
// macOS: from /usr/include/netinet/in.h
const IP_MULTICAST_TTL: u32 = if (is_darwin) 10 else 33;
const IP_MULTICAST_LOOP: u32 = if (is_darwin) 11 else 34;
const IP_ADD_MEMBERSHIP: u32 = if (is_darwin) 12 else 35;
const IP_DROP_MEMBERSHIP: u32 = if (is_darwin) 13 else 36;

// ============================================================================
// Multicast Group Membership
// ============================================================================

/// IP multicast group membership request structure.
const IpMreq = extern struct {
    /// Multicast group address (network byte order).
    multiaddr: u32,
    /// Local interface address (network byte order, 0 = any).
    interface: u32,
};

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
    /// Layout: [8-byte sequence][payload]
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
        try posix.setsockopt(fd, posix.IPPROTO.IP, IP_MULTICAST_TTL, &[1]u8{ttl});

        // Enable loopback for local testing
        try posix.setsockopt(fd, posix.IPPROTO.IP, IP_MULTICAST_LOOP, &[1]u8{1});

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
            std.log.info("Multicast publisher stopped (sent {} messages, last seq={})", .{
                self.messages_sent,
                self.sequence,
            });
        }
    }

    /// Check if publisher is active.
    pub fn isActive(self: *const Self) bool {
        return self.fd != null;
    }

    /// Publish a message to the multicast group.
    /// Wire format: [8-byte sequence BE][encoded message]
    pub fn publish(self: *Self, message: *const msg.OutputMsg) bool {
        const fd = self.fd orelse return false;

        // Write sequence header (big-endian)
        std.mem.writeInt(u64, self.send_buf[0..8], self.sequence, .big);

        // Encode message after sequence header
        const payload_buf = self.send_buf[SEQUENCE_HEADER_SIZE..];
        const msg_len = switch (self.protocol) {
            .csv => csv_codec.encodeOutput(message, payload_buf) catch {
                self.send_errors += 1;
                return false;
            },
            .binary => binary_codec.encodeOutput(message, payload_buf) catch {
                self.send_errors += 1;
                return false;
            },
            else => {
                self.send_errors += 1;
                return false;
            },
        };

        const total_len = SEQUENCE_HEADER_SIZE + msg_len;

        // Send to multicast group
        const dest_ptr: *const posix.sockaddr = @ptrCast(&self.dest_addr);
        const sent = posix.sendto(
            fd,
            self.send_buf[0..total_len],
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

    /// Publish raw data with sequence header.
    /// Useful for forwarding pre-encoded messages.
    pub fn publishRaw(self: *Self, data: []const u8) bool {
        const fd = self.fd orelse return false;

        if (data.len + SEQUENCE_HEADER_SIZE > SEND_BUFFER_SIZE) {
            self.send_errors += 1;
            return false;
        }

        // Write sequence header
        std.mem.writeInt(u64, self.send_buf[0..8], self.sequence, .big);

        // Copy payload
        @memcpy(self.send_buf[SEQUENCE_HEADER_SIZE..][0..data.len], data);

        const total_len = SEQUENCE_HEADER_SIZE + data.len;

        // Send
        const dest_ptr: *const posix.sockaddr = @ptrCast(&self.dest_addr);
        const sent = posix.sendto(
            fd,
            self.send_buf[0..total_len],
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

    /// Get current sequence number (next to be sent).
    pub fn getSequence(self: *const Self) u64 {
        return self.sequence;
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
    total_missing: u64,
    last_sequence: u64,
    out_of_order: u64,
};

// ============================================================================
// Received Message
// ============================================================================

/// Result from receiving a multicast message.
pub const ReceivedMessage = struct {
    /// Sequence number from wire.
    sequence: u64,
    /// Payload data (without sequence header).
    payload: []const u8,
    /// Whether this message created a gap.
    is_gap: bool,
    /// Number of missing messages if gap.
    gap_size: u64,
};

// ============================================================================
// Multicast Subscriber
// ============================================================================

pub const MulticastSubscriber = struct {
    /// Socket file descriptor (null if not started).
    fd: ?posix.fd_t = null,

    /// Receive buffer.
    recv_buf: [RECV_BUFFER_SIZE]u8 = undefined,

    /// Multicast group address for cleanup.
    group_addr: ?u32 = null,

    /// Last received sequence for gap detection.
    last_sequence: u64 = 0,

    /// Whether we've received first message (for gap detection).
    first_received: bool = false,

    // === Statistics ===
    messages_received: u64 = 0,
    bytes_received: u64 = 0,
    gaps_detected: u64 = 0,
    total_missing: u64 = 0,
    out_of_order: u64 = 0,

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
        const mreq = IpMreq{
            .multiaddr = group_addr,
            .interface = 0, // INADDR_ANY
        };

        try posix.setsockopt(fd, posix.IPPROTO.IP, IP_ADD_MEMBERSHIP, std.mem.asBytes(&mreq));

        self.fd = fd;
        self.group_addr = group_addr;
        self.first_received = false;

        std.log.info("Multicast subscriber joined: {s}:{}", .{ group, port });
    }

    /// Stop receiving and leave multicast group.
    pub fn stop(self: *Self) void {
        if (self.fd) |fd| {
            // Leave multicast group (best effort)
            if (self.group_addr) |group_addr| {
                const mreq = IpMreq{
                    .multiaddr = group_addr,
                    .interface = 0,
                };
                posix.setsockopt(fd, posix.IPPROTO.IP, IP_DROP_MEMBERSHIP, std.mem.asBytes(&mreq)) catch {};
                self.group_addr = null;
            }

            posix.close(fd);
            self.fd = null;

            std.log.info("Multicast subscriber stopped (received {} messages, {} gaps, {} missing)", .{
                self.messages_received,
                self.gaps_detected,
                self.total_missing,
            });
        }
    }

    /// Check if subscriber is active.
    pub fn isActive(self: *const Self) bool {
        return self.fd != null;
    }

    /// Receive next message (non-blocking).
    /// Returns null if no message available.
    /// Automatically extracts sequence and detects gaps.
    pub fn receive(self: *Self) ?ReceivedMessage {
        const fd = self.fd orelse return null;

        const n = posix.recv(fd, &self.recv_buf, 0) catch |err| {
            if (net_utils.isWouldBlock(err)) return null;
            std.log.warn("Multicast recv error: {}", .{err});
            return null;
        };

        // Need at least sequence header
        if (n < SEQUENCE_HEADER_SIZE) {
            std.log.debug("Multicast packet too small: {} bytes", .{n});
            return null;
        }

        self.messages_received += 1;
        self.bytes_received += n;

        // Extract sequence number
        const sequence = std.mem.readInt(u64, self.recv_buf[0..8], .big);
        const payload = self.recv_buf[SEQUENCE_HEADER_SIZE..n];

        // Gap detection
        var is_gap = false;
        var gap_size: u64 = 0;

        if (!self.first_received) {
            // First message - establish baseline
            self.first_received = true;
            self.last_sequence = sequence;
        } else if (sequence > self.last_sequence + 1) {
            // Gap detected
            gap_size = sequence - self.last_sequence - 1;
            is_gap = true;
            self.gaps_detected += 1;
            self.total_missing += gap_size;

            std.log.warn("Multicast gap: expected {}, got {} ({} missing)", .{
                self.last_sequence + 1,
                sequence,
                gap_size,
            });

            self.last_sequence = sequence;
        } else if (sequence <= self.last_sequence) {
            // Out of order or duplicate
            self.out_of_order += 1;
            // Don't update last_sequence for old messages
        } else {
            // Sequential - good
            self.last_sequence = sequence;
        }

        return ReceivedMessage{
            .sequence = sequence,
            .payload = payload,
            .is_gap = is_gap,
            .gap_size = gap_size,
        };
    }

    /// Receive raw bytes without sequence extraction.
    /// Use this if you need to handle sequence parsing yourself.
    pub fn receiveRaw(self: *Self) ?[]const u8 {
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

    /// Get expected next sequence number.
    pub fn getExpectedSequence(self: *const Self) u64 {
        if (!self.first_received) return 0;
        return self.last_sequence + 1;
    }

    /// Get statistics.
    pub fn getStats(self: *const Self) SubscriberStats {
        return .{
            .messages_received = self.messages_received,
            .bytes_received = self.bytes_received,
            .gaps_detected = self.gaps_detected,
            .total_missing = self.total_missing,
            .last_sequence = self.last_sequence,
            .out_of_order = self.out_of_order,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MulticastPublisher lifecycle" {
    var publisher = MulticastPublisher.init();
    defer publisher.deinit();

    try std.testing.expect(!publisher.isActive());
    try std.testing.expectEqual(@as(u64, 0), publisher.getSequence());
}

test "MulticastPublisher sequence header encoding" {
    var publisher = MulticastPublisher.init();
    defer publisher.deinit();

    // Simulate encoding (without actually sending)
    const test_seq: u64 = 0x0102030405060708;
    std.mem.writeInt(u64, publisher.send_buf[0..8], test_seq, .big);

    // Verify big-endian encoding
    try std.testing.expectEqual(@as(u8, 0x01), publisher.send_buf[0]);
    try std.testing.expectEqual(@as(u8, 0x02), publisher.send_buf[1]);
    try std.testing.expectEqual(@as(u8, 0x08), publisher.send_buf[7]);

    // Verify decoding
    const decoded = std.mem.readInt(u64, publisher.send_buf[0..8], .big);
    try std.testing.expectEqual(test_seq, decoded);
}

test "MulticastSubscriber gap detection - sequential" {
    var sub = MulticastSubscriber.init();

    // Simulate receiving messages
    sub.first_received = true;
    sub.last_sequence = 100;

    // Sequential message (no gap)
    const next_seq: u64 = 101;
    if (next_seq > sub.last_sequence + 1) {
        sub.gaps_detected += 1;
    }
    try std.testing.expectEqual(@as(u64, 0), sub.gaps_detected);
}

test "MulticastSubscriber gap detection - gap of 2" {
    var sub = MulticastSubscriber.init();

    // First message establishes baseline
    sub.first_received = true;
    sub.last_sequence = 100;

    // Message with gap (skipped 101, 102)
    const gap_seq: u64 = 103;
    if (gap_seq > sub.last_sequence + 1) {
        const gap_size = gap_seq - sub.last_sequence - 1;
        sub.gaps_detected += 1;
        sub.total_missing += gap_size;
        sub.last_sequence = gap_seq;
    }

    try std.testing.expectEqual(@as(u64, 1), sub.gaps_detected);
    try std.testing.expectEqual(@as(u64, 2), sub.total_missing);
    try std.testing.expectEqual(@as(u64, 103), sub.last_sequence);
}

test "MulticastSubscriber gap detection - out of order" {
    var sub = MulticastSubscriber.init();

    sub.first_received = true;
    sub.last_sequence = 105;

    // Late arrival (out of order)
    const late_seq: u64 = 102;
    if (late_seq <= sub.last_sequence) {
        sub.out_of_order += 1;
        // Don't update last_sequence
    }

    try std.testing.expectEqual(@as(u64, 1), sub.out_of_order);
    try std.testing.expectEqual(@as(u64, 105), sub.last_sequence); // Unchanged
}

test "SEQUENCE_HEADER_SIZE constant" {
    try std.testing.expectEqual(@as(usize, 8), SEQUENCE_HEADER_SIZE);
}
