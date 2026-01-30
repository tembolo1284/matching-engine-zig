//! Threaded TCP Server - One thread per client like C version
const std = @import("std");
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const TcpClient = @import("tcp_client.zig").TcpClient;
const msg = @import("../protocol/message_types.zig");
const SpscQueue = @import("../threading/spsc_queue.zig");
const InputEnvelope = SpscQueue.InputEnvelope;
const OutputEnvelope = SpscQueue.OutputEnvelope;
const InputEnvelopeQueue = SpscQueue.InputEnvelopeQueue;
const OutputEnvelopeQueue = SpscQueue.OutputEnvelopeQueue;

pub const MAX_CLIENTS: u32 = 100;

pub const ServerStats = struct {
    connections_accepted: u64,
    connections_closed: u64,
    messages_routed: u64,
    route_failures: u64,

    pub fn init() ServerStats {
        return ServerStats{
            .connections_accepted = 0,
            .connections_closed = 0,
            .messages_routed = 0,
            .route_failures = 0,
        };
    }
};

pub const ThreadedTcpServer = struct {
    allocator: Allocator,
    listener: ?net.Server,
    clients: [MAX_CLIENTS]?*TcpClient,
    client_lock: Thread.Mutex,
    next_client_id: u32,
    
    // Queues
    input_queue: *InputEnvelopeQueue,
    output_queue: *OutputEnvelopeQueue,
    
    // Threads
    accept_thread: ?Thread,
    router_thread: ?Thread,
    
    // Shutdown flag
    shutdown: std.atomic.Value(bool),
    
    // Stats
    stats: ServerStats,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        input_queue: *InputEnvelopeQueue,
        output_queue: *OutputEnvelopeQueue,
    ) Self {
        var self = Self{
            .allocator = allocator,
            .listener = null,
            .clients = [_]?*TcpClient{null} ** MAX_CLIENTS,
            .client_lock = Thread.Mutex{},
            .next_client_id = 1,
            .input_queue = input_queue,
            .output_queue = output_queue,
            .accept_thread = null,
            .router_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .stats = ServerStats.init(),
        };
        return self;
    }

    pub fn start(self: *Self, address: net.Address) !void {
        self.listener = try address.listen(.{
            .reuse_address = true,
        });
        
        // Make listener non-blocking so accept thread can check shutdown flag
        if (self.listener) |listener| {
            const flags = try posix.fcntl(listener.stream.handle, posix.F.GETFL, 0);
            _ = try posix.fcntl(
                listener.stream.handle,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            );
        }
        
        // Start accept thread
        self.accept_thread = try Thread.spawn(.{}, acceptThreadFn, .{self});
        
        // Start output router thread
        self.router_thread = try Thread.spawn(.{}, routerThreadFn, .{self});
        
        std.debug.print("[TCP] Threaded server started\n", .{});
    }

    pub fn stop(self: *Self) void {
        std.debug.print("[TCP] Stopping threaded server...\n", .{});
        
        // Signal shutdown first
        self.shutdown.store(true, .release);
        
        // Wait for accept thread (it should exit on next poll cycle)
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
        std.debug.print("[TCP] Accept thread joined\n", .{});
        
        // Wait for router thread
        if (self.router_thread) |t| {
            t.join();
            self.router_thread = null;
        }
        std.debug.print("[TCP] Router thread joined\n", .{});
        
        // Stop all client threads
        self.client_lock.lock();
        for (&self.clients) |*slot| {
            if (slot.*) |client| {
                client.stop();
                self.allocator.destroy(client);
                slot.* = null;
            }
        }
        self.client_lock.unlock();
        std.debug.print("[TCP] All client threads stopped\n", .{});
        
        // Close listener last
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }
        
        std.debug.print("[TCP] Threaded server stopped\n", .{});
    }

    pub fn getStats(self: *const Self) ServerStats {
        return self.stats;
    }

    pub fn getActiveClientCount(self: *Self) u32 {
        self.client_lock.lock();
        defer self.client_lock.unlock();
        
        var count: u32 = 0;
        for (self.clients) |slot| {
            if (slot) |client| {
                if (client.isActive()) count += 1;
            }
        }
        return count;
    }

    fn acceptThreadFn(self: *Self) void {
        std.debug.print("[TCP] Accept thread started\n", .{});
        
        while (!self.shutdown.load(.acquire)) {
            // Get mutable pointer to listener
            const listener_ptr: ?*net.Server = if (self.listener != null) @constCast(&self.listener.?) else null;
            if (listener_ptr == null) break;
            
            const accept_result = listener_ptr.?.accept() catch |err| {
                if (self.shutdown.load(.acquire)) break;
                switch (err) {
                    error.WouldBlock => {
                        Thread.sleep(1_000_000); // 1ms
                        continue;
                    },
                    else => {
                        if (!self.shutdown.load(.acquire)) {
                            std.debug.print("[TCP] Accept error: {any}\n", .{err});
                        }
                        continue;
                    },
                }
            };
            
            // Find free slot
            self.client_lock.lock();
            var slot_idx: ?usize = null;
            for (self.clients, 0..) |slot, i| {
                if (slot == null) {
                    slot_idx = i;
                    break;
                } else if (!slot.?.isActive()) {
                    // Reap dead client
                    slot.?.stop();
                    self.allocator.destroy(slot.?);
                    self.clients[i] = null;
                    self.stats.connections_closed += 1;
                    slot_idx = i;
                    break;
                }
            }
            
            if (slot_idx == null) {
                self.client_lock.unlock();
                std.debug.print("[TCP] Max clients reached, rejecting connection\n", .{});
                accept_result.stream.close();
                continue;
            }
            
            const client_id = self.next_client_id;
            self.next_client_id += 1;
            
            // Create client
            const client = self.allocator.create(TcpClient) catch {
                self.client_lock.unlock();
                accept_result.stream.close();
                continue;
            };
            client.* = TcpClient.init(
                client_id,
                accept_result.stream,
                accept_result.address,
                self.input_queue,
            );
            
            self.clients[slot_idx.?] = client;
            self.stats.connections_accepted += 1;
            self.client_lock.unlock();
            
            // Start client thread
            client.start() catch |err| {
                std.debug.print("[TCP] Failed to start client thread: {any}\n", .{err});
                self.client_lock.lock();
                self.clients[slot_idx.?] = null;
                self.client_lock.unlock();
                self.allocator.destroy(client);
                continue;
            };
            
            std.debug.print("[TCP] Client {d} connected\n", .{client_id});
        }
        
        std.debug.print("[TCP] Accept thread stopped\n", .{});
    }

    fn routerThreadFn(self: *Self) void {
        std.debug.print("[TCP] Router thread started\n", .{});
        
        while (!self.shutdown.load(.acquire)) {
            // Pop from output queue
            const envelope = self.output_queue.pop() orelse {
                Thread.sleep(100_000); // 100us
                continue;
            };
            
            // Route to appropriate client(s)
            if (envelope.client_id == 0) {
                // Broadcast to all
                self.broadcastMessage(&envelope.message);
            } else {
                // Route to specific client
                self.routeToClient(envelope.client_id, &envelope.message);
            }
        }
        
        // Drain remaining messages
        std.debug.print("[TCP] Router draining remaining messages...\n", .{});
        var drained: u32 = 0;
        while (self.output_queue.pop()) |envelope| {
            if (envelope.client_id == 0) {
                self.broadcastMessage(&envelope.message);
            } else {
                self.routeToClient(envelope.client_id, &envelope.message);
            }
            drained += 1;
            if (drained > 100000) break; // Safety limit
        }
        std.debug.print("[TCP] Router drained {d} messages\n", .{drained});
        
        std.debug.print("[TCP] Router thread stopped\n", .{});
    }

    fn routeToClient(self: *Self, client_id: u32, message: *const msg.OutputMsg) void {
        self.client_lock.lock();
        defer self.client_lock.unlock();
        
        for (self.clients) |slot| {
            if (slot) |client| {
                if (client.client_id == client_id and client.isActive()) {
                    if (client.enqueueOutput(message)) {
                        self.stats.messages_routed += 1;
                    } else {
                        self.stats.route_failures += 1;
                    }
                    return;
                }
            }
        }
        // Client not found - message dropped (client disconnected)
    }

    fn broadcastMessage(self: *Self, message: *const msg.OutputMsg) void {
        self.client_lock.lock();
        defer self.client_lock.unlock();
        
        for (self.clients) |slot| {
            if (slot) |client| {
                if (client.isActive()) {
                    if (client.enqueueOutput(message)) {
                        self.stats.messages_routed += 1;
                    } else {
                        self.stats.route_failures += 1;
                    }
                }
            }
        }
    }
};
