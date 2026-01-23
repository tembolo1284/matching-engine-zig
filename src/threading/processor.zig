//! Matching processor thread for the threaded server architecture.
//!
//! Each processor:
//! - Owns a subset of symbols (A-M or N-Z)
//! - Has its own matching engine instance
//! - Receives input via SPSC queue from I/O thread
//! - Sends output via SPSC queue to I/O thread
//!
//! Thread safety:
//! - Each processor runs in its own thread
//! - Communication via lock-free SPSC queues only
//! - No shared mutable state between processors
//!
//! Memory model (Power of Ten compliant):
//! - All large structures heap-allocated with initInPlace
//! - Bounded memory usage
//! - No dynamic allocation in hot path
//!
//! Backpressure handling:
//! - Output queue full triggers extended spin-wait with yields
//! - Critical messages (trades, rejects) get maximum retry effort
//! - Dropped messages are logged with full details for debugging
//! - In debug builds, dropping critical messages triggers panic
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: All loops bounded by explicit constants
//! - Rule 5: Assertions validate state transitions
//! - Rule 7: All queue operations checked
const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const MatchingEngine = @import("../core/matching_engine.zig").MatchingEngine;
const MemoryPools = @import("../core/memory_pool.zig").MemoryPools;
const OutputBuffer = @import("../core/order_book.zig").OutputBuffer;
const SpscQueue = @import("../collections/spsc_queue.zig").SpscQueue;

// ============================================================================
// Configuration
// ============================================================================

/// Channel capacity - must be power of 2
/// Increased from 8192 to handle high throughput scenarios
/// At 200K orders/sec with ~2 outputs per order, need substantial buffer
pub const CHANNEL_CAPACITY: usize = 4 * 65536;

/// Max messages to process per poll iteration
/// Higher value allows better throughput
const MAX_POLL_ITERATIONS: u32 = 8192;

/// Max messages to drain during shutdown.
/// P10 Rule 2: Bounds the drain loop to prevent infinite processing.
const MAX_DRAIN_ITERATIONS: u32 = CHANNEL_CAPACITY;

/// Spin count before yielding when waiting for output queue space
const OUTPUT_SPIN_COUNT: u32 = 1000;

/// Yield count before giving up on output queue space
const OUTPUT_YIELD_COUNT: u32 = 100;

/// Enable latency tracking (adds ~100-200ns per message from syscalls)
/// Set to false for maximum performance in production
pub const TRACK_LATENCY: bool = false;

/// In debug/safe builds, panic if critical messages are dropped
/// Critical = trades, rejects (clients MUST receive these)
const PANIC_ON_CRITICAL_DROP: bool = std.debug.runtime_safety;

/// Spin iterations before yielding in main loop when idle
const IDLE_SPIN_COUNT: u32 = 1000;

/// Consecutive idle polls (with yields) before sleeping
const IDLE_YIELD_THRESHOLD: u32 = 100;

/// Consecutive yields before sleeping
const IDLE_SLEEP_THRESHOLD: u32 = 1000;

/// Sleep duration when truly idle (nanoseconds)
/// Keep very short to maintain responsiveness
const IDLE_SLEEP_NS: u64 = 100; // 100ns - minimal sleep

comptime {
    // CHANNEL_CAPACITY must be power of 2
    std.debug.assert(CHANNEL_CAPACITY > 0);
    std.debug.assert((CHANNEL_CAPACITY & (CHANNEL_CAPACITY - 1)) == 0);
    // Iteration limits must be reasonable
    std.debug.assert(MAX_POLL_ITERATIONS > 0);
    std.debug.assert(MAX_POLL_ITERATIONS <= CHANNEL_CAPACITY);
    std.debug.assert(MAX_DRAIN_ITERATIONS > 0);
    std.debug.assert(MAX_DRAIN_ITERATIONS <= CHANNEL_CAPACITY * 2);
    // Spin/yield counts must be bounded
    std.debug.assert(OUTPUT_SPIN_COUNT > 0);
    std.debug.assert(OUTPUT_SPIN_COUNT <= 10000);
    std.debug.assert(OUTPUT_YIELD_COUNT > 0);
    std.debug.assert(OUTPUT_YIELD_COUNT <= 1000);
    // Idle thresholds must be in correct order
    std.debug.assert(IDLE_SPIN_COUNT > 0);
    std.debug.assert(IDLE_YIELD_THRESHOLD > 0);
    std.debug.assert(IDLE_SLEEP_THRESHOLD > IDLE_YIELD_THRESHOLD);
}

