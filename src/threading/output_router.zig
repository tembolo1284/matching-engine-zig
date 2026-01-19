//! Output Router Thread
//!
//! Routes output messages from processor(s) to individual client queues.
//! In TCP mode, this performs per-client routing based on client_id.
//!
//! Matches C's output_router.h / output_router.c architecture:
//! - Polls multiple processor output queues (supports dual-processor mode)
//! - Routes messages to per-client ClientOutputQueues
//! - Integrated multicast support for trade/TOB broadcasts
//!
//! Power of Ten Compliance:
//! - Rule 2: All loops bounded (ROUTER_BATCH_SIZE, MAX_OUTPUT_QUEUES, drain limits)
//! - Rule 3: No dynamic allocation in hot path (fixed-size batch buffer)
//! - Rule 5: Assertions verify invariants
//! - Rule 7: All return values checked
//!
//! Flow:
//! ```
//!   Processor 0 → Output Queue 0 ┐
//!                                 ├→ Output Router ─┬→ Per-client queues (TCP)
//!   Processor 1 → Output Queue 1 ┘                  └→ Multicast group (optional)
//! ```

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");

// Import the client output queue types (breaks circular dependency)
const client_queue = @import("../collections/client_output_queue.zig");
pub const ClientOutputQueue = client_queue.ClientOutputQueue;
pub const ClientOutput = client_queue.ClientOutput;

// Re-export for backward compatibility with tcp_client imports
pub const OutputQueue = ClientOutputQueue;

// ============================================================================
// Configuration
// ============================================================================

pub const MAX_OUTPUT_QUEUES: usize = 2;
pub const ROUTER_BATCH_SIZE: usize = 32;

/// Cache line size for alignment
const CACHE_LINE_SIZE: usize = 64;

/// Small idle sleep; router is queue-to-queue only, so it can be aggressive
const SLEEP_TIME_NS: u64 = 1_000; // 1us

/// Drain bounds (P10 Rule 2)
const MAX_DRAIN_PER_QUEUE_PER_TICK: usize = 8192;
const MAX_TOTAL_DRAIN_PER_TICK: usize = 16384;

// Compile-time validation
comptime {
    std.debug.assert(MAX_OUTPUT_QUEUES >= 1);
    std.debug.assert(MAX_OUTPUT_QUEUES <= 4);
    std.debug.assert(ROUTER_BATCH_SIZE >= 1);
    std.debug.assert(ROUTER_BATCH_SIZE <= 256);
    std.debug.assert(MAX_DRAIN_PER_QUEUE_PER_TICK > 0);
    std.debug.assert(MAX_TOTAL_DRAIN_PER_TICK >= MAX_DRAIN_PER_QUEUE_PER_TICK);
}

// ============================================================================
// Statistics
// ============================================================================

/// Router statistics - matches C's output_router_stats_t
pub const RouterStats = struct {
    messages_routed: u64 = 0,
    messages_dropped: u64 = 0,
    critical_drops: u64 = 0,
    messages_from_processor: [MAX_OUTPUT_QUEUES]u64 = [_]u64{0} ** MAX_OUTPUT_QUEUES,
    mcast_messages: u64 = 0,
    mcast_errors: u64 = 0,

    pub fn init() RouterStats {
        return .{};
    }
};

// ============================================================================
// Multicast Callback
// ============================================================================

pub const MulticastCallback = *const fn (out_msg: *const msg.OutputMsg, ctx: ?*anyopaque) void;

// ============================================================================
// Client Registry
// ============================================================================

/// Client registry - maps client_id to ClientOutputQueue pointer
/// Matches C's tcp_client_registry_t concept
const ClientRegistry = struct {
    /// Slot array: client_id -> queue pointer (stored as usize for atomics)
    slots: []std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ClientRegistry {
        // Allocate slots for TCP client range (0 to CLIENT_ID_UDP_BASE)
        const n: usize = @intCast(config.CLIENT_ID_UDP_BASE);
        const slots = try allocator.alloc(std.atomic.Value(usize), n);
        for (slots) |*s| {
            s.* = std.atomic.Value(usize).init(0);
        }
        return .{ .slots = slots, .allocator = allocator };
    }

    pub fn deinit(self: *ClientRegistry) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    fn idx(client_id: config.ClientId, len: usize) ?usize {
        if (client_id == 0) return null;
        const i: usize = @intCast(client_id);
        if (i >= len) return null;
        return i;
    }

    pub fn get(self: *ClientRegistry, client_id: config.ClientId) ?*ClientOutputQueue {
        const i = idx(client_id, self.slots.len) orelse return null;
        const p = self.slots[i].load(.acquire);
        if (p == 0) return null;
        return @ptrFromInt(p);
    }

    pub fn set(self: *ClientRegistry, client_id: config.ClientId, q: ?*ClientOutputQueue) void {
        const i = idx(client_id, self.slots.len) orelse return;
        const p: usize = if (q) |qq| @intFromPtr(qq) else 0;
        self.slots[i].store(p, .release);
    }
};

