//! TCP server with epoll I/O multiplexing.
//!
//! Orchestrates:
//! - Listening socket and connection acceptance
//! - Epoll event loop for non-blocking I/O
//! - Client lifecycle management
//! - Message dispatch via callbacks
//!
//! Architecture:
//! ```
//!   ┌─────────────────────────────────────────────┐
//!   │              TcpServer                       │
//!   │  ┌─────────────────────────────────────┐   │
//!   │  │         Listen Socket               │   │
//!   │  └──────────────┬──────────────────────┘   │
//!   │                 │ accept()                  │
//!   │  ┌──────────────▼──────────────────────┐   │
//!   │  │          Epoll FD                   │   │
//!   │  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐   │   │
//!   │  │  │ C0  │ │ C1  │ │ C2  │ │ ... │   │   │
//!   │  │  └─────┘ └─────┘ └─────┘ └─────┘   │   │
//!   │  └─────────────────────────────────────┘   │
//!   │                 │                           │
//!   │  ┌──────────────▼──────────────────────┐   │
//!   │  │        ClientPool                   │   │
//!   │  │  TcpClient[0..MAX_CLIENTS]          │   │
//!   │  └─────────────────────────────────────┘   │
//!   └─────────────────────────────────────────────┘
//! ```
//!
//! Thread Safety:
//! - NOT thread-safe. Use from single I/O thread only.
//! - Callbacks invoked synchronously during poll().

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const config = @import("config.zig");
const net_utils = @import("net_utils.zig");
const tcp_client = @import("tcp_client.zig");

pub const TcpClient = tcp_client.TcpClient;
pub const ClientState = tcp_client.ClientState;
pub const ClientStats = tcp_client.ClientStats;

// ============================================================================
// Configuration
// ============================================================================

/// Maximum concurrent clients.
pub const MAX_CLIENTS: u32 = 1024;

/// Maximum epoll events per poll cycle.
const MAX_EVENTS: u32 = 64;

/// Listen backlog size.
const LISTEN_BACKLOG: u31 = 128;

// ============================================================================
// Callback Types
// ============================================================================

/// Callback invoked when a complete message is received.
pub const MessageCallback = *const fn (
    client_id: config.ClientId,
    message: *const msg.InputMsg,
    ctx: ?*anyopaque,
) void;

/// Callback invoked when a client disconnects.
pub const DisconnectCallback = *const fn (
    client_id: config.ClientId,
    ctx: ?*anyopaque,
) void;

// ============================================================================
// Server Statistics
// ============================================================================

/// Server-wide statistics.
pub const ServerStats = struct {
    /// Currently connected clients.
    current_clients: u32,
    /// Total connections since start.
    total_connections: u64,
    /// Total disconnections since start.
    total_disconnections: u64,
    /// Total inbound messages.
    total_messages_in: u64,
    /// Total outbound messages.
    total_messages_out: u64,
    /// Total bytes received.
    total_bytes_in: u64,
    /// Total bytes sent.
    total_bytes_out: u64,
    /// Accept errors.
    accept_errors: u64,
    /// Decode errors.
    decode_errors: u64,
};

// ============================================================================
// TCP Server
// ============================================================================

