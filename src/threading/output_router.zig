//! Output router thread.
//!
//! Drains processor output queues (proc.OutputQueue) and routes msg.OutputMsg
//! to per-client output queues used by TcpClient.
//!
//! Matches ThreadedServerV8 expectations:
//! - init() returns *OutputRouter
//! - start/stop/deinit lifecycle
//! - registerClient/unregisterClient
//! - getStats() returning RouterStats with critical_drops field
//! - multicast hooks (trade + top_of_book)

const std = @import("std");

const msg = @import("../protocol/message_types.zig");
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");

// MUST match what threaded_server imports:
const tcp_client = @import("../transport/tcp_client.zig");
pub const OutputQueue = tcp_client.OutputQueue;

// ============================================================================
// Configuration
// ============================================================================

pub const MAX_OUTPUT_QUEUES: usize = 2;

pub const ROUTER_BATCH_SIZE: usize = 64;

// small idle sleep; router is queue-to-queue only, so it can be aggressive
const SLEEP_TIME_NS: u64 = 1_000; // 1us

// Drain bounds (P10 Rule 2)
const MAX_DRAIN_PER_QUEUE_PER_TICK: usize = 8192;
const MAX_TOTAL_DRAIN_PER_TICK: usize = 16384;

// ============================================================================
// Stats
// ============================================================================

pub const RouterStats = struct {
    messages_routed: u64 = 0,
    messages_dropped: u64 = 0,
    critical_drops: u64 = 0,
    messages_from_processor: [MAX_OUTPUT_QUEUES]u64 = [_]u64{0} ** MAX_OUTPUT_QUEUES,

    pub fn init() RouterStats {
        return .{};
    }
};

// ============================================================================
// Multicast Hook
// ============================================================================

pub const MulticastCallback = *const fn (out_msg: *const msg.OutputMsg, ctx: ?*anyopaque) void;

// ============================================================================
// Client Registry (client_id -> queue pointer)
// ============================================================================

