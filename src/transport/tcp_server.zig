//! TCP server with cross-platform I/O multiplexing.
//!
//! Key change: Output queue processing happens BEFORE epoll_wait, matching
//! the C server's tcp_listener.c pattern exactly. This ensures maximum
//! output throughput.
//!
//! C server pattern (tcp_listener.c):
//!   while (!shutdown) {
//!       process_output_queues();  // FIRST - always
//!       epoll_wait(...);          // THEN wait for events
//!       handle_events();
//!   }
//!
//! Data flow:
//!   OutputRouter → Client.output_queue → processOutputQueues() → socket
//!
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const config = @import("config.zig");
const net_utils = @import("net_utils.zig");
const tcp_client = @import("tcp_client.zig");
const output_router = @import("../threading/output_router.zig");

pub const TcpClient = tcp_client.TcpClient;
pub const ClientState = tcp_client.ClientState;
pub const ClientStats = tcp_client.ClientStats;

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();
const is_bsd = builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd;

const linux = if (is_linux) std.os.linux else struct {};
const c = std.c;

const EVFILT_READ: i16 = if (is_darwin or is_bsd) c.EVFILT_READ else 0;
const EVFILT_WRITE: i16 = if (is_darwin or is_bsd) c.EVFILT_WRITE else 0;
const EV_ADD: u16 = if (is_darwin or is_bsd) c.EV_ADD else 0;
const EV_DELETE: u16 = if (is_darwin or is_bsd) c.EV_DELETE else 0;
const EV_CLEAR: u16 = if (is_darwin or is_bsd) c.EV_CLEAR else 0;
const EV_EOF: u16 = if (is_darwin or is_bsd) c.EV_EOF else 0;
const EV_ERROR: u16 = if (is_darwin or is_bsd) c.EV_ERROR else 0;

const EventType = struct {
    readable: bool = false,
    writable: bool = false,
    error_or_hup: bool = false,
};

const PollResult = struct {
    fd: posix.fd_t,
    events: EventType,
};

/// Maximum concurrent TCP clients.
/// Must not exceed output_router.MAX_TCP_CLIENTS for client ID compatibility.
pub const MAX_CLIENTS: u32 = 64;

const MAX_EVENTS: u32 = 64;
const LISTEN_BACKLOG: u31 = 128;
const IDLE_CHECK_INTERVAL: u32 = 100;
const MAX_ACCEPTS_PER_POLL: u32 = 16;
const MAX_FRAMES_PER_CHUNK: u32 = 256;
const MAX_FRAMES_PER_READ_EVENT: u32 = 65536;
const MAX_RAW_BYTES_PER_CHUNK: u32 = 16384;
const MAX_RAW_BYTES_PER_READ_EVENT: u32 = 1024 * 1024;
const SOCKET_BUFFER_SIZE: u32 = 2 * 1024 * 1024;

/// Maximum send() calls per EPOLLOUT event to prevent starvation
const MAX_SENDS_PER_WRITABLE: u32 = 512;

/// Maximum clients to process per output queue drain cycle
/// This matches C server's approach of processing all clients each iteration
const MAX_CLIENTS_PER_OUTPUT_CYCLE: u32 = MAX_CLIENTS;

/// Maximum client ID value - must fit within OutputRouter's registry.
/// Client IDs cycle through [1, MAX_CLIENT_ID_VALUE].
const MAX_CLIENT_ID_VALUE: config.ClientId = @intCast(output_router.MAX_TCP_CLIENTS - 1);

comptime {
    std.debug.assert(MAX_CLIENTS > 0);
    std.debug.assert(MAX_EVENTS > 0);
    std.debug.assert(MAX_ACCEPTS_PER_POLL > 0);
    std.debug.assert(MAX_FRAMES_PER_CHUNK > 0);
    std.debug.assert(MAX_FRAMES_PER_READ_EVENT >= MAX_FRAMES_PER_CHUNK);
    std.debug.assert(SOCKET_BUFFER_SIZE >= 64 * 1024);
    std.debug.assert(MAX_SENDS_PER_WRITABLE > 0);
    // Ensure MAX_CLIENTS fits in OutputRouter's registry
    std.debug.assert(MAX_CLIENTS <= output_router.MAX_TCP_CLIENTS);
    std.debug.assert(MAX_CLIENT_ID_VALUE > 0);
    std.debug.assert(MAX_CLIENT_ID_VALUE < output_router.MAX_TCP_CLIENTS);
}

