//! Transport layer configuration.
//!
//! Configuration can be loaded from:
//! - Default values (development)
//! - Environment variables (production)
//! - Programmatic override
//!
//! Environment variables:
//! - ENGINE_TCP_ENABLED: "true" or "false"
//! - ENGINE_TCP_PORT: port number
//! - ENGINE_UDP_ENABLED: "true" or "false"
//! - ENGINE_UDP_PORT: port number
//! - ENGINE_MCAST_ENABLED: "true" or "false"
//! - ENGINE_MCAST_GROUP: multicast IP (e.g., "239.255.0.1")
//! - ENGINE_MCAST_PORT: port number

const std = @import("std");

// ============================================================================
// Shared Constants
// ============================================================================

/// Default channel capacity for SPSC queues.
/// Used by threading module - keep in sync with processor.zig CHANNEL_CAPACITY.
pub const DEFAULT_CHANNEL_CAPACITY: u32 = 65536;

// ============================================================================
// Client Identification
// ============================================================================

/// Client identifier for routing responses.
/// High bit indicates UDP vs TCP client.
pub const ClientId = u32;

/// Broadcast/unknown client.
pub const CLIENT_ID_NONE: ClientId = 0;

/// Base ID for UDP clients (high bit set).
pub const CLIENT_ID_UDP_BASE: ClientId = 0x80000000;

/// Maximum valid TCP client ID.
pub const CLIENT_ID_TCP_MAX: ClientId = CLIENT_ID_UDP_BASE - 1;

/// Check if client ID represents a UDP client.
pub inline fn isUdpClient(client_id: ClientId) bool {
    return (client_id & CLIENT_ID_UDP_BASE) != 0;
}

/// Check if client ID represents a TCP client.
pub inline fn isTcpClient(client_id: ClientId) bool {
    return client_id != CLIENT_ID_NONE and !isUdpClient(client_id);
}

/// Check if client ID is valid (non-zero).
pub inline fn isValidClient(client_id: ClientId) bool {
    return client_id != CLIENT_ID_NONE;
}

// ============================================================================
// UDP Client Address
// ============================================================================

/// Socket address for UDP response routing.
/// Packed for efficient storage in client maps.
pub const UdpClientAddr = extern struct {
    /// IPv4 address in network byte order.
    addr: u32,
    /// Port in network byte order.
    port: u16,
    /// Padding for alignment.
    _pad: u16 = 0,

    const Self = @This();

    /// Create from components.
    pub fn init(addr: u32, port: u16) Self {
        return .{ .addr = addr, .port = port };
    }

    /// Check equality.
    pub fn eql(self: Self, other: Self) bool {
        return self.addr == other.addr and self.port == other.port;
    }

    /// Hash for use in hash maps.
    pub fn hash(self: Self) u64 {
        return @as(u64, self.addr) << 16 | self.port;
    }

    /// Format for logging.
    pub fn format(
        self: Self,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const a: [4]u8 = @bitCast(self.addr);
        const port_host = std.mem.bigToNative(u16, self.port);
        try writer.print("{}.{}.{}.{}:{}", .{ a[0], a[1], a[2], a[3], port_host });
    }
};

// ============================================================================
// Configuration
// ============================================================================