// ============================================================================
// Message Types
// ============================================================================

pub const ProcessorInput = struct {
    message: msg.InputMsg,
    client_id: u32,
    enqueue_time_ns: i64,
};

/// IMPORTANT FIX:
/// ProcessorOutput MUST carry client_id so OutputRouter can route correctly.
pub const ProcessorOutput = struct {
    client_id: u32,
    message: msg.OutputMsg,
    latency_ns: i64,
};

// ============================================================================
// Channel Types
// ============================================================================

pub const InputQueue = SpscQueue(ProcessorInput, CHANNEL_CAPACITY);
pub const OutputQueue = SpscQueue(ProcessorOutput, CHANNEL_CAPACITY);

// ============================================================================
// Processor ID
// ============================================================================

pub const ProcessorId = enum(u8) {
    processor_0 = 0,
    processor_1 = 1,

    pub fn name(self: ProcessorId) []const u8 {
        return switch (self) {
            .processor_0 => "Processor-0 (A-M)",
            .processor_1 => "Processor-1 (N-Z)",
        };
    }

    pub fn index(self: ProcessorId) usize {
        return @intFromEnum(self);
    }
};

/// Route symbol to processor based on first character.
/// A-M (and non-alphabetic) → processor_0
/// N-Z → processor_1
pub fn routeSymbol(symbol: msg.Symbol) ProcessorId {
    const first = symbol[0];
    if (first == 0) return .processor_0;
    const upper = first & 0xDF; // Convert to uppercase
    if (upper >= 'A' and upper <= 'M') return .processor_0;
    return .processor_1;
}

// ============================================================================
// Statistics
// ============================================================================

pub const ProcessorStats = struct {
    messages_processed: u64,
    outputs_generated: u64,
    input_queue_depth: usize,
    output_queue_depth: usize,
    total_processing_time_ns: i64,
    min_latency_ns: i64,
    max_latency_ns: i64,
    output_backpressure_count: u64,
    output_spin_waits: u64,
    output_yield_waits: u64,
    critical_drops: u64,
    non_critical_drops: u64,
    idle_cycles: u64,

    pub fn isHealthy(self: ProcessorStats) bool {
        return self.critical_drops == 0;
    }

    pub fn avgProcessingTimeNs(self: ProcessorStats) i64 {
        if (self.messages_processed == 0) return 0;
        return @divTrunc(self.total_processing_time_ns, @as(i64, @intCast(self.messages_processed)));
    }
};

// ============================================================================
// Processor
// ============================================================================

