//! Multicast publisher for market data distribution.

const std = @import("std");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");

pub const MulticastPublisher = struct {
    fd: posix.fd_t = -1,
    dest_addr: std.posix.sockaddr.in = undefined,
    send_buf: [4096]u8 = undefined,
    sequence: u64 = 0,
    protocol: codec.Protocol = .csv,

    messages_sent: u64 = 0,
    bytes_sent: u64 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    pub fn start(self: *Self, group: []const u8, port: u16, ttl: u8) !void {
        self.fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        errdefer posix.close(self.fd);

        // Set multicast TTL
        const ttl_val: [1]u8 = .{ttl};
        try posix.setsockopt(self.fd, posix.IPPROTO.IP, posix.IP.MULTICAST_TTL, &ttl_val);

        // Enable loopback for local testing
        const loop: [1]u8 = .{1};
        try posix.setsockopt(self.fd, posix.IPPROTO.IP, posix.IP.MULTICAST_LOOP, &loop);

        // Setup destination address
        self.dest_addr = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = try parseIPv4(group),
        };

        std.log.info("Multicast publisher started: {s}:{} (TTL={})", .{ group, port, ttl });
    }

    pub fn stop(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn publish(self: *Self, message: *const msg.OutputMsg) bool {
        if (self.fd < 0) return false;

        const len = switch (self.protocol) {
            .csv => csv_codec.encodeOutput(message, &self.send_buf) catch return false,
            .binary => binary_codec.encodeOutput(message, &self.send_buf) catch return false,
            else => return false,
        };

        const dest_ptr: *const posix.sockaddr = @ptrCast(&self.dest_addr);
        _ = posix.sendto(self.fd, self.send_buf[0..len], 0, dest_ptr, @sizeOf(@TypeOf(self.dest_addr))) catch return false;

        self.sequence += 1;
        self.messages_sent += 1;
        self.bytes_sent += len;

        return true;
    }

    pub fn setProtocol(self: *Self, protocol: codec.Protocol) void {
        self.protocol = protocol;
    }
};

pub const MulticastSubscriber = struct {
    fd: posix.fd_t = -1,
    recv_buf: [4096]u8 = undefined,
    last_sequence: u64 = 0,
    gaps_detected: u64 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    pub fn start(self: *Self, group: []const u8, port: u16) !void {
        self.fd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        errdefer posix.close(self.fd);

        // Allow address reuse
        try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        // Bind to port
        var bind_addr = std.posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0, // INADDR_ANY
        };
        const bind_ptr: *const posix.sockaddr = @ptrCast(&bind_addr);
        try posix.bind(self.fd, bind_ptr, @sizeOf(@TypeOf(bind_addr)));

        // Join multicast group
        const group_addr = try parseIPv4(group);
        var mreq: extern struct {
            multiaddr: u32,
            interface: u32,
        } = .{
            .multiaddr = group_addr,
            .interface = 0, // INADDR_ANY
        };
        try posix.setsockopt(self.fd, posix.IPPROTO.IP, posix.IP.ADD_MEMBERSHIP, std.mem.asBytes(&mreq));

        std.log.info("Multicast subscriber joined: {s}:{}", .{ group, port });
    }

    pub fn stop(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn receive(self: *Self) ?[]const u8 {
        if (self.fd < 0) return null;

        const n = posix.recv(self.fd, &self.recv_buf, 0) catch return null;
        if (n == 0) return null;

        return self.recv_buf[0..n];
    }
};

fn parseIPv4(addr: []const u8) !u32 {
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
