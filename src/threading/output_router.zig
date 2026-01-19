//! Output Router - Routes processor outputs to per-client queues
//!
//! Matches the C server output_router architecture:
//! - Drains processor output queues (SPSC, lock-free)
//! - Routes messages to per-client output queues (SPSC, lock-free)
//! - Optional multicast callback (broadcast in addition to unicast)
//! - Router does NO socket IO; TCP server drains client queues
//!
//! Flow:
//!   Processor 0 → Output Queue 0 ┐
//!                                 ├→ Output Router ─┬→ Per-client queues (TCP server drains)
//!   Processor 1 → Output Queue 1 ┘                  └→ Multicast callback
//!
//! Power of Ten Compliance:
//! - Rule 2: All loops bounded (ROUTER_BATCH_SIZE, MAX_DRAIN_ITERATIONS, MAX_CLIENTS)
//! - Rule 3: No allocation in hot path
//! - Rule 5: Assertions validate state
//! - Rule 7: All queue ops checked

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const proc = @import("processor.zig");
const config = @import("../transport/config.zig");
const SpscQueue = @import("../collections/spsc_queue.zig").SpscQueue;

// ============================================================================
// Configuration
// ============================================================================

/// Batch size for dequeuing from processor queues
pub const ROUTER_BATCH_SIZE: u32 = 32;

/// Sleep time when idle (nanoseconds) - 1 microsecond like C server
const IDLE_SLEEP_NS: u64 = 1000;

/// Maximum clients to support
pub const MAX_CLIENTS: u32 = 128;

/// Per-client output queue capacity
pub const CLIENT_QUEUE_CAPACITY: u32 = 8192;

/// Maximum drain iterations during shutdown
const MAX_DRAIN_ITERATIONS: u32 = 100;

/// Max processors supported (C supports 1 or 2; keep this explicit)
const MAX_PROCESSOR_QUEUES: u32 = 2;

// ============================================================================
// Per-Client Output Queue
// ============================================================================

/// Output message for client queue (smaller than ProcessorOutput)
pub const ClientOutput = struct {
    message: msg.OutputMsg,
};

/// Per-client output queue type (producer: router, consumer: TCP server)
pub const ClientOutputQueue = SpscQueue(ClientOutput, CLIENT_QUEUE_CAPACITY);

/// Client output slot state
pub const ClientOutputState = struct {
    queue: ClientOutputQueue,
    client_id: config.ClientId,
    active: std.atomic.Value(bool),

    // Stats
    messages_enqueued: u64,
    messages_dropped: u64,
    critical_drops: u64,

    const Self = @This();

    pub fn init() Self {
        return .{
            .queue = .{},
            .client_id = 0,
            .active = std.atomic.Value(bool).init(false),
            .messages_enqueued = 0,
            .messages_dropped = 0,
            .critical_drops = 0,
        };
    }

    pub fn reset(self: *Self) void {
        // Drain queue
        while (self.queue.pop() != null) {}
        self.client_id = 0;
        self.messages_enqueued = 0;
        self.messages_dropped = 0;
        self.critical_drops = 0;
        self.active.store(false, .release);
    }

    pub fn isActive(self: *const Self) bool {
        return self.active.load(.acquire);
    }
};

// ============================================================================
// Multicast Callback
// ============================================================================

pub const MulticastCallback = *const fn (message: *const msg.OutputMsg, ctx: ?*anyopaque) void;

// ============================================================================
// Output Router Statistics
// ============================================================================

pub const RouterStats = struct {
    /// Total messages drained from processor queues
    messages_drained: u64,
    /// Messages routed to client queues (successful enqueue)
    messages_routed: u64,
    /// Messages dropped (client not found or client queue full)
    messages_dropped: u64,
    /// Critical messages dropped (trades, rejects)
    critical_drops: u64,
    /// Multicast messages sent
    multicast_messages: u64,
    /// Idle cycles (no work done)
    idle_cycles: u64,
    /// Per-processor drain counts
    from_processor: [MAX_PROCESSOR_QUEUES]u64,

    pub fn init() RouterStats {
        return std.mem.zeroes(RouterStats);
    }
};

// ============================================================================
// Output Router
// ============================================================================