pub const Processor = struct {
    id: ProcessorId,
    pools: *MemoryPools,
    engine: *MatchingEngine,
    input: *InputQueue,
    output: *OutputQueue,
    output_buffer: *OutputBuffer,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,

    // Statistics
    messages_processed: u64 = 0,
    outputs_generated: u64 = 0,
    total_processing_time_ns: i64 = 0,
    min_latency_ns: i64 = std.math.maxInt(i64),
    max_latency_ns: i64 = 0,
    output_backpressure_count: u64 = 0,
    output_spin_waits: u64 = 0,
    output_yield_waits: u64 = 0,
    critical_drops: u64 = 0,
    non_critical_drops: u64 = 0,
    idle_cycles: u64 = 0,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        id: ProcessorId,
        input: *InputQueue,
        output: *OutputQueue,
    ) !Self {
        const pools = try MemoryPools.init(allocator);
        errdefer pools.deinit();

        const engine = try allocator.create(MatchingEngine);
        errdefer allocator.destroy(engine);
        engine.initInPlace(pools);

        const output_buffer = try allocator.create(OutputBuffer);
        errdefer allocator.destroy(output_buffer);
        output_buffer.* = OutputBuffer.init();

        return .{
            .id = id,
            .pools = pools,
            .engine = engine,
            .input = input,
            .output = output,
            .output_buffer = output_buffer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.allocator.destroy(self.output_buffer);
        self.pools.deinit();
    }

    pub fn start(self: *Self) !void {
        std.debug.assert(!self.running.load(.acquire));
        std.debug.assert(self.thread == null);
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
        std.log.info("{s} started (latency_tracking={}, panic_on_critical_drop={})", .{
            self.id.name(),
            TRACK_LATENCY,
            PANIC_ON_CRITICAL_DROP,
        });
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;
        std.log.info("{s} stopping...", .{self.id.name()});
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        std.log.info(
            "{s} stopped (processed={d}, outputs={d}, backpressure={d}, spins={d}, yields={d}, critical_drops={d}, non_critical_drops={d})",
            .{
                self.id.name(),
                self.messages_processed,
                self.outputs_generated,
                self.output_backpressure_count,
                self.output_spin_waits,
                self.output_yield_waits,
                self.critical_drops,
                self.non_critical_drops,
            },
        );
    }

    fn runLoop(self: *Self) void {
        std.log.debug("{s} thread started", .{self.id.name()});
        var consecutive_idle: u32 = 0;
        while (self.running.load(.acquire)) {
            const processed = self.pollOnce();
            if (processed == 0) {
                consecutive_idle += 1;
                self.idle_cycles +|= 1;
                // Progressive backoff: spin → yield → sleep
                if (consecutive_idle < IDLE_SPIN_COUNT) {
                    std.atomic.spinLoopHint();
                } else if (consecutive_idle < IDLE_SLEEP_THRESHOLD) {
                    std.Thread.yield() catch {};
                } else {
                    std.Thread.sleep(IDLE_SLEEP_NS);
                }
            } else {
                consecutive_idle = 0;
            }
        }
        self.drainRemaining();
        std.log.debug("{s} thread exiting", .{self.id.name()});
    }

    fn pollOnce(self: *Self) usize {
        var count: usize = 0;
        while (count < MAX_POLL_ITERATIONS) : (count += 1) {
            const input_msg = self.input.pop() orelse break;
            self.handleMessage(&input_msg);
        }
        return count;
    }

    fn handleMessage(self: *Self, input: *const ProcessorInput) void {
        std.debug.assert(input.client_id != 0 or input.message.msg_type == .flush);
        const start_time: i128 = if (TRACK_LATENCY) std.time.nanoTimestamp() else 0;
        self.output_buffer.clear();
        self.engine.processMessage(&input.message, input.client_id, self.output_buffer);
        if (TRACK_LATENCY) {
            const end_time = std.time.nanoTimestamp();
            const processing_time = end_time - start_time;
            const queue_latency = start_time - input.enqueue_time_ns;
            const processing_i64: i64 = @intCast(@min(processing_time, std.math.maxInt(i64)));
            const queue_latency_i64: i64 = @intCast(@min(@max(queue_latency, 0), std.math.maxInt(i64)));
            self.total_processing_time_ns += processing_i64;
            self.min_latency_ns = @min(self.min_latency_ns, queue_latency_i64);
            self.max_latency_ns = @max(self.max_latency_ns, queue_latency_i64);
        }
        self.messages_processed += 1;
        const latency_for_output: i64 = if (TRACK_LATENCY)
            @intCast(@min(@max(std.time.nanoTimestamp() - input.enqueue_time_ns, 0), std.math.maxInt(i64)))
        else
            0;
        const outputs = self.output_buffer.slice();
        for (outputs) |out_msg| {
            const proc_output = ProcessorOutput{
                .client_id = input.client_id,
                .message = out_msg,
                .latency_ns = latency_for_output,
            };
            if (self.output.push(proc_output)) {
                self.outputs_generated += 1;
            } else {
                const push_result = self.pushOutputWithRetry(proc_output);
                if (push_result.success) {
                    self.outputs_generated += 1;
                    if (push_result.spin_waited) self.output_spin_waits += 1;
                    if (push_result.yield_waited) self.output_yield_waits += 1;
                } else {
                    self.output_backpressure_count += 1;
                    self.handleDroppedOutput(&out_msg);
                }
            }
        }
        if (self.outputs_generated % 10000 == 0 and self.outputs_generated > 0) {
            const ts = std.time.milliTimestamp();
            std.log.warn("Processor {}: generated {} outputs at ts={}", .{ @intFromEnum(self.id), self.outputs_generated, ts });
        }
    }

    const PushResult = struct {
        success: bool,
        spin_waited: bool,
        yield_waited: bool,
    };

    fn pushOutputWithRetry(self: *Self, output: ProcessorOutput) PushResult {
        var spins: u32 = 0;
        while (spins < OUTPUT_SPIN_COUNT) : (spins += 1) {
            std.atomic.spinLoopHint();
            if (self.output.push(output)) {
                return .{ .success = true, .spin_waited = true, .yield_waited = false };
            }
        }
        var yields: u32 = 0;
        while (yields < OUTPUT_YIELD_COUNT) : (yields += 1) {
            std.Thread.yield() catch {};
            if (self.output.push(output)) {
                return .{ .success = true, .spin_waited = true, .yield_waited = true };
            }
        }
        return .{ .success = false, .spin_waited = true, .yield_waited = true };
    }

    fn handleDroppedOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        const is_critical = switch (out_msg.msg_type) {
            .trade, .reject => true,
            .ack, .cancel_ack, .top_of_book => false,
        };
        if (is_critical) {
            self.critical_drops += 1;
            std.log.err(
                "CRITICAL OUTPUT DROPPED: {s} type={s} client={d} symbol={s} user={d} order={d}",
                .{
                    self.id.name(),
                    @tagName(out_msg.msg_type),
                    out_msg.client_id,
                    msg.symbolSlice(&out_msg.symbol),
                    out_msg.getUserId(),
                    switch (out_msg.msg_type) {
                        .trade => out_msg.data.trade.buy_order_id,
                        .reject => out_msg.data.reject.user_order_id,
                        .ack => out_msg.data.ack.user_order_id,
                        .cancel_ack => out_msg.data.cancel_ack.user_order_id,
                        .top_of_book => 0,
                    },
                },
            );
            if (PANIC_ON_CRITICAL_DROP) {
                @panic("Critical output message dropped - output queue overflow");
            }
        } else {
            self.non_critical_drops += 1;
            std.log.warn("Output dropped: {s} type={s} client={d}", .{
                self.id.name(),
                @tagName(out_msg.msg_type),
                out_msg.client_id,
            });
        }
    }

    fn drainRemaining(self: *Self) void {
        var drained: u32 = 0;
        while (drained < MAX_DRAIN_ITERATIONS) : (drained += 1) {
            const input_msg = self.input.pop() orelse break;
            self.handleMessage(&input_msg);
        }
        if (drained > 0) {
            std.log.debug("{s} drained {d} remaining messages", .{ self.id.name(), drained });
        }
        if (drained >= MAX_DRAIN_ITERATIONS) {
            const remaining = self.input.size();
            if (remaining > 0) {
                std.log.warn("{s} drain limit reached, {d} messages still in queue", .{
                    self.id.name(),
                    remaining,
                });
            }
        }
    }

    pub fn getStats(self: *const Self) ProcessorStats {
        return .{
            .messages_processed = self.messages_processed,
            .outputs_generated = self.outputs_generated,
            .input_queue_depth = self.input.size(),
            .output_queue_depth = self.output.size(),
            .total_processing_time_ns = self.total_processing_time_ns,
            .min_latency_ns = self.min_latency_ns,
            .max_latency_ns = self.max_latency_ns,
            .output_backpressure_count = self.output_backpressure_count,
            .output_spin_waits = self.output_spin_waits,
            .output_yield_waits = self.output_yield_waits,
            .critical_drops = self.critical_drops,
            .non_critical_drops = self.non_critical_drops,
            .idle_cycles = self.idle_cycles,
        };
    }

    pub fn isHealthy(self: *const Self) bool {
        return self.critical_drops == 0;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running.load(.acquire);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "routeSymbol - A-M to processor 0" {
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("AAPL")));
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("MSFT")));
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("IBM")));
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("GE")));
}

