//! Transport layer configuration.

const std = @import("std");

pub const Config = struct {
    // TCP settings
    tcp_enabled: bool = true,
    tcp_addr: []const u8 = "0.0.0.0",
    tcp_port: u16 = 9000,
    tcp_max_clients: usize = 1024,
    tcp_recv_buffer_size: usize = 65536,
    
    // UDP settings
    udp_enabled: bool = true,
    udp_addr: []const u8 = "0.0.0.0",
    udp_port: u16 = 9001,
    udp_recv_buffer_size: usize = 65536,
    
    // Multicast settings
    mcast_enabled: bool = true,
    mcast_group: []const u8 = "239.255.0.1",
    mcast_port: u16 = 9002,
    mcast_interface: []const u8 = "0.0.0.0",
    mcast_ttl: u8 = 1,
    
    // General settings
    channel_capacity: usize = 100000,
    spin_wait: bool = false,
    
    const Self = @This();
    
    /// Load config from environment variables
    pub fn fromEnv() Self {
        var config = Self{};
        
        if (std.posix.getenv("ENGINE_TCP_ENABLED")) |v| {
            config.tcp_enabled = std.mem.eql(u8, v, "true");
        }
        if (std.posix.getenv("ENGINE_TCP_PORT")) |v| {
            config.tcp_port = std.fmt.parseInt(u16, v, 10) catch 9000;
        }
        if (std.posix.getenv("ENGINE_UDP_ENABLED")) |v| {
            config.udp_enabled = std.mem.eql(u8, v, "true");
        }
        if (std.posix.getenv("ENGINE_UDP_PORT")) |v| {
            config.udp_port = std.fmt.parseInt(u16, v, 10) catch 9001;
        }
        if (std.posix.getenv("ENGINE_MCAST_ENABLED")) |v| {
            config.mcast_enabled = std.mem.eql(u8, v, "true");
        }
        if (std.posix.getenv("ENGINE_MCAST_GROUP")) |v| {
            config.mcast_group = v;
        }
        if (std.posix.getenv("ENGINE_MCAST_PORT")) |v| {
            config.mcast_port = std.fmt.parseInt(u16, v, 10) catch 9002;
        }
        
        return config;
    }
};

/// Client identifier for routing responses
pub const ClientId = u32;

/// Special client IDs
pub const CLIENT_ID_BROADCAST: ClientId = 0;
pub const CLIENT_ID_UDP_BASE: ClientId = 0x80000000; // High bit set = UDP client

/// Check if client ID represents a UDP client
pub fn isUdpClient(client_id: ClientId) bool {
    return (client_id & CLIENT_ID_UDP_BASE) != 0;
}

/// Socket address for UDP response routing
pub const UdpClientAddr = extern struct {
    addr: u32,  // IPv4 in network byte order
    port: u16,  // Port in network byte order
    _pad: u16 = 0,
    
    pub fn format(self: UdpClientAddr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const a = @as([4]u8, @bitCast(self.addr));
        try writer.print("{}.{}.{}.{}:{}", .{ a[0], a[1], a[2], a[3], std.mem.nativeToLittle(u16, self.port) });
    }
};