/// TCP server with epoll-based event loop.
pub const TcpServer = struct {
    // === Sockets ===
    /// Listening socket (null if not started).
    listen_fd: ?posix.fd_t = null,

    /// Epoll instance (null if not started).
    epoll_fd: ?posix.fd_t = null,

    // === Clients ===
    /// Pre-allocated client pool.
    clients: tcp_client.ClientPool(MAX_CLIENTS) = .{},

    /// Next client ID to assign.
    next_client_id: config.ClientId = 1,

    // === Callbacks ===
    /// Message received callback.
    on_message: ?MessageCallback = null,

    /// Client disconnected callback.
    on_disconnect: ?DisconnectCallback = null,

    /// Callback context pointer.
    callback_ctx: ?*anyopaque = null,

    // === Options ===
    /// Whether to use length-prefix framing.
    use_framing: bool = true,

    // === Statistics ===
    total_connections: u64 = 0,
    total_disconnections: u64 = 0,
    accept_errors: u64 = 0,
    decode_errors: u64 = 0,

    // === Allocator ===
    allocator: std.mem.Allocator,

    const Self = @This();

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Initialize server (not yet listening).
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Cleanup all resources.
    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start listening on address:port.
    pub fn start(self: *Self, address: []const u8, port: u16) !void {
        std.debug.assert(self.listen_fd == null);
        std.debug.assert(self.epoll_fd == null);

        // Create listening socket
        const listen_fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(listen_fd);

        // Set socket options
        try net_utils.setReuseAddr(listen_fd);

        // Bind to address
        const addr = try net_utils.parseSockAddr(address, port);
        try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

        // Start listening
        try posix.listen(listen_fd, LISTEN_BACKLOG);

        // Create epoll instance
        const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        errdefer posix.close(epoll_fd);

        // Add listen socket to epoll
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = listen_fd },
        };
        try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &ev);

        self.listen_fd = listen_fd;
        self.epoll_fd = epoll_fd;

        std.log.info("TCP server listening on {s}:{} (framing={}, max_clients={})", .{
            address,
            port,
            self.use_framing,
            MAX_CLIENTS,
        });
    }

    /// Stop server and disconnect all clients.
    pub fn stop(self: *Self) void {
        // Disconnect all clients
        var iter = self.clients.getActive();
        while (iter.next()) |client| {
            self.disconnectClientInternal(client, false);
        }

        // Close epoll
        if (self.epoll_fd) |fd| {
            posix.close(fd);
            self.epoll_fd = null;
        }

        // Close listen socket
        if (self.listen_fd) |fd| {
            posix.close(fd);
            self.listen_fd = null;
        }

        std.log.info("TCP server stopped (total connections: {})", .{self.total_connections});
    }

    /// Check if server is running.
    pub fn isRunning(self: *const Self) bool {
        return self.listen_fd != null and self.epoll_fd != null;
    }

    // ========================================================================
    // Event Loop
    // ========================================================================

    /// Poll for events with timeout.
    /// Returns number of events processed.
    pub fn poll(self: *Self, timeout_ms: i32) !usize {
        const epoll_fd = self.epoll_fd orelse return error.NotStarted;
        const listen_fd = self.listen_fd orelse return error.NotStarted;

        var events: [MAX_EVENTS]linux.epoll_event = undefined;
        const n = posix.epoll_wait(epoll_fd, &events, timeout_ms);

        var processed: usize = 0;

        for (events[0..n]) |ev| {
            if (ev.data.fd == listen_fd) {
                // New connection(s) pending
                self.acceptConnections();
                processed += 1;
            } else {
                // Client event
                if (self.clients.findByFd(ev.data.fd)) |client| {
                    self.handleClientEvent(client, ev.events);
                    processed += 1;
                }
            }
        }

        return processed;
    }

    /// Accept all pending connections.
    fn acceptConnections(self: *Self) void {
        const listen_fd = self.listen_fd orelse return;

        // Accept in loop (edge-triggered)
        while (true) {
            self.acceptOne(listen_fd) catch |err| {
                if (err == error.WouldBlock) break;

                self.accept_errors += 1;
                std.log.warn("Accept error: {}", .{err});

                // For transient errors, continue trying
                if (err != error.SystemResources and
                    err != error.ProcessFdQuotaExceeded)
                {
                    break;
                }
            };
        }
    }

    /// Accept a single connection.
    fn acceptOne(self: *Self, listen_fd: posix.fd_t) !void {
        const epoll_fd = self.epoll_fd orelse return error.NotStarted;

        var client_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));

        const client_fd = try posix.accept(
            listen_fd,
            @ptrCast(&client_addr),
            &addr_len,
            posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        );
        errdefer posix.close(client_fd);

        // Find free slot
        const client = self.clients.allocate() orelse {
            std.log.warn("Max clients ({}) reached, rejecting connection", .{MAX_CLIENTS});
            posix.close(client_fd);
            return;
        };

        // Initialize client
        const client_id = self.allocateClientId();
        client.* = TcpClient.init(client_fd, client_id);

        self.total_connections += 1;
        self.clients.active_count += 1;

        // Set socket options for low latency
        net_utils.setLowLatencyOptions(client_fd);

        // Add to epoll (edge-triggered for efficiency)
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP,
            .data = .{ .fd = client_fd },
        };
        try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, client_fd, &ev);

        std.log.info("Client {} connected (fd={}, active={})", .{
            client_id,
            client_fd,
            self.clients.active_count,
        });
    }

    /// Handle epoll event for a client.
    fn handleClientEvent(self: *Self, client: *TcpClient, events: u32) void {
        // Check for errors or hangup first
        if (events & (linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP) != 0) {
            self.disconnectClient(client);
            return;
        }

        // Handle readable
        if (events & linux.EPOLL.IN != 0) {
            self.handleClientRead(client) catch |err| {
                if (err != error.WouldBlock) {
                    std.log.debug("Client {} read error: {}", .{ client.client_id, err });
                    self.disconnectClient(client);
                    return;
                }
            };
        }

        // Handle writable
        if (events & linux.EPOLL.OUT != 0) {
            client.flushSend() catch |err| {
                std.log.debug("Client {} write error: {}", .{ client.client_id, err });
                self.disconnectClient(client);
                return;
            };

            // If send buffer drained, disable write events
            if (!client.hasPendingSend()) {
                self.updateClientEpoll(client, false) catch {};
            }
        }
    }

    /// Handle incoming data from client.
    fn handleClientRead(self: *Self, client: *TcpClient) !void {
        // Receive all available data (edge-triggered)
        while (true) {
            _ = client.receive() catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };
        }

        // Process received data
        if (self.use_framing) {
            self.processFramedMessages(client);
        } else {
            self.processRawMessages(client);
        }
    }

    /// Process length-prefixed framed messages.
    fn processFramedMessages(self: *Self, client: *TcpClient) void {
        while (true) {
            const frame_result = client.extractFrame();

            switch (frame_result) {
                .frame => |payload| {
                    // Auto-detect protocol on first message
                    if (client.protocol == .unknown) {
                        client.protocol = codec.detectProtocol(payload);
                    }

                    // Decode and dispatch
                    self.decodeAndDispatch(client, payload);

                    // Consume the frame
                    client.consumeFrame(payload.len);
                },

                .incomplete, .empty => break,

                .oversized => {
                    // Already handled in extractFrame, continue processing
                    continue;
                },
            }
        }
    }

    /// Process raw (non-framed) messages.
    fn processRawMessages(self: *Self, client: *TcpClient) void {
        var processed: u32 = 0;
        const data = client.getReceivedData();

        while (processed < data.len) {
            const remaining = data[processed..];

            // Try protocol detection
            if (client.protocol == .unknown) {
                client.protocol = codec.detectProtocol(remaining);
                if (client.protocol == .unknown and remaining.len < 8) break;
            }

            // Try to decode
            const result = codec.Codec.decodeInput(remaining) catch |err| {
                if (err == codec.CodecError.IncompleteMessage) break;

                self.decode_errors += 1;
                std.log.debug("Client {} decode error: {}", .{ client.client_id, err });
                processed += 1; // Skip one byte and retry
                continue;
            };

            // Dispatch message
            if (self.on_message) |callback| {
                callback(client.client_id, &result.message, self.callback_ctx);
            }

            client.stats.messages_received += 1;
            processed += @intCast(result.bytes_consumed);
        }

        // Compact buffer
        if (processed > 0) {
            client.compactRecvBuffer(processed);
        }
    }

    /// Decode payload and dispatch to callback.
    fn decodeAndDispatch(self: *Self, client: *TcpClient, payload: []const u8) void {
        const result = codec.Codec.decodeInput(payload) catch |err| {
            self.decode_errors += 1;
            std.log.debug("Client {} decode error: {}", .{ client.client_id, err });
            return;
        };

        if (self.on_message) |callback| {
            callback(client.client_id, &result.message, self.callback_ctx);
        }
    }

    // ========================================================================
    // Send Operations
    // ========================================================================

    /// Send data to specific client.
    pub fn send(self: *Self, client_id: config.ClientId, data: []const u8) bool {
        std.debug.assert(config.isTcpClient(client_id));

        const client = self.clients.findById(client_id) orelse return false;

        const success = if (self.use_framing)
            client.queueFramedSend(data)
        else
            client.queueRawSend(data);

        if (!success) return false;

        client.recordMessageSent();

        // Enable write events to flush
        self.updateClientEpoll(client, true) catch return false;

        return true;
    }

    /// Broadcast data to all connected clients.
    pub fn broadcast(self: *Self, data: []const u8) u32 {
        var sent_count: u32 = 0;

        var iter = self.clients.getActive();
        while (iter.next()) |client| {
            if (client.state != .connected) continue;

            const success = if (self.use_framing)
                client.queueFramedSend(data)
            else
                client.queueRawSend(data);

            if (success) {
                client.recordMessageSent();
                sent_count += 1;
                self.updateClientEpoll(client, true) catch {};
            }
        }

        return sent_count;
    }

    // ========================================================================
    // Client Management
    // ========================================================================

    /// Disconnect a client and invoke callback.
    pub fn disconnectClient(self: *Self, client: *TcpClient) void {
        self.disconnectClientInternal(client, true);
    }

    /// Internal disconnect implementation.
    fn disconnectClientInternal(self: *Self, client: *TcpClient, invoke_callback: bool) void {
        if (client.state == .disconnected) return;

        const client_id = client.client_id;
        const fd = client.fd;

        std.log.info("Client {} disconnected (fd={})", .{ client_id, fd });

        // Remove from epoll
        if (self.epoll_fd) |epoll_fd| {
            posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, fd, null) catch {};
        }

        // Reset client slot
        client.reset();

        std.debug.assert(self.clients.active_count > 0);
        self.clients.active_count -= 1;
        self.total_disconnections += 1;

        // Invoke callback
        if (invoke_callback) {
            if (self.on_disconnect) |callback| {
                callback(client_id, self.callback_ctx);
            }
        }
    }

    /// Update epoll registration for client.
    fn updateClientEpoll(self: *Self, client: *TcpClient, want_write: bool) !void {
        const epoll_fd = self.epoll_fd orelse return error.NotStarted;

        var events: u32 = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP;
        if (want_write) events |= linux.EPOLL.OUT;

        var ev = linux.epoll_event{
            .events = events,
            .data = .{ .fd = client.fd },
        };

        try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_MOD, client.fd, &ev);
    }

    /// Allocate next client ID.
    fn allocateClientId(self: *Self) config.ClientId {
        const id = self.next_client_id;

        self.next_client_id +%= 1;

        // Skip invalid IDs
        if (self.next_client_id == 0 or
            self.next_client_id >= config.CLIENT_ID_UDP_BASE)
        {
            self.next_client_id = 1;
        }

        return id;
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    /// Get server statistics.
    pub fn getStats(self: *const Self) ServerStats {
        const client_stats = self.clients.getAggregateStats();

        return .{
            .current_clients = self.clients.active_count,
            .total_connections = self.total_connections,
            .total_disconnections = self.total_disconnections,
            .total_messages_in = client_stats.total_messages_in,
            .total_messages_out = client_stats.total_messages_out,
            .total_bytes_in = client_stats.total_bytes_in,
            .total_bytes_out = client_stats.total_bytes_out,
            .accept_errors = self.accept_errors,
            .decode_errors = self.decode_errors,
        };
    }

    /// Get number of connected clients.
    pub fn getClientCount(self: *const Self) u32 {
        return self.clients.active_count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TcpServer initialization" {
    var server = TcpServer.init(std.testing.allocator);
    defer server.deinit();

    try std.testing.expect(!server.isRunning());
    try std.testing.expectEqual(@as(u32, 0), server.getClientCount());
}

test "TcpServer client ID allocation" {
    var server = TcpServer.init(std.testing.allocator);
    defer server.deinit();

    const id1 = server.allocateClientId();
    const id2 = server.allocateClientId();
    const id3 = server.allocateClientId();

    try std.testing.expect(id1 != id2);
    try std.testing.expect(id2 != id3);
    try std.testing.expect(config.isTcpClient(id1));
    try std.testing.expect(config.isTcpClient(id2));
}

test "TcpServer statistics initialization" {
    var server = TcpServer.init(std.testing.allocator);
    defer server.deinit();

    const stats = server.getStats();

    try std.testing.expectEqual(@as(u32, 0), stats.current_clients);
    try std.testing.expectEqual(@as(u64, 0), stats.total_connections);
    try std.testing.expectEqual(@as(u64, 0), stats.total_messages_in);
}
