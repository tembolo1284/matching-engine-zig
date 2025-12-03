//! TCP server with 4-byte length-prefix framing.
//!
//! Wire format:
//!   [4 bytes big-endian length][payload]
//!
//! This matches the C protocol specification.

const std = @import("std");
const posix = std.posix;
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const config = @import("config.zig");

const MAX_CLIENTS = 1024;
const RECV_BUFFER_SIZE = 65536;
const SEND_BUFFER_SIZE = 65536;
const MAX_EVENTS = 64;
const FRAME_HEADER_SIZE = 4;
const MAX_MESSAGE_SIZE = 16384;

pub const ClientState = enum {
    disconnected,
    connected,
    draining,
};

pub const TcpClient = struct {
    fd: posix.fd_t = -1,
    client_id: config.ClientId = 0,
    state: ClientState = .disconnected,

    recv_buf: [RECV_BUFFER_SIZE]u8 = undefined,
    recv_len: usize = 0,

    send_buf: [SEND_BUFFER_SIZE]u8 = undefined,
    send_len: usize = 0,
    send_pos: usize = 0,

    protocol: codec.Protocol = .unknown,

    messages_received: u64 = 0,
    messages_sent: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,

    const Self = @This();

    pub fn reset(self: *Self) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
        }
        self.* = .{};
    }

    /// Queue a framed message for sending (adds 4-byte length prefix)
    pub fn queueFramedSend(self: *Self, data: []const u8) bool {
        const frame_size = FRAME_HEADER_SIZE + data.len;
        const available = SEND_BUFFER_SIZE - self.send_len;
        if (frame_size > available) return false;

        // Write length header (big-endian)
        const len_bytes = self.send_buf[self.send_len..][0..4];
        std.mem.writeInt(u32, len_bytes, @intCast(data.len), .big);
        self.send_len += 4;

        // Write payload
        @memcpy(self.send_buf[self.send_len..][0..data.len], data);
        self.send_len += data.len;

        return true;
    }

    /// Queue raw data (no framing - for responses in same format as received)
    pub fn queueSend(self: *Self, data: []const u8) bool {
        const available = SEND_BUFFER_SIZE - self.send_len;
        if (data.len > available) return false;

        @memcpy(self.send_buf[self.send_len..][0..data.len], data);
        self.send_len += data.len;
        return true;
    }

    pub fn flushSend(self: *Self) !void {
        while (self.send_pos < self.send_len) {
            const sent = posix.send(self.fd, self.send_buf[self.send_pos..self.send_len], 0) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };
            self.send_pos += sent;
            self.bytes_sent += sent;
        }

        if (self.send_pos == self.send_len) {
            self.send_pos = 0;
            self.send_len = 0;
        }
    }

    pub fn hasPendingSend(self: *const Self) bool {
        return self.send_pos < self.send_len;
    }

    /// Try to extract a complete framed message from the receive buffer.
    /// Returns the payload slice (without header) or null if incomplete.
    pub fn extractFrame(self: *Self) ?[]const u8 {
        if (self.recv_len < FRAME_HEADER_SIZE) return null;

        const msg_len = std.mem.readInt(u32, self.recv_buf[0..4], .big);
        if (msg_len > MAX_MESSAGE_SIZE) {
            // Invalid frame - skip the header and try to recover
            self.compactBuffer(FRAME_HEADER_SIZE);
            return null;
        }

        const total_len = FRAME_HEADER_SIZE + msg_len;
        if (self.recv_len < total_len) return null;

        return self.recv_buf[FRAME_HEADER_SIZE..total_len];
    }

    /// Remove processed bytes from buffer
    pub fn compactBuffer(self: *Self, bytes: usize) void {
        if (bytes >= self.recv_len) {
            self.recv_len = 0;
            return;
        }

        const remaining = self.recv_len - bytes;
        std.mem.copyForwards(u8, self.recv_buf[0..remaining], self.recv_buf[bytes..self.recv_len]);
        self.recv_len = remaining;
    }
};