// ============================================================================
// OutputRouter
// ============================================================================

pub const OutputRouter = struct {
    allocator: std.mem.Allocator,

    /// Input queues from processors (supports dual-processor mode)
    processor_queues: []const *proc.OutputQueue,

    /// Client registry for TCP routing
    registry: ClientRegistry,

    /// Thread control
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    /// Multicast support
    multicast_enabled: bool,
    multicast_cb: ?MulticastCallback,
    multicast_ctx: ?*anyopaque,

    /// Statistics
    stats: RouterStats,

    const Self = @This();

    // ------------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------------

    /// Initialize output router (matches C's output_router_init)
    ///
    /// @param allocator         Memory allocator
    /// @param processor_queues  Output queues from processor(s) - 1 or 2 queues
    /// @return                  Pointer to initialized router, or error
    pub fn init(
        allocator: std.mem.Allocator,
        processor_queues: []const *proc.OutputQueue,
    ) !*Self {
        std.debug.assert(processor_queues.len >= 1);
        std.debug.assert(processor_queues.len <= MAX_OUTPUT_QUEUES);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var registry = try ClientRegistry.init(allocator);
        errdefer registry.deinit();

        self.* = .{
            .allocator = allocator,
            .processor_queues = processor_queues,
            .registry = registry,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
            .multicast_enabled = false,
            .multicast_cb = null,
            .multicast_ctx = null,
            .stats = RouterStats.init(),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.registry.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) return error.AlreadyRunning;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
        std.log.info("OutputRouter started (processor_queues={d})", .{self.processor_queues.len});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        // Best-effort final drain
        var batch: [ROUTER_BATCH_SIZE]proc.ProcessorOutput = undefined;
        _ = self.drainOnce(batch[0..]);

        std.log.info("OutputRouter stopped (routed={}, dropped={}, critical_drops={})", .{
            self.stats.messages_routed,
            self.stats.messages_dropped,
            self.stats.critical_drops,
        });
    }

    // ------------------------------------------------------------------------
    // Multicast Configuration (matches C's output_router_enable_multicast)
    // ------------------------------------------------------------------------

    pub fn setMulticastEnabled(self: *Self, enabled: bool) void {
        self.multicast_enabled = enabled;
    }

    pub fn setMulticastCallback(self: *Self, cb: MulticastCallback, ctx: ?*anyopaque) void {
        self.multicast_cb = cb;
        self.multicast_ctx = ctx;
    }

    // ------------------------------------------------------------------------
    // Client Registration
    // ------------------------------------------------------------------------

    /// Register a client and create its output queue
    pub fn registerClient(self: *Self, client_id: config.ClientId) ?*ClientOutputQueue {
        if (client_id == 0) return null;

        // Check if already registered
        if (self.registry.get(client_id)) |existing| return existing;

        // Allocate new queue
        const q = self.allocator.create(ClientOutputQueue) catch {
            std.log.err("OutputRouter: failed to allocate ClientOutputQueue for client {}", .{client_id});
            return null;
        };
        q.* = ClientOutputQueue.init();

        self.registry.set(client_id, q);
        std.log.debug("OutputRouter: registered client {}", .{client_id});
        return q;
    }

    /// Unregister a client and free its output queue
    pub fn unregisterClient(self: *Self, client_id: config.ClientId) void {
        if (client_id == 0) return;
        const q = self.registry.get(client_id);
        self.registry.set(client_id, null);
        if (q) |qq| {
            self.allocator.destroy(qq);
        }
        std.log.debug("OutputRouter: unregistered client {}", .{client_id});
    }

    /// Get client's output queue (for external access)
    pub fn getClientQueue(self: *Self, client_id: config.ClientId) ?*ClientOutputQueue {
        return self.registry.get(client_id);
    }

    // ------------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------------

    pub fn getStats(self: *const Self) RouterStats {
        return self.stats;
    }

    // ------------------------------------------------------------------------
    // Main Loop (matches C's output_router_thread)
    // ------------------------------------------------------------------------

    fn runLoop(self: *Self) void {
        var batch: [ROUTER_BATCH_SIZE]proc.ProcessorOutput = undefined;

        while (self.running.load(.acquire)) {
            const drained = self.drainOnce(batch[0..]);
            if (drained == 0) {
                std.Thread.sleep(SLEEP_TIME_NS);
            }
        }
    }

    /// Drain processor queues once (round-robin for fairness)
    fn drainOnce(self: *Self, batch: []proc.ProcessorOutput) usize {
        var total: usize = 0;

        for (self.processor_queues, 0..) |q, qi| {
            var per_q: usize = 0;

            while (per_q < MAX_DRAIN_PER_QUEUE_PER_TICK and total < MAX_TOTAL_DRAIN_PER_TICK) {
                const want = @min(batch.len, MAX_DRAIN_PER_QUEUE_PER_TICK - per_q);
                const got = q.popBatch(batch[0..want]);
                if (got == 0) break;

                if (qi < MAX_OUTPUT_QUEUES) {
                    self.stats.messages_from_processor[qi] += got;
                }

                for (batch[0..got]) |*po| {
                    self.routeOne(po);
                }

                per_q += got;
                total += got;
            }

            if (total >= MAX_TOTAL_DRAIN_PER_TICK) break;
        }

        return total;
    }

    /// Check if message is critical (must not be dropped)
    fn isCritical(out_msg: *const msg.OutputMsg) bool {
        return switch (out_msg.msg_type) {
            .trade, .reject => true,
            .ack, .cancel_ack, .top_of_book => false,
        };
    }

    /// Multicast hook for trade/TOB messages
    fn maybeMulticast(self: *Self, out_msg: *const msg.OutputMsg) void {
        if (!self.multicast_enabled) return;

        switch (out_msg.msg_type) {
            .trade, .top_of_book => {},
            else => return,
        }

        if (self.multicast_cb) |cb| {
            cb(out_msg, self.multicast_ctx);
            self.stats.mcast_messages += 1;
        }
    }

    /// Route a single message to its target client queue
    fn routeOne(self: *Self, po: *const proc.ProcessorOutput) void {
        const client_id: config.ClientId = @intCast(po.client_id);
        const out_msg: *const msg.OutputMsg = &po.message;

        // Get client's queue
        const q = self.registry.get(client_id) orelse {
            self.stats.messages_dropped += 1;
            if (isCritical(out_msg)) self.stats.critical_drops += 1;
            return;
        };

        // Create output envelope
        const output = ClientOutput.init(po.message, client_id, 0);

        // Enqueue to client
        if (!q.push(output)) {
            self.stats.messages_dropped += 1;
            if (isCritical(out_msg)) self.stats.critical_drops += 1;
            return;
        }

        self.stats.messages_routed += 1;

        // Multicast is "side channel" for trade/TOB
        self.maybeMulticast(out_msg);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OutputRouter - basic lifecycle" {
    const allocator = std.testing.allocator;

    // Create mock processor queue
    var queue = proc.OutputQueue{};
    const queues = [_]*proc.OutputQueue{&queue};

    var router = try OutputRouter.init(allocator, &queues);
    defer router.deinit();

    try std.testing.expect(!router.running.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), router.processor_queues.len);
}

test "OutputRouter - client registration" {
    const allocator = std.testing.allocator;

    var queue = proc.OutputQueue{};
    const queues = [_]*proc.OutputQueue{&queue};

    var router = try OutputRouter.init(allocator, &queues);
    defer router.deinit();

    // Register client
    const q = router.registerClient(1);
    try std.testing.expect(q != null);

    // Should return same queue on re-register
    const q2 = router.registerClient(1);
    try std.testing.expectEqual(q, q2);

    // Lookup should work
    const q3 = router.getClientQueue(1);
    try std.testing.expectEqual(q, q3);

    // Unregister
    router.unregisterClient(1);
    try std.testing.expect(router.getClientQueue(1) == null);
}

test "OutputRouter - stats" {
    const allocator = std.testing.allocator;

    var queue = proc.OutputQueue{};
    const queues = [_]*proc.OutputQueue{&queue};

    var router = try OutputRouter.init(allocator, &queues);
    defer router.deinit();

    const stats = router.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.messages_routed);
    try std.testing.expectEqual(@as(u64, 0), stats.critical_drops);
}
