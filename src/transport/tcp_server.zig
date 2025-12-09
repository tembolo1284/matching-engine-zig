//! TCP server with cross-platform I/O multiplexing.
//!
//! Uses epoll on Linux and kqueue on macOS/BSD for efficient event-driven I/O.
//!
//! Orchestrates:
//! - Listening socket and connection acceptance
//! - Event loop for non-blocking I/O
//! - Client lifecycle management
//! - Message dispatch via callbacks
//! - Idle timeout enforcement
//!
//! Thread Safety:
//! - NOT thread-safe. Use from single I/O thread only.
//! - Callbacks invoked synchronously during poll().

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const config = @import("config.zig");
const net_utils = @import("net_utils.zig");
const tcp_client = @import("tcp_client.zig");

pub const TcpClient = tcp_client.TcpClient;
pub const ClientState = tcp_client.ClientState;
pub const ClientStats = tcp_client.ClientStats;

// ============================================================================
// Platform Detection
// ============================================================================

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();
const is_bsd = builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd;

// Import platform-specific modules
const linux = if (is_linux) std.os.linux else struct {};

// ============================================================================
// Cross-Platform Event Poller
// ============================================================================

/// Cross-platform event types
const EventType = struct {
    readable: bool = false,
    writable: bool = false,
    error_or_hup: bool = false,
};

