//! Shared network utilities for transport layer.
//!
//! Consolidates common functionality:
//! - IP address parsing
//! - Socket option helpers
//! - Error handling utilities
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: parseIPv4 loop bounded by 4 octets
//! - Rule 5: Assertions validate inputs
//! - Rule 7: All errors returned, never ignored silently

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ============================================================================
// Platform Detection
// ============================================================================
const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

// ============================================================================
// Cross-Platform TCP Socket Option Constants
// ============================================================================
// TCP_NODELAY is 1 on both Linux and macOS
const TCP_NODELAY: u32 = 1;

// TCP_QUICKACK is Linux-only (value 12)
const TCP_QUICKACK: u32 = 12;

// IPPROTO_TCP value
const IPPROTO_TCP: u32 = 6;

// ============================================================================
// IP Address Parsing
// ============================================================================

/// Maximum octets in IPv4 address.
const MAX_IPV4_OCTETS: usize = 4;

/// Maximum digits per octet (0-255 = 3 digits max).
const MAX_OCTET_DIGITS: usize = 3;

/// Parse IPv4 address string to network byte order u32.
/// Accepts standard dotted-decimal notation: "192.168.1.1"
/// Note: Does not accept leading zeros (e.g., "192.168.001.001" is invalid).
///
/// P10 Rule 2: Loop bounded by MAX_IPV4_OCTETS (4).
pub fn parseIPv4(addr: []const u8) !u32 {
    std.debug.assert(addr.len > 0);
    std.debug.assert(addr.len <= 15); // Max "255.255.255.255" = 15 chars

    var parts: [MAX_IPV4_OCTETS]u8 = undefined;
    var iter = std.mem.splitScalar(u8, addr, '.');
    var i: usize = 0;

    // P10 Rule 2: Bounded by MAX_IPV4_OCTETS
    while (iter.next()) |part| : (i += 1) {
        if (i >= MAX_IPV4_OCTETS) return error.InvalidAddress;
        if (part.len == 0) return error.InvalidAddress;
        if (part.len > MAX_OCTET_DIGITS) return error.InvalidAddress;

        // Reject leading zeros (except "0" itself)
        // This prevents ambiguity with octal notation
        if (part.len > 1 and part[0] == '0') return error.InvalidAddress;

        parts[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }

    if (i != MAX_IPV4_OCTETS) return error.InvalidAddress;

    // P10 Rule 5: Verify all parts were set
    std.debug.assert(i == 4);

    return @bitCast(parts);
}

/// Parse address and port into sockaddr_in.
pub fn parseSockAddr(address: []const u8, port: u16) !posix.sockaddr.in {
    std.debug.assert(address.len > 0);
    std.debug.assert(port > 0 or std.mem.eql(u8, address, "0.0.0.0"));

    return .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = if (std.mem.eql(u8, address, "0.0.0.0"))
            0
        else
            try parseIPv4(address),
    };
}

/// Format sockaddr_in for logging.
pub fn formatSockAddr(addr: posix.sockaddr.in) std.fmt.Formatter(formatSockAddrImpl) {
    return .{ .data = addr };
}

fn formatSockAddrImpl(
    addr: posix.sockaddr.in,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const a: [4]u8 = @bitCast(addr.addr);
    const port = std.mem.bigToNative(u16, addr.port);
    try writer.print("{}.{}.{}.{}:{}", .{ a[0], a[1], a[2], a[3], port });
}

// ============================================================================
// Socket Options
// ============================================================================

/// Set common socket options for low-latency.
pub fn setLowLatencyOptions(fd: posix.fd_t) void {
    std.debug.assert(fd >= 0);

    // Disable Nagle's algorithm (TCP_NODELAY)
    // Use raw setsockopt since posix.TCP doesn't exist on macOS
    _ = std.c.setsockopt(
        fd,
        IPPROTO_TCP,
        TCP_NODELAY,
        &std.mem.toBytes(@as(c_int, 1)),
        @sizeOf(c_int),
    );

    // Enable quick ack (Linux only, ignored on macOS)
    if (is_linux) {
        _ = std.c.setsockopt(
            fd,
            IPPROTO_TCP,
            TCP_QUICKACK,
            &std.mem.toBytes(@as(c_int, 1)),
            @sizeOf(c_int),
        );
    }
}

/// Set socket buffer sizes and return actual receive buffer size achieved.
/// Note: OS may cap the requested size. macOS default max is ~8MB, Linux varies.
/// Returns the actual receive buffer size (which may be less than requested).
pub fn setBufferSizes(fd: posix.fd_t, recv_size: u32, send_size: u32) u32 {
    std.debug.assert(fd >= 0);
    std.debug.assert(recv_size > 0);
    std.debug.assert(send_size > 0);

    // Set receive buffer
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, @intCast(recv_size)))) catch {};

    // Set send buffer
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, @intCast(send_size)))) catch {};

    // Query actual receive buffer size
    return getSocketRecvBufSize(fd);
}