const ClientRegistry = struct {
    slots: []std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ClientRegistry {
        const n: usize = @intCast(config.CLIENT_ID_UDP_BASE);
        var slots = try allocator.alloc(std.atomic.Value(usize), n);
        for (slots) |*s| s.* = std.atomic.Value(usize).init(0);
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

    pub fn get(self: *ClientRegistry, client_id: config.ClientId) ?*OutputQueue {
        const i = idx(client_id, self.slots.len) orelse return null;
        const p = self.slots[i].load(.acquire);
        if (p == 0) return null;
        return @ptrFromInt(p);
    }

    pub fn set(self: *ClientRegistry, client_id: config.ClientId, q: ?*OutputQueue) void {
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
    processor_queues: []const *proc.OutputQueue,

    registry: ClientRegistry,

    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    multicast_enabled: bool,
    multicast_cb: ?MulticastCallback,
    multicast_ctx: ?*anyopaque,

    stats: RouterStats,

    const Self = @This();

    // ------------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------------

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

        // best-effort final drain
        var batch: [ROUTER_BATCH_SIZE]proc.ProcessorOutput = undefined;
        _ = self.drainOnce(batch[0..]);

        std.log.info("OutputRouter stopped (routed={}, dropped={}, critical_drops={})", .{
            self.stats.messages_routed,
            self.stats.messages_dropped,
            self.stats.critical_drops,
        });
    }

    // ------------------------------------------------------------------------
    // Multicast configuration
    // ------------------------------------------------------------------------

    pub fn setMulticastEnabled(self: *Self, enabled: bool) void {
        self.multicast_enabled = enabled;
    }

    pub fn setMulticastCallback(self: *Self, cb: MulticastCallback, ctx: ?*anyopaque) void {
        self.multicast_cb = cb;
        self.multicast_ctx = ctx;
    }

    // ------------------------------------------------------------------------
    // Client registration
    // ------------------------------------------------------------------------

    pub fn registerClient(self: *Self, client_id: config.ClientId) ?*OutputQueue {
        if (client_id == 0) return null;

        if (self.registry.get(client_id)) |existing| return existing;

        const q = self.allocator.create(OutputQueue) catch {
            std.log.err("OutputRouter: failed to allocate OutputQueue for client {}", .{client_id});
            return null;
        };

        // Be robust to whether OutputQueue has init() or not
        if (@hasDecl(OutputQueue, "init")) {
            q.* = OutputQueue.init();
        } else {
            q.* = .{};
        }

        self.registry.set(client_id, q);
        std.log.debug("OutputRouter: registered client {}", .{client_id});
        return q;
    }

    pub fn unregisterClient(self: *Self, client_id: config.ClientId) void {
        if (client_id == 0) return;

        const q = self.registry.get(client_id);
        self.registry.set(client_id, null);

        if (q) |qq| {
            self.allocator.destroy(qq);
        }

        std.log.debug("OutputRouter: unregistered client {}", .{client_id});
    }

    // ------------------------------------------------------------------------
    // Stats
    // ------------------------------------------------------------------------

    pub fn getStats(self: *const Self) RouterStats {
        return self.stats;
    }

    // ------------------------------------------------------------------------
    // Main loop
    // ------------------------------------------------------------------------

    fn runLoop(self: *Self) void {
        var batch: [ROUTER_BATCH_SIZE]proc.ProcessorOutput = undefined;

        while (self.running.load(.acquire)) {
            const drained = self.drainOnce(batch[0..]);
            if (drained == 0) {
                std.time.sleep(SLEEP_TIME_NS);
            }
        }
    }

    fn drainOnce(self: *Self, batch: []proc.ProcessorOutput) usize {
        var total: usize = 0;

        for (self.processor_queues, 0..) |q, qi| {
            var per_q: usize = 0;

            while (per_q < MAX_DRAIN_PER_QUEUE_PER_TICK and total < MAX_TOTAL_DRAIN_PER_TICK) {
                const want = @min(batch.len, MAX_DRAIN_PER_QUEUE_PER_TICK - per_q);
                const got = q.popBatch(batch[0..want]);
                if (got == 0) break;

                if (qi < MAX_OUTPUT_QUEUES) self.stats.messages_from_processor[qi] += got;

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

    fn isCritical(out_msg: *const msg.OutputMsg) bool {
        return switch (out_msg.msg_type) {
            .trade, .reject => true,
            .ack, .cancel_ack, .top_of_book => false,
        };
    }

    fn maybeMulticast(self: *Self, out_msg: *const msg.OutputMsg) void {
        if (!self.multicast_enabled) return;

        switch (out_msg.msg_type) {
            .trade, .top_of_book => {},
            else => return,
        }

        if (self.multicast_cb) |cb| {
            cb(out_msg, self.multicast_ctx);
        }
    }

    fn clientQueueEnqueue(q: *OutputQueue, out_msg: msg.OutputMsg) bool {
        // Support either push() or send() depending on your OutputQueue type
        if (@hasDecl(OutputQueue, "push")) {
            return q.push(out_msg);
        }
        if (@hasDecl(OutputQueue, "send")) {
            return q.send(out_msg);
        }
        // If neither exists, compilation should fail (intentional)
        @compileError("TcpClient.OutputQueue must expose push(msg.OutputMsg)->bool or send(msg.OutputMsg)->bool");
    }

    fn routeOne(self: *Self, po: *const proc.ProcessorOutput) void {
        const client_id: config.ClientId = @intCast(po.client_id);
        const out_msg: *const msg.OutputMsg = &po.message;

        const q = self.registry.get(client_id) orelse {
            self.stats.messages_dropped += 1;
            if (isCritical(out_msg)) self.stats.critical_drops += 1;
            return;
        };

        if (!clientQueueEnqueue(q, po.message)) {
            self.stats.messages_dropped += 1;
            if (isCritical(out_msg)) self.stats.critical_drops += 1;
            return;
        }

        self.stats.messages_routed += 1;

        // multicast is "side channel" for trade / TOB
        self.maybeMulticast(out_msg);
    }
};