pub const OutputRouter = struct {
    /// Processor output queues to drain
    processor_queues: []const *proc.OutputQueue,

    /// Per-client slots
    clients: [MAX_CLIENTS]ClientOutputState,

    /// Fast lookup: client_id % MAX_CLIENTS -> slot index
    ///
    /// IMPORTANT: collisions can happen. If we detect a collision, we set the
    /// bucket to null and rely on slow-path scan for correctness.
    client_index: [MAX_CLIENTS]?u8,

    /// Active client count
    active_clients: std.atomic.Value(u32),

    /// Round-robin cursor for processor queue polling (fairness)
    rr_cursor: u32,

    /// Multicast callback
    multicast_callback: ?MulticastCallback,
    multicast_ctx: ?*anyopaque,
    multicast_enabled: bool,

    /// Thread handle
    thread: ?std.Thread,

    /// Running flag
    running: std.atomic.Value(bool),

    /// Statistics
    stats: RouterStats,

    /// Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    // ========================================================================
    // Lifecycle
    // ========================================================================

    pub fn init(
        allocator: std.mem.Allocator,
        processor_queues: []const *proc.OutputQueue,
    ) !*Self {
        // Rule 5: Preconditions
        std.debug.assert(processor_queues.len >= 1);
        std.debug.assert(processor_queues.len <= MAX_PROCESSOR_QUEUES);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .processor_queues = processor_queues,
            .clients = undefined,
            .client_index = [_]?u8{null} ** MAX_CLIENTS,
            .active_clients = std.atomic.Value(u32).init(0),
            .rr_cursor = 0,
            .multicast_callback = null,
            .multicast_ctx = null,
            .multicast_enabled = false,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .stats = RouterStats.init(),
            .allocator = allocator,
        };

        for (&self.clients) |*c| {
            c.* = ClientOutputState.init();
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.destroy(self);
    }

    // ========================================================================
    // Configuration
    // ========================================================================

    pub fn setMulticastCallback(
        self: *Self,
        callback: ?MulticastCallback,
        ctx: ?*anyopaque,
    ) void {
        self.multicast_callback = callback;
        self.multicast_ctx = ctx;
    }

    pub fn setMulticastEnabled(self: *Self, enabled: bool) void {
        self.multicast_enabled = enabled;
    }

    // ========================================================================
    // Client Management
    // ========================================================================

    /// Register client; returns pointer to client's output queue.
    pub fn registerClient(self: *Self, client_id: config.ClientId) ?*ClientOutputQueue {
        if (client_id == 0) return null;

        // Find free slot (bounded by MAX_CLIENTS)
        var slot_idx: ?usize = null;
        for (&self.clients, 0..) |*client, i| {
            if (!client.isActive()) {
                slot_idx = i;
                break;
            }
        }

        const idx = slot_idx orelse {
            std.log.warn("OutputRouter: No free client slots for client {}", .{client_id});
            return null;
        };

        const client = &self.clients[idx];
        // Reset slot contents (queue already empty because inactive, but be safe)
        client.reset();
        client.client_id = client_id;

        // Fast lookup bucket
        const hash_idx: usize = @intCast(client_id % MAX_CLIENTS);

        // Collision handling: if bucket is empty -> set it.
        // If bucket already points at an active different client -> disable fast path for that bucket.
        if (self.client_index[hash_idx]) |existing_idx| {
            const existing = &self.clients[existing_idx];
            if (existing.isActive() and existing.client_id != client_id) {
                // Collision: turn off fast path for this bucket.
                self.client_index[hash_idx] = null;
            } else {
                self.client_index[hash_idx] = @intCast(idx);
            }
        } else {
            self.client_index[hash_idx] = @intCast(idx);
        }

        client.active.store(true, .release);
        _ = self.active_clients.fetchAdd(1, .monotonic);

        std.log.info("OutputRouter: Registered client {} in slot {}", .{ client_id, idx });
        return &client.queue;
    }

    pub fn unregisterClient(self: *Self, client_id: config.ClientId) void {
        if (client_id == 0) return;

        for (&self.clients, 0..) |*client, i| {
            if (client.isActive() and client.client_id == client_id) {
                std.log.info("OutputRouter: Unregistering client {} (enqueued={}, dropped={})", .{
                    client_id,
                    client.messages_enqueued,
                    client.messages_dropped,
                });

                client.reset();
                _ = self.active_clients.fetchSub(1, .monotonic);

                // Clear fast path bucket ONLY if it points to this slot.
                const hash_idx: usize = @intCast(client_id % MAX_CLIENTS);
                if (self.client_index[hash_idx]) |idx| {
                    if (idx == @as(u8, @intCast(i))) {
                        self.client_index[hash_idx] = null;
                    }
                }
                return;
            }
        }
    }

    fn findClient(self: *Self, client_id: config.ClientId) ?*ClientOutputState {
        if (client_id == 0) return null;

        const hash_idx: usize = @intCast(client_id % MAX_CLIENTS);
        if (self.client_index[hash_idx]) |idx| {
            const client = &self.clients[idx];
            if (client.isActive() and client.client_id == client_id) {
                return client;
            }
        }

        // Slow path scan (bounded by MAX_CLIENTS)
        for (&self.clients) |*client| {
            if (client.isActive() and client.client_id == client_id) return client;
        }

        return null;
    }

    // ========================================================================
    // Thread Control
    // ========================================================================

    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) return error.AlreadyRunning;

        std.log.info("OutputRouter: Starting (queues={}, max_clients={})", .{
            self.processor_queues.len,
            MAX_CLIENTS,
        });

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;

        std.log.info("OutputRouter: Stopping...", .{});
        self.running.store(false, .release);

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        // Drain remaining messages (bounded)
        self.drainRemaining();

        std.log.info("OutputRouter: Stopped (drained={}, routed={}, dropped={}, critical={})", .{
            self.stats.messages_drained,
            self.stats.messages_routed,
            self.stats.messages_dropped,
            self.stats.critical_drops,
        });
    }

    // ========================================================================
    // Main Loop
    // ========================================================================

    fn runLoop(self: *Self) void {
        std.log.debug("OutputRouter: Thread started", .{});

        while (self.running.load(.acquire)) {
            const drained = self.drainOnce();

            if (drained == 0) {
                self.stats.idle_cycles += 1;
                std.Thread.sleep(IDLE_SLEEP_NS);
            }
        }

        std.log.debug("OutputRouter: Thread exiting", .{});
    }

    /// Drain processor output queues and route to client queues.
    /// Returns number of messages processed.
    fn drainOnce(self: *Self) u32 {
        var total: u32 = 0;
        var batch: [ROUTER_BATCH_SIZE]proc.ProcessorOutput = undefined;

        const nqs: u32 = @intCast(self.processor_queues.len);
        std.debug.assert(nqs >= 1 and nqs <= MAX_PROCESSOR_QUEUES);

        // Round-robin start index (fairness)
        const start = self.rr_cursor % nqs;
        self.rr_cursor = (self.rr_cursor + 1) % nqs;

        // Bounded loop: at most nqs queues
        var i: u32 = 0;
        while (i < nqs) : (i += 1) {
            const q_idx: u32 = (start + i) % nqs;
            const queue = self.processor_queues[q_idx];

            const count = queue.popBatch(&batch);
            if (count == 0) continue;

            // Process batch (bounded by ROUTER_BATCH_SIZE)
            for (batch[0..count]) |*out| {
                self.routeMessage(&out.message);
            }

            total += @intCast(count);
            self.stats.messages_drained += count;
            self.stats.from_processor[q_idx] += count;
        }

        return total;
    }

    fn drainRemaining(self: *Self) void {
        var iterations: u32 = 0;

        while (iterations < MAX_DRAIN_ITERATIONS) : (iterations += 1) {
            const drained = self.drainOnce();
            if (drained == 0) break;
        }

        if (iterations == MAX_DRAIN_ITERATIONS) {
            std.log.warn("OutputRouter: Drain limit reached; some messages may remain", .{});
        }
    }

    // ========================================================================
    // Routing
    // ========================================================================

    fn routeMessage(self: *Self, out_msg: *const msg.OutputMsg) void {
        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => {
                self.routeToClient(out_msg);
            },
            .trade => {
                self.routeToClient(out_msg);
                if (self.multicast_enabled) self.publishMulticast(out_msg);
            },
            .top_of_book => {
                if (out_msg.client_id != 0) self.routeToClient(out_msg);
                if (self.multicast_enabled) self.publishMulticast(out_msg);
            },
        }
    }

    fn routeToClient(self: *Self, out_msg: *const msg.OutputMsg) void {
        if (out_msg.client_id == 0) return;

        const client = self.findClient(out_msg.client_id) orelse {
            self.stats.messages_dropped += 1;
            const is_critical = (out_msg.msg_type == .trade or out_msg.msg_type == .reject);
            if (is_critical) self.stats.critical_drops += 1;
            return;
        };

        const output = ClientOutput{ .message = out_msg.* };
        if (client.queue.push(output)) {
            client.messages_enqueued += 1;
            self.stats.messages_routed += 1;
        } else {
            client.messages_dropped += 1;
            self.stats.messages_dropped += 1;

            const is_critical = (out_msg.msg_type == .trade or out_msg.msg_type == .reject);
            if (is_critical) {
                client.critical_drops += 1;
                self.stats.critical_drops += 1;
                std.log.err("OutputRouter: CRITICAL DROP client={} type={s}", .{
                    out_msg.client_id,
                    @tagName(out_msg.msg_type),
                });
            }
        }
    }

    fn publishMulticast(self: *Self, out_msg: *const msg.OutputMsg) void {
        if (self.multicast_callback) |cb| {
            cb(out_msg, self.multicast_ctx);
            self.stats.multicast_messages += 1;
        }
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    pub fn getStats(self: *const Self) RouterStats {
        return self.stats;
    }

    pub fn isHealthy(self: *const Self) bool {
        return self.stats.critical_drops == 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OutputRouter compiles" {
    _ = OutputRouter;
    _ = ClientOutputState;
    _ = ClientOutputQueue;
}

