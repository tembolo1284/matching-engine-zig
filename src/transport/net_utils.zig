//! Shared network utilities for transport layer.
//!
//! Consolidates common functionality:
//! - IP address parsing
//! - Socket option helpers
//! - Error handling utilities

const std = @import("std");
const posix = std.posix;

// ============================================================================
// IP Address Parsing
// ============================================================================

/// Parse IPv4 address string to network byte order u32.
pub fn parseIPv4(addr: []const u8) !u32 {
    var parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, addr, '.');
    var i: usize = 0;

    while (iter.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidAddress;
        parts[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }

    if (i != 4) return error.InvalidAddress;

    return @bitCast(parts);
}

/// Parse address and port into sockaddr_in.
pub fn parseSockAddr(address: []const u8, port: u16) !posix.sockaddr.in {
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
    // Disable Nagle's algorithm
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

    // Enable quick ack (Linux only, ignored on macOS)
    const TCP_QUICKACK = 12;
    posix.setsockopt(fd, posix.IPPROTO.TCP, TCP_QUICKACK, &std.mem.toBytes(@as(c_int, 1))) catch {};
}

/// Set socket buffer sizes and return actual receive buffer size achieved.
/// Note: OS may cap the requested size. macOS default max is ~8MB, Linux varies.
/// Returns the actual receive buffer size (which may be less than requested).
pub fn setBufferSizes(fd: posix.fd_t, recv_size: u32, send_size: u32) u32 {
    // Set receive buffer
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, @intCast(recv_size)))) catch {};
    
    // Set send buffer
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, @intCast(send_size)))) catch {};

    // Query actual receive buffer size
    return getSocketRecvBufSize(fd);
}

/// Get current socket receive buffer size.
pub fn getSocketRecvBufSize(fd: posix.fd_t) u32 {
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
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
}

/// Set socket to non-blocking.
pub fn setNonBlocking(fd: posix.fd_t) !void {
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

// ============================================================================
// Tests
// ============================================================================

test "parseIPv4" {
    // Valid addresses
    try std.testing.expectEqual(@as(u32, 0x0100007F), try parseIPv4("127.0.0.1"));
    try std.testing.expectEqual(@as(u32, 0x00000000), try parseIPv4("0.0.0.0"));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), try parseIPv4("255.255.255.255"));

    // Invalid addresses
    try std.testing.expectError(error.InvalidAddress, parseIPv4("256.0.0.1"));
    try std.testing.expectError(error.InvalidAddress, parseIPv4("1.2.3"));
    try std.testing.expectError(error.InvalidAddress, parseIPv4("1.2.3.4.5"));
    try std.testing.expectError(error.InvalidAddress, parseIPv4("abc.def.ghi.jkl"));
}

test "parseSockAddr" {
    const addr = try parseSockAddr("192.168.1.1", 8080);
    try std.testing.expectEqual(posix.AF.INET, addr.family);
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 8080), addr.port);
}