test "routeSymbol - N-Z to processor 1" {
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("NVDA")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("TSLA")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("XOM")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("ZM")));
}

test "routeSymbol - lowercase handled" {
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("aapl")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("tsla")));
}

test "routeSymbol - empty symbol" {
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.EMPTY_SYMBOL));
}

test "ProcessorStats default values" {
    const stats = ProcessorStats{
        .messages_processed = 0,
        .outputs_generated = 0,
        .input_queue_depth = 0,
        .output_queue_depth = 0,
        .total_processing_time_ns = 0,
        .min_latency_ns = std.math.maxInt(i64),
        .max_latency_ns = 0,
        .output_backpressure_count = 0,
        .output_spin_waits = 0,
        .output_yield_waits = 0,
        .critical_drops = 0,
        .non_critical_drops = 0,
        .idle_cycles = 0,
    };
    try std.testing.expectEqual(@as(u64, 0), stats.messages_processed);
    try std.testing.expectEqual(@as(u64, 0), stats.critical_drops);
    try std.testing.expect(stats.isHealthy());
}

test "ProcessorStats average processing time" {
    const stats = ProcessorStats{
        .messages_processed = 100,
        .outputs_generated = 200,
        .input_queue_depth = 0,
        .output_queue_depth = 0,
        .total_processing_time_ns = 1000000,
        .min_latency_ns = 100,
        .max_latency_ns = 50000,
        .output_backpressure_count = 0,
        .output_spin_waits = 0,
        .output_yield_waits = 0,
        .critical_drops = 0,
        .non_critical_drops = 0,
        .idle_cycles = 0,
    };
    try std.testing.expectEqual(@as(i64, 10000), stats.avgProcessingTimeNs());
}