pub const TcpServer = struct {
    listen_fd: posix.fd_t = -1,
    epoll_fd: posix.fd_t = -1,

    clients: [MAX_CLIENTS]TcpClient = [_]TcpClient{.{}} ** MAX_CLIENTS,
    client_count: usize = 0,
    next_client_id: config.ClientId = 1,

    on_message: ?*const fn (client_id: config.ClientId, message: *const msg.InputMsg, ctx: ?*anyopaque) void = null,
    on_disconnect: ?*const fn (client_id: config.ClientId, ctx: ?*anyopaque) void = null,
    callback_ctx: ?*anyopaque = null,

    total_connections: u64 = 0,
    total_disconnections: u64 = 0,

    use_framing: bool = true, // Enable TCP framing by default

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    pub fn start(self: *Self, address: []const u8, port: u16) !void {
        self.listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(self.listen_fd);

        try posix.setsockopt(self.listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        var addr = try parseAddress(address, port);
        try posix.bind(self.listen_fd, &addr, @sizeOf(@TypeOf(addr)));
        try posix.listen(self.listen_fd, 128);

        self.epoll_fd = try posix.epoll_create1(0);
        errdefer posix.close(self.epoll_fd);

        var ev = posix.epoll_event{
            .events = posix.EPOLL.IN,
            .data = .{ .fd = self.listen_fd },
        };
        try posix.epoll_ctl(self.epoll_fd, posix.EPOLL.CTL_ADD, self.listen_fd, &ev);

        std.log.info("TCP server listening on {s}:{} (framing={})", .{ address, port, self.use_framing });
    }

    pub fn stop(self: *Self) void {
        for (&self.clients) |*client| {
            if (client.state != .disconnected) {
                client.reset();
            }
        }
        self.client_count = 0;

        if (self.epoll_fd >= 0) {
            posix.close(self.epoll_fd);
            self.epoll_fd = -1;
        }

        if (self.listen_fd >= 0) {
            posix.close(self.listen_fd);
            self.listen_fd = -1;
        }
    }

    pub fn poll(self: *Self, timeout_ms: i32) !usize {
        var events: [MAX_EVENTS]posix.epoll_event = undefined;

        const n = posix.epoll_wait(self.epoll_fd, &events, timeout_ms);

        for (events[0..n]) |ev| {
            if (ev.data.fd == self.listen_fd) {
                self.acceptConnection() catch |err| {
                    std.log.warn("Accept failed: {}", .{err});
                };
            } else {
                const client_idx = self.findClientByFd(ev.data.fd) orelse continue;
                const client = &self.clients[client_idx];

                if (ev.events & posix.EPOLL.IN != 0) {
                    self.handleClientRead(client) catch |err| {
                        std.log.debug("Client {} read error: {}", .{ client.client_id, err });
                        self.disconnectClient(client);
                    };
                }

                if (ev.events & posix.EPOLL.OUT != 0) {
                    client.flushSend() catch |err| {
                        std.log.debug("Client {} write error: {}", .{ client.client_id, err });
                        self.disconnectClient(client);
                    };

                    if (!client.hasPendingSend()) {
                        self.updateClientEpoll(client, false) catch {};
                    }
                }

                if (ev.events & (posix.EPOLL.ERR | posix.EPOLL.HUP) != 0) {
                    self.disconnectClient(client);
                }
            }
        }

        return n;
    }

    pub fn send(self: *Self, client_id: config.ClientId, data: []const u8) bool {
        const client = self.findClientById(client_id) orelse return false;

        const success = if (self.use_framing)
            client.queueFramedSend(data)
        else
            client.queueSend(data);

        if (!success) return false;

        client.messages_sent += 1;
        self.updateClientEpoll(client, true) catch return false;

        return true;
    }

    pub fn broadcast(self: *Self, data: []const u8) void {
        for (&self.clients) |*client| {
            if (client.state == .connected) {
                if (self.use_framing) {
                    _ = client.queueFramedSend(data);
                } else {
                    _ = client.queueSend(data);
                }
                self.updateClientEpoll(client, true) catch {};
            }
        }
    }

    fn acceptConnection(self: *Self) !void {
        var addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(@TypeOf(addr));

        const client_fd = try posix.accept(self.listen_fd, @ptrCast(&addr), &addr_len, posix.SOCK.NONBLOCK);
        errdefer posix.close(client_fd);

        const client = self.findFreeClientSlot() orelse {
            std.log.warn("Max clients reached, rejecting connection", .{});
            posix.close(client_fd);
            return;
        };

        client.fd = client_fd;
        client.client_id = self.next_client_id;
        client.state = .connected;
        self.next_client_id +%= 1;
        if (self.next_client_id == 0) self.next_client_id = 1;

        self.client_count += 1;
        self.total_connections += 1;

        posix.setsockopt(client_fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        var ev = posix.epoll_event{
            .events = posix.EPOLL.IN | posix.EPOLL.ET,
            .data = .{ .fd = client_fd },
        };
        try posix.epoll_ctl(self.epoll_fd, posix.EPOLL.CTL_ADD, client_fd, &ev);

        std.log.info("Client {} connected (fd={})", .{ client.client_id, client_fd });
    }

    fn handleClientRead(self: *Self, client: *TcpClient) !void {
        while (true) {
            const available = RECV_BUFFER_SIZE - client.recv_len;
            if (available == 0) {
                std.log.warn("Client {} buffer full", .{client.client_id});
                return error.BufferFull;
            }

            const n = posix.recv(client.fd, client.recv_buf[client.recv_len..], 0) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };

            if (n == 0) return error.ConnectionClosed;

            client.recv_len += n;
            client.bytes_received += n;
        }

        if (self.use_framing) {
            self.processClientFrames(client);
        } else {
            self.processClientRaw(client);
        }
    }

    fn processClientFrames(self: *Self, client: *TcpClient) void {
        while (true) {
            const payload = client.extractFrame() orelse break;

            // Detect protocol if unknown
            if (client.protocol == .unknown) {
                client.protocol = codec.detectProtocol(payload);
            }

            // Decode message
            const result = codec.Codec.decodeInput(payload) catch |err| {
                std.log.warn("Client {} decode error: {}", .{ client.client_id, err });
                client.compactBuffer(FRAME_HEADER_SIZE + payload.len);
                continue;
            };

            client.messages_received += 1;

            if (self.on_message) |callback| {
                callback(client.client_id, &result.message, self.callback_ctx);
            }

            // Remove processed frame
            client.compactBuffer(FRAME_HEADER_SIZE + payload.len);
        }
    }

    fn processClientRaw(self: *Self, client: *TcpClient) void {
        var processed: usize = 0;

        while (processed < client.recv_len) {
            const remaining = client.recv_buf[processed..client.recv_len];

            if (client.protocol == .unknown) {
                client.protocol = codec.detectProtocol(remaining);
                if (client.protocol == .unknown and remaining.len < 8) break;
            }

            const result = codec.Codec.decodeInput(remaining) catch |err| {
                if (err == codec.CodecError.IncompleteMessage) break;
                std.log.warn("Client {} decode error: {}", .{ client.client_id, err });
                processed += 1;
                continue;
            };

            processed += result.bytes_consumed;
            client.messages_received += 1;

            if (self.on_message) |callback| {
                callback(client.client_id, &result.message, self.callback_ctx);
            }
        }

        if (processed > 0) {
            client.compactBuffer(processed);
        }
    }

    fn disconnectClient(self: *Self, client: *TcpClient) void {
        if (client.state == .disconnected) return;

        const client_id = client.client_id;
        std.log.info("Client {} disconnected", .{client_id});

        posix.epoll_ctl(self.epoll_fd, posix.EPOLL.CTL_DEL, client.fd, null) catch {};

        client.reset();
        self.client_count -|= 1;
        self.total_disconnections += 1;

        if (self.on_disconnect) |callback| {
            callback(client_id, self.callback_ctx);
        }
    }

    fn updateClientEpoll(self: *Self, client: *TcpClient, want_write: bool) !void {
        var events: u32 = posix.EPOLL.IN | posix.EPOLL.ET;
        if (want_write) events |= posix.EPOLL.OUT;

        var ev = posix.epoll_event{
            .events = events,
            .data = .{ .fd = client.fd },
        };
        try posix.epoll_ctl(self.epoll_fd, posix.EPOLL.CTL_MOD, client.fd, &ev);
    }

    fn findFreeClientSlot(self: *Self) ?*TcpClient {
        for (&self.clients) |*client| {
            if (client.state == .disconnected) return client;
        }
        return null;
    }

    fn findClientByFd(self: *Self, fd: posix.fd_t) ?usize {
        for (self.clients, 0..) |client, i| {
            if (client.fd == fd and client.state != .disconnected) return i;
        }
        return null;
    }

    fn findClientById(self: *Self, client_id: config.ClientId) ?*TcpClient {
        for (&self.clients) |*client| {
            if (client.client_id == client_id and client.state != .disconnected) return client;
        }
        return null;
    }
};

fn parseAddress(address: []const u8, port: u16) !posix.sockaddr.in {
    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
    };

    if (std.mem.eql(u8, address, "0.0.0.0")) {
        addr.addr = 0;
    } else {
        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, address, '.');
        var i: usize = 0;
        while (iter.next()) |part| : (i += 1) {
            if (i >= 4) return error.InvalidAddress;
            parts[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
        }
        if (i != 4) return error.InvalidAddress;
        addr.addr = @bitCast(parts);
    }

    return addr;
}
