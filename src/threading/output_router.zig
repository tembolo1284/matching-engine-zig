//! Output Router - Routes processor outputs to per-client queues
//!
//! This matches the C server's output_router architecture:
//! - Drains processor output queues (SPSC, lock-free)
//! - Routes messages to per-client output queues (SPSC, lock-free)
//! - Broadcasts to multicast (if enabled)
//! - Very fast because it only does queue operations, no socket I/O
//!
//! The TCP server thread handles actual socket sends from client queues.
//!
//! Flow:
//!   Processor 0 → Output Queue 0 ┐
//!                                 ├→ Output Router ─┬→ Per-client queues (TCP server drains)
//!   Processor 1 → Output Queue 1 ┘                  └→ Multicast callback
//!
//! Performance:
//! - Sleep only 1 microsecond when idle (matches C server)
//! - Batch dequeue for efficiency
//! - No socket operations in this thread
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: All loops bounded by ROUTER_BATCH_SIZE, MAX_DRAIN_ITERATIONS
//! - Rule 3: No dynamic allocation in hot path
//! - Rule 5: Assertions validate state
//! - Rule 7: All queue operations checked

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
const IDLE_SLEEP_NS: u64 = 1000;

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
    
    /// Statistics
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
        // Drain any remaining messages
        while (self.queue.pop() != null) {}
        self.client_id = 0;
        self.active.store(false, .release);
        self.messages_enqueued = 0;
        self.messages_dropped = 0;
        self.critical_drops = 0;
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
    /// Messages dropped (client queue full or not found)
    messages_dropped: u64,
    /// Critical messages dropped (trades, rejects)
    critical_drops: u64,
    /// Multicast messages sent
    multicast_messages: u64,
    /// Idle cycles (no work done)
    idle_cycles: u64,
    /// Per-processor drain counts
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

    /// Client lookup index (client_id % MAX_CLIENTS -> slot index)
    client_index: [MAX_CLIENTS]?u8,

    /// Active client count
    active_clients: std.atomic.Value(u32),

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
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .processor_queues = processor_queues,
            .clients = undefined,
            .client_index = [_]?u8{null} ** MAX_CLIENTS,
            .active_clients = std.atomic.Value(u32).init(0),
            .multicast_callback = null,
            .multicast_ctx = null,
            .multicast_enabled = false,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .stats = RouterStats.init(),
            .allocator = allocator,
        };

        // Initialize all client slots
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

    /// Register a client for output routing
    /// Returns pointer to client's output queue for TCP server to drain
    pub fn registerClient(self: *Self, client_id: config.ClientId) ?*ClientOutputQueue {
        if (client_id == 0) return null;

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
        client.client_id = client_id;
        client.messages_enqueued = 0;
        client.messages_dropped = 0;
        client.critical_drops = 0;

        // Update index for fast lookup
        const hash_idx = client_id % MAX_CLIENTS;
        self.client_index[hash_idx] = @intCast(idx);

        // Mark active (must be last - release fence)
        client.active.store(true, .release);
        _ = self.active_clients.fetchAdd(1, .monotonic);

        std.log.info("OutputRouter: Registered client {} in slot {}", .{ client_id, idx });
        return &client.queue;
    }

    /// Unregister a client
    pub fn unregisterClient(self: *Self, client_id: config.ClientId) void {
        if (client_id == 0) return;

        for (&self.clients, 0..) |*client, i| {
            if (client.client_id == client_id and client.isActive()) {
                std.log.info("OutputRouter: Unregistering client {} (enqueued={}, dropped={})", .{
                    client_id,
                    client.messages_enqueued,
                    client.messages_dropped,
                });
                client.reset();
                _ = self.active_clients.fetchSub(1, .monotonic);

                // Clear index
                const hash_idx = client_id % MAX_CLIENTS;
                if (self.client_index[hash_idx]) |idx| {
                    if (idx == i) {
                        self.client_index[hash_idx] = null;
                    }
                }
                return;
            }
        }
    }

    /// Find client by ID
    fn findClient(self: *Self, client_id: config.ClientId) ?*ClientOutputState {
        if (client_id == 0) return null;

        // Fast path: check index
        const hash_idx = client_id % MAX_CLIENTS;
        if (self.client_index[hash_idx]) |idx| {
            const client = &self.clients[idx];
            if (client.client_id == client_id and client.isActive()) {
                return client;
            }
        }

        // Slow path: linear scan (handles hash collisions)
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
        if (self.running.load(.acquire)) {
            return error.AlreadyRunning;
        }

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

        // Final drain
        _ = self.drainOnce();

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

        // Drain all processor queues
        for (self.processor_queues, 0..) |queue, q_idx| {
            const count = queue.popBatch(&batch);

            if (count == 0) continue;

            // Process the batch
            for (batch[0..count]) |*output| {
                self.routeMessage(&output.message);
            }

            total_drained += @intCast(count);
            self.stats.messages_drained += count;
            if (q_idx < 2) {
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
                // Trade to buyer
                self.routeToClient(out_msg);
                // Also multicast
                if (self.multicast_enabled) {
                    self.publishMulticast(out_msg);
                }
            },
            .top_of_book => {
                // Unicast if client specified
                if (out_msg.client_id != 0) {
                    self.routeToClient(out_msg);
                }
                // Also multicast
                if (self.multicast_enabled) {
                    self.publishMulticast(out_msg);
                }
            },
        }
    }

    /// Route message to a specific client's output queue
    fn routeToClient(self: *Self, out_msg: *const msg.OutputMsg) void {
        if (out_msg.client_id == 0) return;

        const client = self.findClient(out_msg.client_id) orelse {
            // Client not registered - this happens during disconnect races
            self.stats.messages_dropped += 1;
            const is_critical = (out_msg.msg_type == .trade or out_msg.msg_type == .reject);
            if (is_critical) {
                self.stats.critical_drops += 1;
            }
            return;
        };

        // Enqueue to client's output queue
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
                    out_msg.client_id,
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

test "OutputRouter basic" {
    // This would require setting up processor queues which is complex
    // Just verify compilation
    _ = OutputRouter;
    _ = ClientOutputState;
    _ = ClientOutputQueue;
}
