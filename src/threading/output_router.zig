//! Output Router - Routes processor outputs to per-client queues
//!
//! Matches the C server's output_router architecture:
//! - Drains processor output queues (SPSC, lock-free)
//! - Routes messages to per-client output queues (SPSC, lock-free)
//! - Optionally publishes multicast (callback)
//! - No socket I/O here; TCP server thread drains per-client queues.
//!
//! Flow:
//!   Processor 0 → Output Queue 0 ┐
//!                                 ├→ Output Router ─┬→ Per-client queues (TCP server drains)
//!   Processor 1 → Output Queue 1 ┘                  └→ Multicast callback
//!
//! Performance / P10:
//! - Bounded loops (Rule 2): ROUTER_BATCH_SIZE, MAX_DRAIN_ITERATIONS, MAX_CLIENTS
//! - No dynamic allocation in hot path (Rule 3)
//! - Assertions where appropriate (Rule 5)
//! - All queue ops checked (Rule 7)

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

/// Maximum drain iterations during shutdown
const MAX_DRAIN_ITERATIONS: u32 = 100;

/// Sleep time when idle (nanoseconds) - 1 microsecond like C server
const IDLE_SLEEP_NS: u64 = 1_000;

/// Maximum clients to support
pub const MAX_CLIENTS: u32 = 128;

/// Per-client output queue capacity
pub const CLIENT_QUEUE_CAPACITY: u32 = 8192;

// ============================================================================
// Per-Client Output Queue
// ============================================================================

/// Output message for client queue (smaller than ProcessorOutput)
pub const ClientOutput = struct {
    message: msg.OutputMsg,
};

/// Per-client output queue type
pub const ClientOutputQueue = SpscQueue(ClientOutput, CLIENT_QUEUE_CAPACITY);