/// Cross-platform event poller abstraction
const Poller = struct {
    fd: posix.fd_t,

    const Self = @This();

    /// Create a new poller instance
    pub fn init() !Self {
        if (is_linux) {
            const fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
            return .{ .fd = fd };
        } else if (is_darwin or is_bsd) {
            const fd = try posix.kqueue();
            return .{ .fd = fd };
        } else {
            @compileError("Unsupported platform for event polling");
        }
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.fd);
    }

    /// Add a file descriptor to watch for read events
    pub fn addRead(self: *Self, fd: posix.fd_t) !void {
        if (is_linux) {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .fd = fd },
            };
            try epollCtl(self.fd, linux.EPOLL.CTL_ADD, fd, &ev);
        } else if (is_darwin or is_bsd) {
            var changelist = [_]posix.Kevent{
                makeKEvent(fd, posix.system.EVFILT.READ, posix.system.EV.ADD, 0),
            };
            _ = try posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null);
        }
    }

    /// Add a client fd with read + edge-triggered + hangup detection
    pub fn addClient(self: *Self, fd: posix.fd_t) !void {
        if (is_linux) {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP,
                .data = .{ .fd = fd },
            };
            try epollCtl(self.fd, linux.EPOLL.CTL_ADD, fd, &ev);
        } else if (is_darwin or is_bsd) {
            // kqueue uses separate filters for read and write
            // EV_CLEAR gives edge-triggered-like behavior
            var changelist = [_]posix.Kevent{
                makeKEvent(fd, posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.CLEAR, 0),
            };
            _ = try posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null);
        }
    }

    /// Update client to enable/disable write events
    pub fn updateClient(self: *Self, fd: posix.fd_t, want_write: bool) !void {
        if (is_linux) {
            var events: u32 = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP;
            if (want_write) events |= linux.EPOLL.OUT;

            var ev = linux.epoll_event{
                .events = events,
                .data = .{ .fd = fd },
            };
            try epollCtl(self.fd, linux.EPOLL.CTL_MOD, fd, &ev);
        } else if (is_darwin or is_bsd) {
            // For kqueue, we add/delete the write filter
            if (want_write) {
                var changelist = [_]posix.Kevent{
                    makeKEvent(fd, posix.system.EVFILT.WRITE, posix.system.EV.ADD | posix.system.EV.CLEAR, 0),
                };
                _ = try posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null);
            } else {
                var changelist = [_]posix.Kevent{
                    makeKEvent(fd, posix.system.EVFILT.WRITE, posix.system.EV.DELETE, 0),
                };
                // Ignore error if filter wasn't registered
                _ = posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null) catch {};
            }
        }
    }

    /// Remove fd from poller
    pub fn remove(self: *Self, fd: posix.fd_t) void {
        if (is_linux) {
            epollCtl(self.fd, linux.EPOLL.CTL_DEL, fd, null) catch |err| {
                std.log.debug("epoll_ctl DEL failed for fd {}: {}", .{ fd, err });
            };
        } else if (is_darwin or is_bsd) {
            // kqueue automatically removes events when fd is closed
            // But we can explicitly remove if needed
            var changelist = [_]posix.Kevent{
                makeKEvent(fd, posix.system.EVFILT.READ, posix.system.EV.DELETE, 0),
                makeKEvent(fd, posix.system.EVFILT.WRITE, posix.system.EV.DELETE, 0),
            };
            _ = posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null) catch {};
        }
    }

    /// Wait for events. Returns slice of ready fds with their event types.
    /// Caller must provide storage for results.
    pub fn wait(
        self: *Self,
        results: []PollResult,
        timeout_ms: i32,
    ) ![]PollResult {
        if (is_linux) {
            var events: [MAX_EVENTS]linux.epoll_event = undefined;
            const n = posix.epoll_wait(self.fd, &events, timeout_ms);

            const count = @min(n, results.len);
            for (0..count) |i| {
                results[i] = .{
                    .fd = events[i].data.fd,
                    .events = .{
                        .readable = (events[i].events & linux.EPOLL.IN) != 0,
                        .writable = (events[i].events & linux.EPOLL.OUT) != 0,
                        .error_or_hup = (events[i].events & (linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP)) != 0,
                    },
                };
            }
            return results[0..count];
        } else if (is_darwin or is_bsd) {
            var events: [MAX_EVENTS]posix.Kevent = undefined;

            // kevent expects a pointer to timespec, not an optional value
            var timeout_val: posix.timespec = .{
                .sec = @intCast(@divTrunc(timeout_ms, 1000)),
                .nsec = @intCast(@mod(timeout_ms, 1000) * 1_000_000),
            };
            const timeout_ptr: ?*const posix.timespec = if (timeout_ms < 0) null else &timeout_val;

            const n = try posix.kevent(self.fd, &[_]posix.Kevent{}, &events, timeout_ptr);

            const count = @min(n, results.len);
            for (0..count) |i| {
                const ev = &events[i];
                const fd: posix.fd_t = @intCast(ev.ident);
                results[i] = .{
                    .fd = fd,
                    .events = .{
                        .readable = ev.filter == posix.system.EVFILT.READ,
                        .writable = ev.filter == posix.system.EVFILT.WRITE,
                        .error_or_hup = (ev.flags & posix.system.EV.EOF) != 0 or
                            (ev.flags & posix.system.EV.ERROR) != 0,
                    },
                };
            }
            return results[0..count];
        } else {
            return &[_]PollResult{};
        }
    }

    // Helper for Linux epoll_ctl with proper type handling and logging
    fn epollCtl(epfd: posix.fd_t, op: u32, fd: posix.fd_t, event: ?*linux.epoll_event) !void {
        const rc = linux.epoll_ctl(epfd, op, fd, event);
        if (rc != 0) {
            const errno = std.posix.errno(rc);
            std.log.debug("epoll_ctl failed: op={} fd={} errno={}", .{ op, fd, errno });
            return error.EpollCtlFailed;
        }
    }

    // Helper to create kqueue kevent struct
    fn makeKEvent(ident: posix.fd_t, filter: i16, flags: u16, fflags: u32) posix.Kevent {
        return .{
            .ident = @intCast(ident),
            .filter = filter,
            .flags = flags,
            .fflags = fflags,
            .data = 0,
            .udata = 0,
        };
    }
};

/// Result from polling
const PollResult = struct {
    fd: posix.fd_t,
    events: EventType,
};

// ============================================================================
// Configuration
// ============================================================================

/// Maximum concurrent clients.
pub const MAX_CLIENTS: u32 = 64;

/// Maximum events per poll cycle.
const MAX_EVENTS: u32 = 64;

/// Listen backlog size.
const LISTEN_BACKLOG: u31 = 128;

/// How often to check for idle clients (in poll cycles).
const IDLE_CHECK_INTERVAL: u32 = 100;

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
    /// Idle timeout disconnects.
    idle_timeouts: u64,
    /// Error threshold disconnects.
    error_disconnects: u64,
};