test "PushResult flags" {
    const fast_path = Processor.PushResult{ .success = true, .spin_waited = false, .yield_waited = false };
    const spin_path = Processor.PushResult{ .success = true, .spin_waited = true, .yield_waited = false };
    const yield_path = Processor.PushResult{ .success = true, .spin_waited = true, .yield_waited = true };
    const failed = Processor.PushResult{ .success = false, .spin_waited = true, .yield_waited = true };

    try std.testing.expect(fast_path.success);
    try std.testing.expect(!fast_path.spin_waited);
    try std.testing.expect(spin_path.success);
    try std.testing.expect(spin_path.spin_waited);
    try std.testing.expect(!spin_path.yield_waited);
    try std.testing.expect(yield_path.success);
    try std.testing.expect(yield_path.yield_waited);
    try std.testing.expect(!failed.success);
}

test "ProcessorId name and index" {
    try std.testing.expectEqualStrings("Processor-0 (A-M)", ProcessorId.processor_0.name());
    try std.testing.expectEqualStrings("Processor-1 (N-Z)", ProcessorId.processor_1.name());
    try std.testing.expectEqual(@as(usize, 0), ProcessorId.processor_0.index());
    try std.testing.expectEqual(@as(usize, 1), ProcessorId.processor_1.index());
}

test "Configuration constants are valid" {
    try std.testing.expect(CHANNEL_CAPACITY > 0);
    try std.testing.expect((CHANNEL_CAPACITY & (CHANNEL_CAPACITY - 1)) == 0);
    try std.testing.expect(MAX_POLL_ITERATIONS > 0);
    try std.testing.expect(MAX_POLL_ITERATIONS <= CHANNEL_CAPACITY);
    try std.testing.expect(MAX_DRAIN_ITERATIONS > 0);
    try std.testing.expect(OUTPUT_SPIN_COUNT > 0);
    try std.testing.expect(OUTPUT_YIELD_COUNT > 0);
}
