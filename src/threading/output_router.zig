//! Output Router Thread
//!
//! Routes output messages from processor(s) to individual client queues.
//! ...
const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const config = @import("../transport/config.zig");
const proc = @import("processor.zig");
const client_queue = @import("../collections/client_output_queue.zig");
pub const ClientOutputQueue = client_queue.ClientOutputQueue;
pub const ClientOutput = client_queue.ClientOutput;
pub const OutputQueue = ClientOutputQueue;
// ============================================================================
// Configuration
// ============================================================================
pub const MAX_OUTPUT_QUEUES: usize = 2;
pub const ROUTER_BATCH_SIZE: usize = 256;
pub const MAX_TCP_CLIENTS: usize = 4096;
const SLEEP_TIME_NS: u64 = 100;
const IDLE_SPIN_COUNT: u32 = 100000;
const MAX_DRAIN_PER_QUEUE_PER_TICK: usize = 65536;
const MAX_TOTAL_DRAIN_PER_TICK: usize = 131072;
comptime {
    std.debug.assert(MAX_OUTPUT_QUEUES >= 1);
    std.debug.assert(MAX_OUTPUT_QUEUES <= 4);
    std.debug.assert(ROUTER_BATCH_SIZE >= 1);
    std.debug.assert(ROUTER_BATCH_SIZE <= 256);
    std.debug.assert(MAX_DRAIN_PER_QUEUE_PER_TICK > 0);
    std.debug.assert(MAX_TOTAL_DRAIN_PER_TICK >= MAX_DRAIN_PER_QUEUE_PER_TICK);
    std.debug.assert(MAX_TCP_CLIENTS > 0);
    std.debug.assert(MAX_TCP_CLIENTS <= 65536);
}
// ============================================================================
// Statistics
// ============================================================================
pub const RouterStats = struct {
    messages_routed: u64 = 0,
    messages_dropped: u64 = 0,
    critical_drops: u64 = 0,
    messages_from_processor: [MAX_OUTPUT_QUEUES]u64 = [_]u64{0} ** MAX_OUTPUT_QUEUES,
    mcast_messages: u64 = 0,
    mcast_errors: u64 = 0,
    unknown_client_drops: u64 = 0,
    pub fn init() RouterStats {
        return .{};
    }
};
pub const MulticastCallback = *const fn (out_msg: *const msg.OutputMsg, ctx: ?*anyopaque) void;
/// NEW: Notify callback — used to wake the TCP poller thread.
/// Called when router routes any output in a tick.
/// Signature is intentionally generic to avoid imports / cycles.
pub const NotifyCallback = *const fn (ctx: ?*anyopaque) void;
// ============================================================================
// Client Registry
// ============================================================================
const ClientRegistry = struct {
    slots: []std.atomic.Value(usize),
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) !ClientRegistry {
        const n: usize = MAX_TCP_CLIENTS + 1;
        const slots = try allocator.alloc(std.atomic.Value(usize), n);
        for (slots) |*s| s.* = std.atomic.Value(usize).init(0);
        return .{ .slots = slots, .allocator = allocator };
    }
    pub fn deinit(self: *ClientRegistry) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }
    fn idx(client_id: config.ClientId, len: usize) ?usize {
        if (client_id == 0) return null;
        if (config.isUdpClient(client_id)) return null;
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
    processor_queues: []const *proc.OutputQueue,
    registry: ClientRegistry,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    multicast_enabled: bool,
    multicast_cb: ?MulticastCallback,
    multicast_ctx: ?*anyopaque,
    /// NEW: wake notifier
    notify_cb: ?NotifyCallback,
    notify_ctx: ?*anyopaque,
    stats: RouterStats,
    const Self = @This();
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
            .notify_cb = null,
            .notify_ctx = null,
            .stats = RouterStats.init(),
        };
        std.log.info("OutputRouter initialized (max_clients={}, registry_slots={})", .{
            MAX_TCP_CLIENTS,
            self.registry.slots.len,
        });
        return self;
    }
    pub fn deinit(self: *Self) void {
        self.stop();
        self.registry.deinit();
        self.allocator.destroy(self);
    }
    pub fn setNotifyCallback(self: *Self, cb: NotifyCallback, ctx: ?*anyopaque) void {
        self.notify_cb = cb;
        self.notify_ctx = ctx;
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
        var batch: [ROUTER_BATCH_SIZE]proc.ProcessorOutput = undefined;
        _ = self.drainOnce(batch[0..]);
        std.log.info("OutputRouter stopped (routed={}, dropped={}, critical_drops={}, unknown_client={})", .{
            self.stats.messages_routed,
            self.stats.messages_dropped,
            self.stats.critical_drops,
            self.stats.unknown_client_drops,
        });
    }
    pub fn setMulticastEnabled(self: *Self, enabled: bool) void {
        self.multicast_enabled = enabled;
    }
    pub fn setMulticastCallback(self: *Self, cb: MulticastCallback, ctx: ?*anyopaque) void {
        self.multicast_cb = cb;
        self.multicast_ctx = ctx;
    }
    pub fn registerClient(self: *Self, client_id: config.ClientId) ?*ClientOutputQueue {
        if (client_id == 0) return null;
        if (config.isUdpClient(client_id)) {
            std.log.warn("OutputRouter: rejected UDP client_id {} for TCP registration", .{client_id});
            return null;
        }
        if (self.registry.get(client_id)) |existing| {
            std.log.debug("OutputRouter: client {} already registered, returning existing queue", .{client_id});
            return existing;
        }
        const q = self.allocator.create(ClientOutputQueue) catch {
            std.log.err("OutputRouter: failed to allocate ClientOutputQueue for client {}", .{client_id});
            return null;
        };
        q.* = ClientOutputQueue.init();
        self.registry.set(client_id, q);
        std.log.debug("OutputRouter: registered client {} with new queue", .{client_id});
        return q;
    }
    pub fn unregisterClient(self: *Self, client_id: config.ClientId) void {
        if (client_id == 0) return;
        const q = self.registry.get(client_id);
        self.registry.set(client_id, null);
        if (q) |qq| {
            self.allocator.destroy(qq);
            std.log.debug("OutputRouter: unregistered client {}", .{client_id});
        }
    }
    pub fn getClientQueue(self: *Self, client_id: config.ClientId) ?*ClientOutputQueue {
        return self.registry.get(client_id);
    }
    pub fn getStats(self: *const Self) RouterStats {
        return self.stats;
    }
    fn runLoop(self: *Self) void {
        var batch: [ROUTER_BATCH_SIZE]proc.ProcessorOutput = undefined;
        var consecutive_idle: u32 = 0;
        while (self.running.load(.acquire)) {
            const drained = self.drainOnce(batch[0..]);
            if (drained == 0) {
                consecutive_idle += 1;
                if (consecutive_idle < IDLE_SPIN_COUNT) {
                    std.atomic.spinLoopHint();
                } else {
                    std.Thread.sleep(SLEEP_TIME_NS);
                }
            } else {
                consecutive_idle = 0;
            }
        }
    }
    fn drainOnce(self: *Self, batch: []proc.ProcessorOutput) usize {
        var total: usize = 0;
        for (self.processor_queues, 0..) |q, qi| {
            var per_q: usize = 0;
            while (per_q < MAX_DRAIN_PER_QUEUE_PER_TICK and total < MAX_TOTAL_DRAIN_PER_TICK) {
                const want = @min(batch.len, MAX_DRAIN_PER_QUEUE_PER_TICK - per_q);
                
                // DEBUG TIMING (uncomment to diagnose):
                // const pop_start = std.time.microTimestamp();
                const got = q.popBatch(batch[0..want]);
                // const pop_end = std.time.microTimestamp();
                
                if (got == 0) break;
                
                // DEBUG TIMING (uncomment to diagnose):
                // const pop_us = pop_end - pop_start;
                // if (pop_us > 100000) {
                //     std.log.warn("popBatch took {}us for {} items", .{pop_us, got});
                // }
                
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
        if (self.notify_cb) |cb| cb(self.notify_ctx);
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
            self.stats.mcast_messages += 1;
        }
    }
    fn routeOne(self: *Self, po: *const proc.ProcessorOutput) void {
        const client_id: config.ClientId = @intCast(po.client_id);
        const out_msg: *const msg.OutputMsg = &po.message;
        
        // DEBUG TIMING (uncomment to diagnose):
        // const time_begin = std.time.microTimestamp();
        
        const q = self.registry.get(client_id) orelse {
            self.stats.messages_dropped += 1;
            self.stats.unknown_client_drops += 1;
            if (isCritical(out_msg)) self.stats.critical_drops += 1;
            return;
        };
        
        // DEBUG TIMING (uncomment to diagnose):
        // const after_lookup = std.time.microTimestamp();
        
        const output = ClientOutput.init(po.message, client_id, 0);
        
        if (!q.push(output)) {
            self.stats.messages_dropped += 1;
            if (isCritical(out_msg)) self.stats.critical_drops += 1;
            return;
        }
        
        // DEBUG TIMING (uncomment to diagnose):
        // const after_push = std.time.microTimestamp();
        
        self.stats.messages_routed += 1;
        
        // DEBUG: Log every 10000th message with timing breakdown (uncomment to diagnose):
        // if (self.stats.messages_routed % 10000 == 0) {
        //     const ts = std.time.milliTimestamp();
        //     const lookup_us = after_lookup - time_begin;
        //     const push_us = after_push - after_lookup;
        //     const total_us = after_push - time_begin;
        //     std.log.warn("OutputRouter: routed {} at ts={}, timing: lookup={}us push={}us total={}us", .{
        //         self.stats.messages_routed, ts, lookup_us, push_us, total_us
        //     });
        // }
        
        self.maybeMulticast(out_msg);
    }
};
