//! TCP Server - Multi-Client TCP Listener
const std = @import("std");
const net = std.net;
const posix = std.posix;
const TcpConnection = @import("tcp_connection.zig").TcpConnection;
const ConnectionState = @import("tcp_connection.zig").ConnectionState;
const framing = @import("framing.zig");
const msg = @import("../protocol/message_types.zig");
const SpscQueue = @import("../threading/spsc_queue.zig");
const InputEnvelope = SpscQueue.InputEnvelope;
const OutputEnvelope = SpscQueue.OutputEnvelope;
const InputEnvelopeQueue = SpscQueue.InputEnvelopeQueue;
const OutputEnvelopeQueue = SpscQueue.OutputEnvelopeQueue;

pub const MAX_CLIENTS: u32 = 256;
pub const POLL_TIMEOUT_MS: i32 = 1;
pub const MAX_POLL_EVENTS: usize = 256;
pub const ACCEPT_BATCH_SIZE: u32 = 8;

pub const ServerState = enum {
    stopped,
    starting,
    running,
    stopping,
};

pub const ServerStats = struct {
    connections_accepted: u64,
    connections_closed: u64,
    messages_received: u64,
    messages_sent: u64,
    bytes_received: u64,
    bytes_sent: u64,
    accept_errors: u64,
    current_clients: u32,
    send_buffer_full: u64,

    pub fn init() ServerStats {
        return ServerStats{
            .connections_accepted = 0,
            .connections_closed = 0,
            .messages_received = 0,
            .messages_sent = 0,
            .bytes_received = 0,
            .bytes_sent = 0,
            .accept_errors = 0,
            .current_clients = 0,
            .send_buffer_full = 0,
        };
    }
};

const ClientSlot = struct {
    connection: ?TcpConnection,
    active: bool,

    pub fn init() ClientSlot {
        return ClientSlot{
            .connection = null,
            .active = false,
        };
    }

    pub fn isActive(self: *const ClientSlot) bool {
        return self.active and self.connection != null;
    }
};