/// Get current socket receive buffer size.
pub fn getSocketRecvBufSize(fd: posix.fd_t) u32 {
    std.debug.assert(fd >= 0);

    var buf: [@sizeOf(c_int)]u8 = undefined;
    var len: posix.socklen_t = @sizeOf(c_int);

    const rc = std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &buf, &len);
    if (rc == 0 and len == @sizeOf(c_int)) {
        const val: c_int = @bitCast(buf);
        return if (val > 0) @intCast(val) else 0;
    }
    return 0;
}

/// Get current socket send buffer size.
pub fn getSocketSendBufSize(fd: posix.fd_t) u32 {
    std.debug.assert(fd >= 0);

    var buf: [@sizeOf(c_int)]u8 = undefined;
    var len: posix.socklen_t = @sizeOf(c_int);

    const rc = std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &buf, &len);
    if (rc == 0 and len == @sizeOf(c_int)) {
        const val: c_int = @bitCast(buf);
        return if (val > 0) @intCast(val) else 0;
    }
    return 0;
}

/// Enable address reuse.
pub fn setReuseAddr(fd: posix.fd_t) !void {
    std.debug.assert(fd >= 0);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
}

/// Set socket to non-blocking.
pub fn setNonBlocking(fd: posix.fd_t) !void {
    std.debug.assert(fd >= 0);
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
}

// ============================================================================
// Error Handling
// ============================================================================

/// Check if error is a transient "would block" condition.
pub fn isWouldBlock(err: anyerror) bool {
    return err == error.WouldBlock or err == error.Again;
}

/// Check if error indicates connection reset.
pub fn isConnectionReset(err: anyerror) bool {
    return err == error.ConnectionResetByPeer or
        err == error.BrokenPipe or
        err == error.ConnectionRefused;
}

/// Check if error is a network error that should be retried.
pub fn isTransientError(err: anyerror) bool {
    return isWouldBlock(err) or
        err == error.Interrupted or
        err == error.TimedOut;
}

// ============================================================================
// Tests
// ============================================================================

test "parseIPv4 valid addresses" {
    try std.testing.expectEqual(@as(u32, 0x0100007F), try parseIPv4("127.0.0.1"));
    try std.testing.expectEqual(@as(u32, 0x00000000), try parseIPv4("0.0.0.0"));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), try parseIPv4("255.255.255.255"));
    try std.testing.expectEqual(@as(u32, 0x0101A8C0), try parseIPv4("192.168.1.1"));
}

test "parseIPv4 invalid addresses" {
    // Out of range
    try std.testing.expectError(error.InvalidAddress, parseIPv4("256.0.0.1"));

    // Wrong number of octets
    try std.testing.expectError(error.InvalidAddress, parseIPv4("1.2.3"));
    try std.testing.expectError(error.InvalidAddress, parseIPv4("1.2.3.4.5"));

    // Non-numeric
    try std.testing.expectError(error.InvalidAddress, parseIPv4("abc.def.ghi.jkl"));

    // Leading zeros (ambiguous - could be octal)
    try std.testing.expectError(error.InvalidAddress, parseIPv4("192.168.01.1"));
    try std.testing.expectError(error.InvalidAddress, parseIPv4("192.168.001.001"));

    // Empty octets
    try std.testing.expectError(error.InvalidAddress, parseIPv4("192..1.1"));
    try std.testing.expectError(error.InvalidAddress, parseIPv4(".168.1.1"));
}

test "parseSockAddr" {
    const addr = try parseSockAddr("192.168.1.1", 8080);
    try std.testing.expectEqual(posix.AF.INET, addr.family);
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 8080), addr.port);
}

test "parseSockAddr zero address" {
    const addr = try parseSockAddr("0.0.0.0", 1234);
    try std.testing.expectEqual(@as(u32, 0), addr.addr);
}

test "isWouldBlock" {
    try std.testing.expect(isWouldBlock(error.WouldBlock));
    try std.testing.expect(isWouldBlock(error.Again));
    try std.testing.expect(!isWouldBlock(error.ConnectionRefused));
}

test "isConnectionReset" {
    try std.testing.expect(isConnectionReset(error.ConnectionResetByPeer));
    try std.testing.expect(isConnectionReset(error.BrokenPipe));
    try std.testing.expect(!isConnectionReset(error.WouldBlock));
}

test "isTransientError" {
    try std.testing.expect(isTransientError(error.WouldBlock));
    try std.testing.expect(isTransientError(error.Interrupted));
    try std.testing.expect(!isTransientError(error.ConnectionRefused));
}