/// Client output state
pub const ClientOutputState = struct {
    /// Output queue (producer: router, consumer: TCP server)
    queue: ClientOutputQueue,

    /// Client ID (0 = inactive)
    client_id: config.ClientId,

    /// Active flag
    active: std.atomic.Value(bool),

    /// Statistics (single-writer: router thread)
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
        // Drain any remaining messages (bounded by queue capacity)
        while (self.queue.pop() != null) {}

        self.client_id = 0;
        self.messages_enqueued = 0;
        self.messages_dropped = 0;
        self.critical_drops = 0;

        // Make inactive last
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
    /// Messages routed to client queues
    messages_routed: u64,
    /// Messages dropped (client not found or queue full)
    messages_dropped: u64,
    /// Critical messages dropped (trades, rejects)
    critical_drops: u64,
    /// Multicast messages sent
    multicast_messages: u64,
    /// Idle cycles (no work done)
    idle_cycles: u64,
    /// Per-processor drain counts (kept at 2 to match your current processor design)
    from_processor: [2]u64,

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

    /// Per-client output states
    clients: [MAX_CLIENTS]ClientOutputState,

    /// Active client count (informational)
    active_clients: std.atomic.Value(u32),

    /// Multicast callback
    multicast_callback: ?MulticastCallback,
    multicast_ctx: ?*anyopaque,
    multicast_enabled: bool,

    /// Thread handle
    thread: ?std.Thread,

    /// Running flag
    running: std.atomic.Value(bool),

    /// Statistics (single-writer: router thread)
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
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .processor_queues = processor_queues,
            .clients = undefined,
            .active_clients = std.atomic.Value(u32).init(0),
            .multicast_callback = null,
            .multicast_ctx = null,
            .multicast_enabled = false,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .stats = RouterStats.init(),
            .allocator = allocator,
        };

        for (&self.clients) |*client| {
            client.* = ClientOutputState.init();
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

    /// Register a client for output routing.
    /// Returns pointer to client's output queue for TCP server to drain.
    ///
    /// NOTE: We intentionally avoid hashed indices here. The previous `client_id % MAX_CLIENTS`
    /// approach is collision-prone and can cause misrouting/drops. Linear scan is bounded (128).
    pub fn registerClient(self: *Self, client_id: config.ClientId) ?*ClientOutputQueue {
        if (client_id == 0) return null;

        // If already registered, return existing queue (idempotent-ish)
        if (self.findClient(client_id)) |existing| {
            return &existing.queue;
        }

        // Find free slot
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

        // Initialize slot
        client.queue = .{}; // reset queue struct
        client.client_id = client_id;
        client.messages_enqueued = 0;
        client.messages_dropped = 0;
        client.critical_drops = 0;

        // Mark active last (publish)
        client.active.store(true, .release);
        _ = self.active_clients.fetchAdd(1, .monotonic);

        std.log.info("OutputRouter: Registered client {} in slot {}", .{ client_id, idx });
        return &client.queue;
    }

    /// Unregister a client
    pub fn unregisterClient(self: *Self, client_id: config.ClientId) void {
        if (client_id == 0) return;

        for (&self.clients) |*client| {
            if (client.client_id == client_id and client.isActive()) {
                std.log.info(
                    "OutputRouter: Unregistering client {} (enqueued={}, dropped={}, critical={})",
                    .{ client_id, client.messages_enqueued, client.messages_dropped, client.critical_drops },
                );

                client.reset();
                _ = self.active_clients.fetchSub(1, .monotonic);
                return;
            }
        }
    }

    /// Find client by ID (bounded linear scan; safe and predictable)
    fn findClient(self: *Self, client_id: config.ClientId) ?*ClientOutputState {
        if (client_id == 0) return null;

        for (&self.clients) |*client| {
            if (client.client_id == client_id and client.isActive()) {
                return client;
            }
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

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        // Drain remaining work (bounded)
        var iters: u32 = 0;
        while (iters < MAX_DRAIN_ITERATIONS) : (iters += 1) {
            const drained = self.drainOnce();
            if (drained == 0) break;
        }

        std.log.info("OutputRouter: Stopped (drained={}, routed={}, dropped={}, critical={}, multicast={})", .{
            self.stats.messages_drained,
            self.stats.messages_routed,
            self.stats.messages_dropped,
            self.stats.critical_drops,
            self.stats.multicast_messages,
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
                // Sleep 1 microsecond when idle (matches C server)
                std.Thread.sleep(IDLE_SLEEP_NS);
            }
        }

        std.log.debug("OutputRouter: Thread exiting", .{});
    }

    /// Drain processor output queues and route to client queues.
    /// Returns number of messages processed.
    fn drainOnce(self: *Self) u32 {
        var total_drained: u32 = 0;

        // Batch buffer for efficient dequeue
        var batch: [ROUTER_BATCH_SIZE]proc.ProcessorOutput = undefined;

        for (self.processor_queues, 0..) |queue, q_idx| {
            const count = queue.popBatch(&batch);
            if (count == 0) continue;

            // Route the batch
            for (batch[0..count]) |*output| {
                self.routeMessage(&output.message);
            }

            total_drained += @intCast(count);
            self.stats.messages_drained += count;

            if (q_idx < self.stats.from_processor.len) {
                self.stats.from_processor[q_idx] += count;
            }
        }

        return total_drained;
    }

    /// Route a single message to appropriate destination(s)
    fn routeMessage(self: *Self, out_msg: *const msg.OutputMsg) void {
        switch (out_msg.msg_type) {
            .ack, .cancel_ack, .reject => {
                // Unicast only
                self.routeToClient(out_msg);
            },
            .trade => {
                // Trade to buyer/specific client_id field in out_msg
                self.routeToClient(out_msg);
                // Also multicast
                if (self.multicast_enabled) self.publishMulticast(out_msg);
            },
            .top_of_book => {
                // Unicast if client specified
                if (out_msg.client_id != 0) self.routeToClient(out_msg);
                // Also multicast
                if (self.multicast_enabled) self.publishMulticast(out_msg);
            },
        }
    }

    /// Route message to a specific client's output queue
    fn routeToClient(self: *Self, out_msg: *const msg.OutputMsg) void {
        const client_id = out_msg.client_id;
        if (client_id == 0) return;

        const client = self.findClient(client_id) orelse {
            // Client not registered (disconnect races)
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
            // Queue full
            client.messages_dropped += 1;
            self.stats.messages_dropped += 1;

            const is_critical = (out_msg.msg_type == .trade or out_msg.msg_type == .reject);
            if (is_critical) {
                client.critical_drops += 1;
                self.stats.critical_drops += 1;
                std.log.err("OutputRouter: CRITICAL DROP client={} type={s}", .{
                    client_id,
                    @tagName(out_msg.msg_type),
                });
            }
        }
    }

    /// Publish to multicast
    fn publishMulticast(self: *Self, out_msg: *const msg.OutputMsg) void {
        if (self.multicast_callback) |callback| {
            callback(out_msg, self.multicast_ctx);
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