/// Server configuration.
pub const Config = struct {
    // === TCP Settings ===
    tcp_enabled: bool = true,
    tcp_addr: []const u8 = "0.0.0.0",
    tcp_port: u16 = 1234,
    tcp_max_clients: u32 = 1024,
    tcp_recv_buffer_size: u32 = 4 * 1024 * 1024,
    tcp_send_buffer_size: u32 = 4 * 1024 * 1024,
    tcp_nodelay: bool = true,

    // === UDP Settings ===
    udp_enabled: bool = true,
    udp_addr: []const u8 = "0.0.0.0",
    udp_port: u16 = 1235,
    udp_recv_buffer_size: u32 = 4 * 1024 * 1024,
    udp_send_buffer_size: u32 = 4 * 1024 * 1024,
    udp_max_clients: u32 = 1024,

    // === Multicast Settings ===
    mcast_enabled: bool = true,
    mcast_group: []const u8 = "239.255.0.1",
    mcast_port: u16 = 1236,
    mcast_interface: []const u8 = "0.0.0.0",
    mcast_ttl: u8 = 1,
    mcast_loopback: bool = true, // Enable for local testing

    // === General Settings ===
    /// Channel capacity for processor queues.
    /// Must match threading/processor.zig CHANNEL_CAPACITY.
    channel_capacity: u32 = DEFAULT_CHANNEL_CAPACITY,
    use_binary_protocol: bool = false,
    use_tcp_framing: bool = true,

    // === Timeout Settings ===
    /// Idle timeout for TCP connections in seconds (0 = disabled).
    tcp_idle_timeout_secs: i64 = 300,

    const Self = @This();

    /// Load config from environment variables with defaults.
    pub fn fromEnv() Self {
        var cfg = Self{};

        // TCP
        cfg.tcp_enabled = envBool("ENGINE_TCP_ENABLED", cfg.tcp_enabled);
        cfg.tcp_port = envU16("ENGINE_TCP_PORT", cfg.tcp_port);
        cfg.tcp_max_clients = envU32("ENGINE_TCP_MAX_CLIENTS", cfg.tcp_max_clients);
        cfg.tcp_idle_timeout_secs = envI64("ENGINE_TCP_IDLE_TIMEOUT", cfg.tcp_idle_timeout_secs);

        // UDP
        cfg.udp_enabled = envBool("ENGINE_UDP_ENABLED", cfg.udp_enabled);
        cfg.udp_port = envU16("ENGINE_UDP_PORT", cfg.udp_port);

        // Multicast
        cfg.mcast_enabled = envBool("ENGINE_MCAST_ENABLED", cfg.mcast_enabled);
        if (std.posix.getenv("ENGINE_MCAST_GROUP")) |v| {
            cfg.mcast_group = v;
        }
        cfg.mcast_port = envU16("ENGINE_MCAST_PORT", cfg.mcast_port);
        cfg.mcast_ttl = envU8("ENGINE_MCAST_TTL", cfg.mcast_ttl);

        // General
        cfg.use_binary_protocol = envBool("ENGINE_BINARY_PROTOCOL", cfg.use_binary_protocol);
        cfg.channel_capacity = envU32("ENGINE_CHANNEL_CAPACITY", cfg.channel_capacity);

        return cfg;
    }

    /// Validate configuration.
    pub fn validate(self: *const Self) ConfigError!void {
        // Port validation
        if (self.tcp_enabled and self.tcp_port == 0) {
            return error.InvalidTcpPort;
        }
        if (self.udp_enabled and self.udp_port == 0) {
            return error.InvalidUdpPort;
        }
        if (self.mcast_enabled and self.mcast_port == 0) {
            return error.InvalidMcastPort;
        }

        // Buffer size validation
        if (self.tcp_recv_buffer_size < 1024) {
            return error.BufferTooSmall;
        }
        if (self.udp_recv_buffer_size < 1024) {
            return error.BufferTooSmall;
        }

        // Multicast address validation
        if (self.mcast_enabled) {
            const first_octet = parseFirstOctet(self.mcast_group) catch {
                return error.InvalidMcastGroup;
            };
            // Multicast range: 224.0.0.0 - 239.255.255.255
            if (first_octet < 224 or first_octet > 239) {
                return error.InvalidMcastGroup;
            }
        }

        // Client limits
        if (self.tcp_max_clients == 0 or self.tcp_max_clients > 65535) {
            return error.InvalidClientLimit;
        }

        // Channel capacity must be power of 2
        if (self.channel_capacity == 0 or
            (self.channel_capacity & (self.channel_capacity - 1)) != 0)
        {
            return error.InvalidChannelCapacity;
        }
    }

    /// Log configuration summary.
    pub fn log(self: *const Self) void {
        std.log.info("Configuration:", .{});
        std.log.info("  TCP: {} (port {}, idle_timeout={}s)", .{
            self.tcp_enabled,
            self.tcp_port,
            self.tcp_idle_timeout_secs,
        });
        std.log.info("  UDP: {} (port {})", .{ self.udp_enabled, self.udp_port });
        std.log.info("  Multicast: {} ({s}:{})", .{
            self.mcast_enabled,
            self.mcast_group,
            self.mcast_port,
        });
        std.log.info("  Channel capacity: {}", .{self.channel_capacity});
    }
};

pub const ConfigError = error{
    InvalidTcpPort,
    InvalidUdpPort,
    InvalidMcastPort,
    InvalidMcastGroup,
    BufferTooSmall,
    InvalidClientLimit,
    InvalidChannelCapacity,
};

// ============================================================================
// Environment Helpers
// ============================================================================

fn envBool(name: []const u8, default: bool) bool {
    const val = std.posix.getenv(name) orelse return default;
    return std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
}

fn envU8(name: []const u8, default: u8) u8 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u8, val, 10) catch default;
}

fn envU16(name: []const u8, default: u16) u16 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u16, val, 10) catch default;
}

fn envU32(name: []const u8, default: u32) u32 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u32, val, 10) catch default;
}

fn envI64(name: []const u8, default: i64) i64 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(i64, val, 10) catch default;
}

fn parseFirstOctet(addr: []const u8) !u8 {
    var iter = std.mem.splitScalar(u8, addr, '.');
    const first = iter.next() orelse return error.InvalidAddress;
    return std.fmt.parseInt(u8, first, 10);
}

// ============================================================================
// Tests
// ============================================================================

test "ClientId utilities" {
    const tcp_id: ClientId = 42;
    try std.testing.expect(isTcpClient(tcp_id));
    try std.testing.expect(!isUdpClient(tcp_id));
    try std.testing.expect(isValidClient(tcp_id));

    const udp_id: ClientId = CLIENT_ID_UDP_BASE + 100;
    try std.testing.expect(!isTcpClient(udp_id));
    try std.testing.expect(isUdpClient(udp_id));
    try std.testing.expect(isValidClient(udp_id));

    try std.testing.expect(!isValidClient(CLIENT_ID_NONE));
}

test "UdpClientAddr equality and hash" {
    const addr1 = UdpClientAddr.init(0x0100007F, 1234);
    const addr2 = UdpClientAddr.init(0x0100007F, 1234);
    const addr3 = UdpClientAddr.init(0x0100007F, 1235);

    try std.testing.expect(addr1.eql(addr2));
    try std.testing.expect(!addr1.eql(addr3));
    try std.testing.expectEqual(addr1.hash(), addr2.hash());
}

test "Config validation" {
    var cfg = Config{};
    try cfg.validate();

    cfg.mcast_group = "192.168.1.1";
    try std.testing.expectError(error.InvalidMcastGroup, cfg.validate());

    cfg.mcast_group = "239.255.0.1";
    try cfg.validate();
}

test "Config channel capacity validation" {
    var cfg = Config{};

    // Valid power of 2
    cfg.channel_capacity = 65536;
    try cfg.validate();

    // Invalid: not power of 2
    cfg.channel_capacity = 1000;
    try std.testing.expectError(error.InvalidChannelCapacity, cfg.validate());

    // Invalid: zero
    cfg.channel_capacity = 0;
    try std.testing.expectError(error.InvalidChannelCapacity, cfg.validate());
}