pub const MessageCallback = *const fn (client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void;
pub const DisconnectCallback = *const fn (client_id: config.ClientId, ctx: ?*anyopaque) void;

/// Connect callback - called when a new client connects
/// Parameters: client_id, file descriptor, context
/// Returns: pointer to client's output queue (from OutputRouter), or null
pub const ConnectCallback = *const fn (client_id: config.ClientId, fd: posix.fd_t, ctx: ?*anyopaque) ?*tcp_client.OutputQueue;

pub const ServerStats = struct {
    current_clients: u32,
    total_connections: u64,
    total_disconnections: u64,
    total_messages_in: u64,
    total_messages_out: u64,
    total_bytes_in: u64,
    total_bytes_out: u64,
    accept_errors: u64,
    decode_errors: u64,
    idle_timeouts: u64,
    error_disconnects: u64,
};

const Poller = struct {
    fd: posix.fd_t,

    const Self = @This();

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

    pub fn addRead(self: *Self, fd: posix.fd_t) !void {
        if (is_linux) {
            var ev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = fd } };
            try epollCtl(self.fd, linux.EPOLL.CTL_ADD, fd, &ev);
        } else {
            var changelist = [_]posix.Kevent{makeKEvent(fd, EVFILT_READ, EV_ADD, 0)};
            _ = try posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null);
        }
    }

    pub fn addClient(self: *Self, fd: posix.fd_t) !void {
        if (is_linux) {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP,
                .data = .{ .fd = fd },
            };
            try epollCtl(self.fd, linux.EPOLL.CTL_ADD, fd, &ev);
        } else {
            var changelist = [_]posix.Kevent{makeKEvent(fd, EVFILT_READ, EV_ADD | EV_CLEAR, 0)};
            _ = try posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null);
        }
    }

    pub fn updateClient(self: *Self, fd: posix.fd_t, want_write: bool) !void {
        if (is_linux) {
            var events: u32 = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP;
            if (want_write) events |= linux.EPOLL.OUT;
            var ev = linux.epoll_event{ .events = events, .data = .{ .fd = fd } };
            try epollCtl(self.fd, linux.EPOLL.CTL_MOD, fd, &ev);
        } else {
            if (want_write) {
                var changelist = [_]posix.Kevent{makeKEvent(fd, EVFILT_WRITE, EV_ADD | EV_CLEAR, 0)};
                _ = try posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null);
            } else {
                var changelist = [_]posix.Kevent{makeKEvent(fd, EVFILT_WRITE, EV_DELETE, 0)};
                _ = posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null) catch {};
            }
        }
    }

    pub fn remove(self: *Self, fd: posix.fd_t) void {
        if (is_linux) {
            epollCtl(self.fd, linux.EPOLL.CTL_DEL, fd, null) catch {};
        } else {
            var changelist = [_]posix.Kevent{
                makeKEvent(fd, EVFILT_READ, EV_DELETE, 0),
                makeKEvent(fd, EVFILT_WRITE, EV_DELETE, 0),
            };
            _ = posix.kevent(self.fd, &changelist, &[_]posix.Kevent{}, null) catch {};
        }
    }

    pub fn wait(self: *Self, results: []PollResult, timeout_ms: i32) ![]PollResult {
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
        } else {
            var events: [MAX_EVENTS]posix.Kevent = undefined;
            var timeout_val: posix.timespec = .{
                .tv_sec = @intCast(@divTrunc(timeout_ms, 1000)),
                .tv_nsec = @intCast(@mod(timeout_ms, 1000) * 1_000_000),
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
                        .readable = ev.filter == EVFILT_READ,
                        .writable = ev.filter == EVFILT_WRITE,
                        .error_or_hup = (ev.flags & EV_EOF) != 0 or (ev.flags & EV_ERROR) != 0,
                    },
                };
            }
            return results[0..count];
        }
    }

    fn epollCtl(epfd: posix.fd_t, op: u32, fd: posix.fd_t, event: ?*linux.epoll_event) !void {
        const rc = linux.epoll_ctl(epfd, op, fd, event);
        if (rc != 0) return error.EpollCtlFailed;
    }

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