// ============================================================================
// TCP Server
// ============================================================================

/// TCP server with cross-platform event loop.
pub const TcpServer = struct {
    // === Sockets ===
    /// Listening socket (null if not started).
    listen_fd: ?posix.fd_t = null,

    /// Cross-platform event poller (null if not started).
    poller: ?Poller = null,

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

    /// Idle timeout in seconds (0 = disabled).
    idle_timeout_secs: i64 = 300,

    // === Statistics ===
    total_connections: u64 = 0,
    total_disconnections: u64 = 0,
    accept_errors: u64 = 0,
    decode_errors: u64 = 0,
    idle_timeouts: u64 = 0,
    error_disconnects: u64 = 0,

    /// Poll cycle counter for periodic tasks.
    poll_cycles: u64 = 0,

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
        std.debug.assert(self.poller == null);

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

        // Create event poller
        var poller = try Poller.init();
        errdefer poller.deinit();

        // Add listen socket to poller
        try poller.addRead(listen_fd);

        self.listen_fd = listen_fd;
        self.poller = poller;

        const platform = if (is_linux) "epoll" else if (is_darwin) "kqueue" else "poll";
        std.log.info("TCP server listening on {s}:{} (framing={}, max_clients={}, backend={s}, idle_timeout={}s)", .{
            address,
            port,
            self.use_framing,
            MAX_CLIENTS,
            platform,
            self.idle_timeout_secs,
        });
    }

    /// Stop server and disconnect all clients.
    pub fn stop(self: *Self) void {
        // Disconnect all clients
        var iter = self.clients.getActive();
        while (iter.next()) |client| {
            self.disconnectClientInternal(client, false);
        }

        // Close poller
        if (self.poller) |*poller| {
            poller.deinit();
            self.poller = null;
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
        return self.listen_fd != null and self.poller != null;
    }

    // ========================================================================
    // Event Loop
    // ========================================================================

    /// Poll for events with timeout.
    /// Returns number of events processed.
    pub fn poll(self: *Self, timeout_ms: i32) !usize {
        var poller = self.poller orelse return error.NotStarted;
        const listen_fd = self.listen_fd orelse return error.NotStarted;

        var results: [MAX_EVENTS]PollResult = undefined;
        const events = try poller.wait(&results, timeout_ms);

        var processed: usize = 0;

        for (events) |ev| {
            if (ev.fd == listen_fd) {
                // New connection(s) pending
                self.acceptConnections();
                processed += 1;
            } else {
                // Client event
                if (self.clients.findByFd(ev.fd)) |client| {
                    self.handleClientEvent(client, ev.events);
                    processed += 1;
                }
            }
        }

        // Periodic idle timeout check
        self.poll_cycles += 1;
        if (self.idle_timeout_secs > 0 and self.poll_cycles % IDLE_CHECK_INTERVAL == 0) {
            self.checkIdleClients();
        }

        return processed;
    }

    /// Check for and disconnect idle clients.
    fn checkIdleClients(self: *Self) void {
        var iter = self.clients.getActive();
        while (iter.next()) |client| {
            if (client.getIdleDuration() > self.idle_timeout_secs) {
                std.log.info("Client {} idle timeout ({}s)", .{
                    client.client_id,
                    client.getIdleDuration(),
                });
                self.idle_timeouts += 1;
                self.disconnectClient(client);
            }
        }
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
        var poller = self.poller orelse return error.NotStarted;

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

        // Initialize client with collision-free ID
        const client_id = self.allocateClientId();
        client.* = TcpClient.init(client_fd, client_id);

        self.total_connections += 1;
        self.clients.active_count += 1;

        // Set socket options for low latency
        net_utils.setLowLatencyOptions(client_fd);

        // Add to poller
        try poller.addClient(client_fd);

        std.log.info("Client {} connected (fd={}, active={})", .{
            client_id,
            client_fd,
            self.clients.active_count,
        });
    }

    /// Handle event for a client.
    fn handleClientEvent(self: *Self, client: *TcpClient, events: EventType) void {
        // Check for errors or hangup first
        if (events.error_or_hup) {
            self.disconnectClient(client);
            return;
        }

        // Handle readable
        if (events.readable) {
            self.handleClientRead(client) catch |err| {
                if (err != error.WouldBlock) {
                    std.log.debug("Client {} read error: {}", .{ client.client_id, err });
                    self.disconnectClient(client);
                    return;
                }
            };
        }

        // Handle writable
        if (events.writable) {
            client.flushSend() catch |err| {
                std.log.debug("Client {} write error: {}", .{ client.client_id, err });
                self.disconnectClient(client);
                return;
            };

            // If send buffer drained, disable write events
            if (!client.hasPendingSend()) {
                self.updateClientPoller(client, false) catch {};
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
                    // Check if too many errors
                    if (client.recordDecodeError()) {
                        std.log.warn("Client {} exceeded error threshold, disconnecting", .{client.client_id});
                        self.error_disconnects += 1;
                        self.disconnectClient(client);
                        return;
                    }
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

                // Track consecutive errors
                if (client.recordDecodeError()) {
                    std.log.warn("Client {} exceeded error threshold, disconnecting", .{client.client_id});
                    self.error_disconnects += 1;
                    self.disconnectClient(client);
                    return;
                }

                processed += 1; // Skip one byte and retry
                continue;
            };

            // Successful decode - reset error counter
            client.resetErrors();

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

            // Track consecutive errors (but don't disconnect here - let caller handle)
            _ = client.recordDecodeError();
            return;
        };

        // Successful decode - reset error counter
        client.resetErrors();

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
        self.updateClientPoller(client, true) catch return false;

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
                self.updateClientPoller(client, true) catch {};
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

        // Remove from poller
        if (self.poller) |*poller| {
            poller.remove(fd);
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

    /// Update poller registration for client.
    fn updateClientPoller(self: *Self, client: *TcpClient, want_write: bool) !void {
        var poller = self.poller orelse return error.NotStarted;
        try poller.updateClient(client.fd, want_write);
    }

    /// Allocate next client ID, ensuring no collision with active clients.
    fn allocateClientId(self: *Self) config.ClientId {
        // Try up to MAX_CLIENTS times to find unused ID
        var attempts: u32 = 0;
        while (attempts < MAX_CLIENTS + 10) : (attempts += 1) {
            const id = self.next_client_id;

            // Advance to next ID
            self.next_client_id +%= 1;
            if (self.next_client_id == 0 or
                self.next_client_id >= config.CLIENT_ID_UDP_BASE)
            {
                self.next_client_id = 1;
            }

            // Check if ID is already in use
            if (self.clients.findById(id) == null) {
                return id;
            }
        }

        // Fallback (should never happen with MAX_CLIENTS=64)
        std.log.warn("Client ID allocation exhausted, using next ID", .{});
        const id = self.next_client_id;
        self.next_client_id +%= 1;
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
            .idle_timeouts = self.idle_timeouts,
            .error_disconnects = self.error_disconnects,
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

test "TcpServer client ID allocation no collision" {
    var server = TcpServer.init(std.testing.allocator);
    defer server.deinit();

    // Allocate several IDs
    var ids: [10]config.ClientId = undefined;
    for (&ids) |*id| {
        id.* = server.allocateClientId();
    }

    // Verify all unique
    for (ids, 0..) |id1, i| {
        for (ids[i + 1 ..]) |id2| {
            try std.testing.expect(id1 != id2);
        }
        try std.testing.expect(config.isTcpClient(id1));
    }
}

test "TcpServer statistics initialization" {
    var server = TcpServer.init(std.testing.allocator);
    defer server.deinit();

    const stats = server.getStats();

    try std.testing.expectEqual(@as(u32, 0), stats.current_clients);
    try std.testing.expectEqual(@as(u64, 0), stats.total_connections);
    try std.testing.expectEqual(@as(u64, 0), stats.total_messages_in);
    try std.testing.expectEqual(@as(u64, 0), stats.idle_timeouts);
    try std.testing.expectEqual(@as(u64, 0), stats.error_disconnects);
}

test "Poller creation" {
    var poller = try Poller.init();
    defer poller.deinit();
}