pub const TcpServer = struct {
    listener: ?net.Server,
    clients: [MAX_CLIENTS]ClientSlot,
    next_client_id: u32,
    state: ServerState,
    stats: ServerStats,
    poll_fds: [MAX_CLIENTS + 1]posix.pollfd,
    poll_fd_count: usize,
    input_queue: ?*InputEnvelopeQueue,
    output_queue: ?*OutputEnvelopeQueue,
    input_sequence: u64,

    const Self = @This();

    pub fn initInPlace(self: *Self) void {
        self.listener = null;
        self.next_client_id = 1;
        self.state = .stopped;
        self.stats = ServerStats.init();
        self.poll_fd_count = 0;
        self.input_queue = null;
        self.output_queue = null;
        self.input_sequence = 0;

        for (&self.clients) |*slot| {
            slot.* = ClientSlot.init();
        }

        for (&self.poll_fds) |*pfd| {
            pfd.fd = -1;
            pfd.events = 0;
            pfd.revents = 0;
        }
    }

    pub fn init() Self {
        var self: Self = undefined;
        self.initInPlace();
        return self;
    }

    pub fn start(self: *Self, address: net.Address) !void {
        std.debug.assert(self.state == .stopped);
        self.state = .starting;
        self.listener = try address.listen(.{
            .reuse_address = true,
        });
        const flags = try posix.fcntl(self.listener.?.stream.handle, posix.F.GETFL, 0);
        _ = try posix.fcntl(
            self.listener.?.stream.handle,
            posix.F.SETFL,
            flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
        );
        self.state = .running;
    }

    pub fn stop(self: *Self) void {
        if (self.state != .running) return;
        self.state = .stopping;
        for (&self.clients) |*slot| {
            if (slot.connection) |*conn| {
                conn.close();
                slot.active = false;
                slot.connection = null;
            }
        }
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }
        self.state = .stopped;
    }

    pub fn setQueues(self: *Self, input: *InputEnvelopeQueue, output: *OutputEnvelopeQueue) void {
        self.input_queue = input;
        self.output_queue = output;
    }

    pub fn poll(self: *Self) !u32 {
        if (self.state != .running) return 0;
        var events_processed: u32 = 0;
        events_processed += try self.acceptConnections();
        events_processed += self.processOutputQueue();
        self.buildPollFds();
        if (self.poll_fd_count > 0) {
            const ready = posix.poll(self.poll_fds[0..self.poll_fd_count], POLL_TIMEOUT_MS) catch {
                return events_processed;
            };
            if (ready > 0) {
                events_processed += try self.handlePollEvents();
            }
        }
        self.cleanupDisconnected();
        return events_processed;
    }

    /// Non-blocking poll - no timeout, returns immediately
    pub fn pollNonBlocking(self: *Self) !u32 {
        if (self.state != .running) return 0;
        var events_processed: u32 = 0;
        events_processed += try self.acceptConnections();
        self.buildPollFds();
        if (self.poll_fd_count > 0) {
            const ready = posix.poll(self.poll_fds[0..self.poll_fd_count], 0) catch {
                return events_processed;
            };
            if (ready > 0) {
                events_processed += try self.handlePollEvents();
            }
        }
        self.cleanupDisconnected();
        return events_processed;
    }

    /// Drain output queue and send to clients - returns number processed
    pub fn drainAndSend(self: *Self) u32 {
        var processed: u32 = 0;
        processed += self.processOutputQueue();
        // Try to send after processing
        for (&self.clients) |*slot| {
            if (slot.isActive()) {
                if (slot.connection) |*conn| {
                    _ = conn.trySend() catch {};
                }
            }
        }
        return processed;
    }

    /// Check if there are any active clients
    pub fn hasActiveClients(self: *Self) bool {
        return self.stats.current_clients > 0;
    }

    pub fn run(self: *Self) !void {
        while (self.state == .running) {
            _ = try self.poll();
        }
    }

    fn acceptConnections(self: *Self) !u32 {
        var accepted: u32 = 0;
        while (accepted < ACCEPT_BATCH_SIZE) {
            const accept_result = self.listener.?.accept() catch |err| {
                switch (err) {
                    error.WouldBlock => break,
                    else => {
                        self.stats.accept_errors += 1;
                        break;
                    },
                }
            };

            const slot_idx = self.findFreeSlot() orelse {
                accept_result.stream.close();
                break;
            };
            const client_id = self.next_client_id;
            self.next_client_id += 1;
            var conn = TcpConnection.init(client_id, accept_result.stream, accept_result.address);
            conn.setNonBlocking(true) catch {};
            conn.setNoDelay(true) catch {};
            self.clients[slot_idx].connection = conn;
            self.clients[slot_idx].active = true;
            self.stats.connections_accepted += 1;
            self.stats.current_clients += 1;
            accepted += 1;

            // Log connection
            std.debug.print("[TCP] Client {d} connected\n", .{client_id});
        }
        return accepted;
    }

    fn processOutputQueue(self: *Self) u32 {
        const output_queue = self.output_queue orelse return 0;
        var processed: u32 = 0;

        // Drain ALL available messages from output queue
        while (true) {
            const envelope = output_queue.pop() orelse break;
            if (envelope.client_id == 0) {
                self.broadcastMessage(&envelope.message);
            } else {
                self.sendToClient(envelope.client_id, &envelope.message);
            }
            processed += 1;
            self.stats.messages_sent += 1;
        }
        return processed;
    }

    fn broadcastMessage(self: *Self, message: *const msg.OutputMsg) void {
        for (&self.clients) |*slot| {
            if (slot.isActive()) {
                if (slot.connection) |*conn| {
                    if (!conn.queueMessage(message)) {
                        self.stats.send_buffer_full += 1;
                    }
                    _ = conn.trySend() catch {};
                }
            }
        }
    }

    fn sendToClient(self: *Self, client_id: u32, message: *const msg.OutputMsg) void {
        for (&self.clients) |*slot| {
            if (slot.isActive()) {
                if (slot.connection) |*conn| {
                    if (conn.client_id == client_id) {
                        if (!conn.queueMessage(message)) {
                            self.stats.send_buffer_full += 1;
                        }
                        _ = conn.trySend() catch {};
                        return;
                    }
                }
            }
        }
    }

    fn buildPollFds(self: *Self) void {
        self.poll_fd_count = 0;
        if (self.listener) |listener| {
            self.poll_fds[self.poll_fd_count] = .{
                .fd = listener.stream.handle,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            self.poll_fd_count += 1;
        }
        for (&self.clients) |*slot| {
            if (slot.isActive()) {
                if (slot.connection) |*conn| {
                    var events: i16 = posix.POLL.IN;
                    if (conn.hasPendingData()) {
                        events |= posix.POLL.OUT;
                    }
                    self.poll_fds[self.poll_fd_count] = .{
                        .fd = conn.getFd(),
                        .events = events,
                        .revents = 0,
                    };
                    self.poll_fd_count += 1;
                }
            }
        }
    }

    fn handlePollEvents(self: *Self) !u32 {
        var events_handled: u32 = 0;
        var fd_idx: usize = 1;
        for (&self.clients) |*slot| {
            if (!slot.isActive()) continue;
            if (fd_idx >= self.poll_fd_count) break;
            const pfd = &self.poll_fds[fd_idx];
            fd_idx += 1;
            if (pfd.revents == 0) continue;
            if (slot.connection) |*conn| {
                if (pfd.revents & posix.POLL.IN != 0) {
                    events_handled += try self.handleClientRead(conn);
                }
                if (pfd.revents & posix.POLL.OUT != 0) {
                    _ = conn.trySend() catch {};
                    events_handled += 1;
                }
                if (pfd.revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                    conn.state = .disconnecting;
                }
            }
        }
        return events_handled;
    }

    fn handleClientRead(self: *Self, conn: *TcpConnection) !u32 {
        var messages_received: u32 = 0;
        const received = conn.tryReceive() catch false;

        if (received) {
            while (conn.nextMessage()) |message| {
                self.stats.messages_received += 1;
                messages_received += 1;
                if (self.input_queue) |queue| {
                    const envelope = InputEnvelope{
                        .message = message,
                        .client_id = conn.client_id,
                        ._pad = undefined,
                    };
                    _ = queue.push(envelope);
                    self.input_sequence += 1;
                }
            }
        }
        self.stats.bytes_received += conn.stats.bytes_received;
        return messages_received;
    }

    fn cleanupDisconnected(self: *Self) void {
        for (&self.clients) |*slot| {
            if (slot.connection) |*conn| {
                if (conn.state == .disconnecting or conn.state == .disconnected) {
                    const client_id = conn.client_id;
                    conn.close();
                    slot.active = false;
                    slot.connection = null;
                    self.stats.connections_closed += 1;
                    self.stats.current_clients -= 1;

                    // Log disconnection
                    std.debug.print("[TCP] Client {d} disconnected\n", .{client_id});
                }
            }
        }
    }

    fn findFreeSlot(self: *Self) ?usize {
        for (&self.clients, 0..) |*slot, idx| {
            if (!slot.active) {
                return idx;
            }
        }
        return null;
    }

    pub fn getStats(self: *const Self) ServerStats {
        return self.stats;
    }

    pub fn getClientCount(self: *const Self) u32 {
        return self.stats.current_clients;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.state == .running;
    }

    pub fn getClient(self: *Self, client_id: u32) ?*TcpConnection {
        for (&self.clients) |*slot| {
            if (slot.isActive()) {
                if (slot.connection) |*conn| {
                    if (conn.client_id == client_id) {
                        return conn;
                    }
                }
            }
        }
        return null;
    }

    pub fn disconnectClient(self: *Self, client_id: u32) void {
        if (self.getClient(client_id)) |conn| {
            conn.state = .disconnecting;
        }
    }

    pub fn flushAllClients(self: *Self) void {
        for (&self.clients) |*slot| {
            if (slot.isActive()) {
                if (slot.connection) |*conn| {
                    var attempts: u32 = 0;
                    while (conn.hasPendingData() and attempts < 100) : (attempts += 1) {
                        const sent = conn.trySend() catch break;
                        if (sent == 0) break;
                    }
                }
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================
test "server init" {
    var server: TcpServer = undefined;
    server.initInPlace();
    try std.testing.expectEqual(ServerState.stopped, server.state);
    try std.testing.expectEqual(@as(u32, 0), server.stats.current_clients);
}

test "server stats init" {
    const stats = ServerStats.init();
    try std.testing.expectEqual(@as(u64, 0), stats.connections_accepted);
    try std.testing.expectEqual(@as(u64, 0), stats.messages_sent);
}

test "client slot" {
    var slot = ClientSlot.init();
    try std.testing.expect(!slot.isActive());
}

test "find free slot" {
    var server: TcpServer = undefined;
    server.initInPlace();
    const slot = server.findFreeSlot();
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(@as(usize, 0), slot.?);
}