pub const TcpServer = struct {
    listen_fd: ?posix.fd_t = null,
    poller: ?Poller = null,
    clients: tcp_client.ClientPool(MAX_CLIENTS) = .{},
    next_client_id: config.ClientId = 1,

    on_message: ?MessageCallback = null,
    on_disconnect: ?DisconnectCallback = null,
    on_connect: ?ConnectCallback = null,
    callback_ctx: ?*anyopaque = null,

    use_framing: bool = true,
    idle_timeout_secs: i64 = 300,

    total_connections: u64 = 0,
    total_disconnections: u64 = 0,
    accept_errors: u64 = 0,
    decode_errors: u64 = 0,
    idle_timeouts: u64 = 0,
    error_disconnects: u64 = 0,
    poll_cycles: u64 = 0,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    pub fn start(self: *Self, address: []const u8, port: u16) !void {
        const listen_fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(listen_fd);

        try net_utils.setReuseAddr(listen_fd);

        const addr = try net_utils.parseSockAddr(address, port);
        try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try posix.listen(listen_fd, LISTEN_BACKLOG);

        var poller = try Poller.init();
        errdefer poller.deinit();
        try poller.addRead(listen_fd);

        self.listen_fd = listen_fd;
        self.poller = poller;

        const platform = if (is_linux) "epoll" else if (is_darwin) "kqueue" else "poll";
        std.log.info("TCP server listening on {s}:{} (framing={}, max_clients={}, backend={s}, idle_timeout={}s, max_client_id={})", .{
            address, port, self.use_framing, MAX_CLIENTS, platform, self.idle_timeout_secs, MAX_CLIENT_ID_VALUE,
        });
    }

    pub fn stop(self: *Self) void {
        var iter = self.clients.getActive();
        while (iter.next()) |client| self.disconnectClientInternal(client, false);

        if (self.poller) |*poller| {
            poller.deinit();
            self.poller = null;
        }
        if (self.listen_fd) |fd| {
            posix.close(fd);
            self.listen_fd = null;
        }
        std.log.info("TCP server stopped (total connections: {})", .{self.total_connections});
    }

    pub fn isRunning(self: *const Self) bool {
        return self.listen_fd != null and self.poller != null;
    }

    /// Main poll function - processes output queues FIRST (like C server),
    /// then waits for events.
    pub fn poll(self: *Self, timeout_ms: i32) !usize {
        var poller = self.poller orelse return error.NotStarted;
        const listen_fd = self.listen_fd orelse return error.NotStarted;

        // ================================================================
        // CRITICAL: Process output queues FIRST, before epoll_wait
        // This matches C server's tcp_listener.c architecture exactly
        // ================================================================
        const has_output_work = self.processOutputQueues();

        // Use timeout=0 if we have pending output work to maintain throughput
        // This ensures we don't block waiting for input when outputs are ready
        const effective_timeout = if (has_output_work) 0 else timeout_ms;

        // Now wait for events
        var results: [MAX_EVENTS]PollResult = undefined;
        const events = try poller.wait(&results, effective_timeout);

        var processed: usize = 0;
        for (events) |ev| {
            if (ev.fd == listen_fd) {
                self.acceptConnections();
                processed += 1;
            } else if (self.clients.findByFd(ev.fd)) |client| {
                self.handleClientEvent(client, ev.events);
                processed += 1;
            }
        }

        self.poll_cycles += 1;
        if (self.idle_timeout_secs > 0 and self.poll_cycles % IDLE_CHECK_INTERVAL == 0) {
            self.checkIdleClients();
        }

        return processed;
    }

    /// Process all client output queues - matches C server's process_output_queues()
    ///
    /// Key behaviors from C server:
    /// 1. Skip clients that already have pending writes (has_pending_write)
    /// 2. Dequeue ONE message from the queue
    /// 3. Format it into the write buffer
    /// 4. Try immediate write()
    /// 5. If partial write or EAGAIN, enable EPOLLOUT
    /// 6. Loop continues to next client
    ///
    /// Returns true if any client has more output work pending
    fn processOutputQueues(self: *Self) bool {
        var clients_processed: u32 = 0;
        var has_more_work: bool = false;
        var iter = self.clients.getActive();

        while (iter.next()) |client| {
            if (clients_processed >= MAX_CLIENTS_PER_OUTPUT_CYCLE) break;
            clients_processed += 1;

            // Skip if already has pending write data (matches C server)
            // This prevents piling up multiple messages in the send buffer
            if (client.hasPendingSend()) {
                has_more_work = true;
                continue;
            }

            // Check if there are messages in the output queue
            if (!client.hasOutputQueueMessages()) {
                continue;
            }

            // Drain ONE message from output queue into send buffer
            const drained = client.drainOutputQueueOne();
            if (drained == 0) {
                continue;
            }

            // Track if there's more work after draining one
            if (client.hasOutputQueueMessages()) {
                has_more_work = true;
            }

            // Try immediate write (like C server's process_output_queues)
            client.flushSend() catch |err| {
                if (err == error.WouldBlock) {
                    // Socket buffer full - enable EPOLLOUT
                    self.updateClientPoller(client, true) catch {};
                    has_more_work = true;
                } else {
                    // Fatal error - will be cleaned up later
                    self.error_disconnects += 1;
                }
                continue;
            };

            // If we still have pending data after flush, enable EPOLLOUT
            if (client.hasPendingSend()) {
                self.updateClientPoller(client, true) catch {};
                has_more_work = true;
            }
        }

        return has_more_work;
    }

    /// Legacy method - now just calls processOutputQueues
    /// Kept for backward compatibility
    pub fn drainAllClientOutputQueues(self: *Self) void {
        self.processOutputQueues();
    }

    fn checkIdleClients(self: *Self) void {
        var iter = self.clients.getActive();
        while (iter.next()) |client| {
            if (client.getIdleDuration() > self.idle_timeout_secs) {
                self.idle_timeouts += 1;
                self.disconnectClient(client);
            }
        }
    }

    fn acceptConnections(self: *Self) void {
        const listen_fd = self.listen_fd orelse return;
        var accepted: u32 = 0;

        while (accepted < MAX_ACCEPTS_PER_POLL) : (accepted += 1) {
            self.acceptOne(listen_fd) catch |err| {
                if (err == error.WouldBlock) break;
                self.accept_errors += 1;
                if (err != error.SystemResources and err != error.ProcessFdQuotaExceeded) break;
            };
        }
    }

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

        const sock_buf_size: u32 = SOCKET_BUFFER_SIZE;
        posix.setsockopt(client_fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(sock_buf_size)) catch {};
        posix.setsockopt(client_fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(sock_buf_size)) catch {};

        const client_slot = self.clients.allocate() orelse {
            posix.close(client_fd);
            return;
        };

        const client_id = self.allocateClientId();

        client_slot.* = TcpClient.init(self.allocator, client_fd, client_id) catch {
            posix.close(client_fd);
            return;
        };

        self.total_connections += 1;
        self.clients.active_count += 1;

        net_utils.setLowLatencyOptions(client_fd);

        poller.addClient(client_fd) catch {
            client_slot.reset();
            self.clients.active_count -= 1;
            return;
        };

        std.log.info("Client {} connected (fd={}, active={})", .{ client_id, client_fd, self.clients.active_count });

        // Invoke connect callback to register with OutputRouter and get output queue
        if (self.on_connect) |cb| {
            if (cb(client_id, client_fd, self.callback_ctx)) |output_queue| {
                client_slot.setOutputQueue(output_queue);
            }
        }
    }

    fn handleClientEvent(self: *Self, client: *TcpClient, events: EventType) void {
        if (events.error_or_hup) {
            self.disconnectClient(client);
            return;
        }

        if (events.readable) {
            self.handleClientRead(client) catch |err| {
                if (err != error.WouldBlock) self.disconnectClient(client);
            };
        }

        // Handle EPOLLOUT - drain remaining send buffer and more output queue
        if (events.writable) {
            self.handleClientWrite(client);
        }
    }

    /// Handle writable event - continues draining send buffer and output queue.
    /// This is triggered when socket becomes writable after a previous EAGAIN.
    fn handleClientWrite(self: *Self, client: *TcpClient) void {
        var sends: u32 = 0;

        // Loop until WouldBlock or no more work (bounded for safety)
        while (sends < MAX_SENDS_PER_WRITABLE) : (sends += 1) {
            // First, try to flush any pending send buffer data
            if (client.hasPendingSend()) {
                client.flushSend() catch |err| {
                    if (err == error.WouldBlock) {
                        // Socket buffer full, wait for next EPOLLOUT
                        return;
                    }
                    // Fatal error
                    self.disconnectClient(client);
                    return;
                };

                // If we still have pending data, keep EPOLLOUT enabled and return
                if (client.hasPendingSend()) {
                    return;
                }
            }

            // Send buffer is empty - try to drain ONE more message from output queue
            if (client.hasOutputQueueMessages()) {
                const drained = client.drainOutputQueueOne();
                if (drained > 0) {
                    // We added data to send buffer, loop to send it
                    continue;
                }
            }

            // No more work - disable EPOLLOUT
            self.updateClientPoller(client, false) catch {};
            return;
        }
        // Hit iteration limit - EPOLLOUT will fire again
    }

    fn handleClientRead(self: *Self, client: *TcpClient) !void {
        // Drain socket (ET requirement)
        while (true) {
            _ = client.receive() catch |err| {
                if (err == error.WouldBlock) break;
                if (err == error.BufferFull) break;
                return err;
            };
        }

        // Drain USER BUFFER too (ET requirement)
        if (self.use_framing) {
            var total: u32 = 0;
            while (total < MAX_FRAMES_PER_READ_EVENT) {
                const n = self.processFramedMessagesChunk(client, MAX_FRAMES_PER_CHUNK);
                if (n == 0) break;
                total += n;
            }
        } else {
            var total_bytes: u32 = 0;
            while (total_bytes < MAX_RAW_BYTES_PER_READ_EVENT) {
                const n = self.processRawMessagesChunk(client, MAX_RAW_BYTES_PER_CHUNK);
                if (n == 0) break;
                total_bytes += n;
            }
        }
    }

    fn processFramedMessagesChunk(self: *Self, client: *TcpClient, max_frames: u32) u32 {
        var frames_processed: u32 = 0;

        while (frames_processed < max_frames) : (frames_processed += 1) {
            const frame_result = client.extractFrame();

            switch (frame_result) {
                .frame => |payload| {
                    if (client.protocol == .unknown) client.protocol = codec.detectProtocol(payload);
                    self.decodeAndDispatch(client, payload);
                    client.consumeFrame(payload.len);
                },
                .incomplete, .empty => return frames_processed,
                .oversized => {
                    if (client.recordDecodeError()) {
                        self.error_disconnects += 1;
                        self.disconnectClient(client);
                        return frames_processed;
                    }
                    continue;
                },
            }
        }
        return frames_processed;
    }

    fn processRawMessagesChunk(self: *Self, client: *TcpClient, max_bytes: u32) u32 {
        var processed: u32 = 0;
        const data = client.getReceivedData();
        if (data.len == 0) return 0;

        const max_process = @min(@as(u32, @intCast(data.len)), max_bytes);

        while (processed < max_process) {
            const remaining = data[processed..];

            if (client.protocol == .unknown) {
                client.protocol = codec.detectProtocol(remaining);
                if (client.protocol == .unknown and remaining.len < 8) break;
            }

            const result = codec.Codec.decodeInput(remaining) catch |err| {
                if (err == codec.CodecError.IncompleteMessage) break;
                self.decode_errors += 1;

                if (client.recordDecodeError()) {
                    self.error_disconnects += 1;
                    self.disconnectClient(client);
                    return processed;
                }
                processed += 1;
                continue;
            };

            client.resetErrors();
            if (self.on_message) |cb| cb(client.client_id, &result.message, self.callback_ctx);
            client.stats.messages_received += 1;
            processed += @intCast(result.bytes_consumed);
        }

        if (processed > 0) client.consumeBytes(processed);
        return processed;
    }

    fn decodeAndDispatch(self: *Self, client: *TcpClient, payload: []const u8) void {
        const result = codec.Codec.decodeInput(payload) catch {
            self.decode_errors += 1;
            _ = client.recordDecodeError();
            return;
        };
        client.resetErrors();
        if (self.on_message) |cb| cb(client.client_id, &result.message, self.callback_ctx);
    }

    // ========================================================================
    // Send Operations (for direct sends, bypassing OutputRouter)
    // ========================================================================

    pub fn send(self: *Self, client_id: config.ClientId, data: []const u8) bool {
        const client = self.clients.findById(client_id) orelse return false;

        const ok = if (self.use_framing) client.queueFramedSend(data) else client.queueRawSend(data);
        if (!ok) return false;

        client.recordMessageSent();

        if (client.hasPendingSend()) {
            self.updateClientPoller(client, true) catch return false;
        }

        return true;
    }

    pub fn broadcast(self: *Self, data: []const u8) u32 {
        var sent_count: u32 = 0;
        var iter = self.clients.getActive();

        while (iter.next()) |client| {
            if (client.state != .connected) continue;
            const ok = if (self.use_framing) client.queueFramedSend(data) else client.queueRawSend(data);
            if (!ok) continue;
            client.recordMessageSent();

            if (client.hasPendingSend()) self.updateClientPoller(client, true) catch {};
            sent_count += 1;
        }

        return sent_count;
    }

    // ========================================================================
    // Client Management
    // ========================================================================

    pub fn disconnectClient(self: *Self, client: *TcpClient) void {
        self.disconnectClientInternal(client, true);
    }

    fn disconnectClientInternal(self: *Self, client: *TcpClient, invoke_callback: bool) void {
        if (client.state == .disconnected) return;

        const client_id = client.client_id;
        const fd = client.fd;

        if (self.poller) |*poller| poller.remove(fd);

        client.reset();
        self.clients.active_count -= 1;
        self.total_disconnections += 1;

        if (invoke_callback) {
            if (self.on_disconnect) |cb| cb(client_id, self.callback_ctx);
        }
    }

    pub fn updateClientPoller(self: *Self, client: *TcpClient, want_write: bool) !void {
        var poller = self.poller orelse return error.NotStarted;
        try poller.updateClient(client.fd, want_write);
    }

    /// Enable EPOLLOUT for a client by ID (for use from other threads)
    pub fn enableWriteForClient(self: *Self, client_id: config.ClientId) void {
        if (self.clients.findById(client_id)) |client| {
            self.updateClientPoller(client, true) catch {};
        }
    }

    /// Allocate a unique client ID in range [1, MAX_CLIENT_ID_VALUE].
    /// This ensures client IDs fit within OutputRouter's registry.
    fn allocateClientId(self: *Self) config.ClientId {
        var attempts: u32 = 0;
        const max_attempts = MAX_CLIENTS + 10;

        while (attempts < max_attempts) : (attempts += 1) {
            const id = self.next_client_id;

            // Advance to next ID, wrapping within valid range
            self.next_client_id += 1;
            if (self.next_client_id > MAX_CLIENT_ID_VALUE) {
                self.next_client_id = 1;
            }

            // Check if ID is available (not in use by active client)
            if (self.clients.findById(id) == null) return id;
        }

        // Fallback (should rarely happen with MAX_CLIENTS << MAX_CLIENT_ID_VALUE)
        const id = self.next_client_id;
        self.next_client_id += 1;
        if (self.next_client_id > MAX_CLIENT_ID_VALUE) {
            self.next_client_id = 1;
        }
        return id;
    }

    pub fn getStats(self: *const Self) ServerStats {
        const agg = self.clients.getAggregateStats();
        return .{
            .current_clients = self.clients.active_count,
            .total_connections = self.total_connections,
            .total_disconnections = self.total_disconnections,
            .total_messages_in = agg.total_messages_in,
            .total_messages_out = agg.total_messages_out,
            .total_bytes_in = agg.total_bytes_in,
            .total_bytes_out = agg.total_bytes_out,
            .accept_errors = self.accept_errors,
            .decode_errors = self.decode_errors,
            .idle_timeouts = self.idle_timeouts,
            .error_disconnects = self.error_disconnects,
        };
    }

    pub fn getClientCount(self: *const Self) u32 {
        return self.clients.active_count;
    }
};
