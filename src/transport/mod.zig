i//! Transport layer for matching engine.
//!
//! Provides network communication via:
//! - TCP: Reliable, connection-oriented client communication
//! - UDP: Low-latency, connectionless client communication
//! - Multicast: Market data distribution with gap detection
//!
//! Key components:
//! - `TcpServer`: Cross-platform TCP server (epoll/kqueue)
//! - `UdpServer`: UDP server with O(1) client lookup
//! - `MulticastPublisher`: Market data publisher with sequence numbers
//! - `MulticastSubscriber`: Gap-detecting market data receiver
//! - `Server`: DEPRECATED single-threaded unified server
//!
//! For production use, prefer `threading.ThreadedServer` which provides
//! multi-threaded processing with dual matching engines.

pub const config = @import("config.zig");
pub const net_utils = @import("net_utils.zig");
pub const tcp_client = @import("tcp_client.zig");
pub const tcp_server = @import("tcp_server.zig");
pub const udp_server = @import("udp_server.zig");
pub const multicast = @import("multicast.zig");
pub const server = @import("server.zig");

// Re-export commonly used types
pub const Config = config.Config;
pub const ClientId = config.ClientId;
pub const UdpClientAddr = config.UdpClientAddr;

pub const TcpServer = tcp_server.TcpServer;
pub const TcpClient = tcp_client.TcpClient;
pub const ClientState = tcp_client.ClientState;
pub const ClientStats = tcp_client.ClientStats;

pub const UdpServer = udp_server.UdpServer;
pub const BatchSender = udp_server.BatchSender;

pub const MulticastPublisher = multicast.MulticastPublisher;
pub const MulticastSubscriber = multicast.MulticastSubscriber;
pub const ReceivedMessage = multicast.ReceivedMessage;
pub const SEQUENCE_HEADER_SIZE = multicast.SEQUENCE_HEADER_SIZE;

pub const Server = server.Server;

// Client ID utilities
pub const isUdpClient = config.isUdpClient;
pub const isTcpClient = config.isTcpClient;
pub const isValidClient = config.isValidClient;
pub const CLIENT_ID_NONE = config.CLIENT_ID_NONE;
pub const CLIENT_ID_UDP_BASE = config.CLIENT_ID_UDP_BASE;

// Network utilities
pub const parseIPv4 = net_utils.parseIPv4;
pub const parseSockAddr = net_utils.parseSockAddr;
pub const setLowLatencyOptions = net_utils.setLowLatencyOptions;
pub const setBufferSizes = net_utils.setBufferSizes;
pub const setReuseAddr = net_utils.setReuseAddr;
pub const isWouldBlock = net_utils.isWouldBlock;
pub const isConnectionReset = net_utils.isConnectionReset;

// ============================================================================
// Tests
// ============================================================================

test {
    // Run all submodule tests
    @import("std").testing.refAllDecls(@This());
}
