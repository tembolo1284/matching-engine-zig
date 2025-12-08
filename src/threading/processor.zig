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
pub const CHANNEL_CAPACITY: usize = 65536;

/// Max messages to process per poll iteration
/// Prevents starvation but allows good throughput
const MAX_POLL_ITERATIONS: u32 = 1000;

/// Spin count before yielding when waiting for output queue space
const OUTPUT_SPIN_COUNT: u32 = 100;

/// Yield count before giving up on output queue space
const OUTPUT_YIELD_COUNT: u32 = 50;

/// Enable latency tracking (adds ~100-200ns per message from syscalls)
/// Set to false for maximum performance in production
pub const TRACK_LATENCY: bool = true;

/// In debug/safe builds, panic if critical messages are dropped
/// Critical = trades, rejects (clients MUST receive these)
const PANIC_ON_CRITICAL_DROP: bool = std.debug.runtime_safety;

// ============================================================================
// Message Types
// ============================================================================

pub const ProcessorInput = struct {
    message: msg.InputMsg,
    client_id: u32,
    enqueue_time_ns: i64,
};

pub const ProcessorOutput = struct {
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
};

pub fn routeSymbol(symbol: msg.Symbol) ProcessorId {
    const first = symbol[0];
    if (first == 0) return .processor_0;
    const upper = first & 0xDF;
    if (upper >= 'A' and upper <= 'M') {
        return .processor_0;
    }
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
        // Initialize all large structures on the heap in a simple,
        // linear fashion (P10: avoid clever control flow).

        // 1) Memory pools (heap-allocated, returns pointer)
        const pools = try MemoryPools.init(allocator);
        errdefer pools.deinit();

        // 2) Matching engine (owns big hash tables; uses MemoryPools allocator)
        const engine = try allocator.create(MatchingEngine);
        errdefer allocator.destroy(engine);
        engine.initInPlace(pools);

        // 3) Output buffer (~800KB); no dynamic allocation in hot path
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
        // Idempotent-ish shutdown: stop thread, then tear down heap state
        self.stop();

        // Matching engine may own OrderBooks and other heap objects;
        // deinit them before we free the allocator-backed pools.
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.allocator.destroy(self.output_buffer);

        // MemoryPools.deinit() handles its own destroy
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
        if (!self.running.load(.acquire)) {
            return;
        }

        std.log.info("{s} stopping...", .{self.id.name()});
        self.running.store(false, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        std.log.info("{s} stopped (processed={d}, outputs={d}, backpressure={d}, spins={d}, yields={d}, critical_drops={d}, non_critical_drops={d})", .{
            self.id.name(),
            self.messages_processed,
            self.outputs_generated,
            self.output_backpressure_count,
            self.output_spin_waits,
            self.output_yield_waits,
            self.critical_drops,
            self.non_critical_drops,
        });
    }

    fn runLoop(self: *Self) void {
        std.log.debug("{s} thread started", .{self.id.name()});

        while (self.running.load(.acquire)) {
            const processed = self.pollOnce();

            if (processed == 0) {
                // Saturating add to prevent overflow (not that it matters after 584 years)
                self.idle_cycles +|= 1;
                // Yield is bounded and explicit; no busy loops.
                std.Thread.yield() catch {};
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
        // Conditional timestamp to avoid syscall overhead in production
        const start_time: i128 = if (TRACK_LATENCY) std.time.nanoTimestamp() else 0;

        self.output_buffer.clear();
        self.engine.processMessage(&input.message, input.client_id, self.output_buffer);

        // Update timing stats if tracking enabled
        if (TRACK_LATENCY) {
            const end_time = std.time.nanoTimestamp();
            const processing_time = end_time - start_time;
            const queue_latency = start_time - input.enqueue_time_ns;

            // Safe conversion to i64 (clamping if somehow > 292 years)
            const processing_i64: i64 = @intCast(@min(processing_time, std.math.maxInt(i64)));
            const queue_latency_i64: i64 = @intCast(@min(@max(queue_latency, 0), std.math.maxInt(i64)));

            self.total_processing_time_ns += processing_i64;
            self.min_latency_ns = @min(self.min_latency_ns, queue_latency_i64);
            self.max_latency_ns = @max(self.max_latency_ns, queue_latency_i64);
        }

        self.messages_processed += 1;

        // Send outputs with extended retry on backpressure
        const latency_for_output: i64 = if (TRACK_LATENCY)
            @intCast(@min(@max(std.time.nanoTimestamp() - input.enqueue_time_ns, 0), std.math.maxInt(i64)))
        else
            0;

        for (self.output_buffer.slice()) |out_msg| {
            const proc_output = ProcessorOutput{
                .message = out_msg,
                .latency_ns = latency_for_output,
            };

            const push_result = self.pushOutputWithRetry(proc_output);

            if (push_result.success) {
                self.outputs_generated += 1;
                if (push_result.spin_waited) {
                    self.output_spin_waits += 1;
                }
                if (push_result.yield_waited) {
                    self.output_yield_waits += 1;
                }
            } else {
                self.output_backpressure_count += 1;
                self.handleDroppedOutput(&out_msg);
            }
        }
    }

    const PushResult = struct {
        success: bool,
        spin_waited: bool,
        yield_waited: bool,
    };

    /// Try to push output with extended retry on backpressure.
    /// Uses spin-wait, then yield-wait before giving up.
    fn pushOutputWithRetry(self: *Self, output: ProcessorOutput) PushResult {
        // First try - fast path
        if (self.output.push(output)) {
            return .{ .success = true, .spin_waited = false, .yield_waited = false };
        }

        // Queue is full - spin briefly waiting for space
        var spins: u32 = 0;
        while (spins < OUTPUT_SPIN_COUNT) : (spins += 1) {
            std.atomic.spinLoopHint();

            if (self.output.push(output)) {
                return .{ .success = true, .spin_waited = true, .yield_waited = false };
            }
        }

        // Still full - yield to let I/O thread drain
        var yields: u32 = 0;
        while (yields < OUTPUT_YIELD_COUNT) : (yields += 1) {
            std.Thread.yield() catch {};

            if (self.output.push(output)) {
                return .{ .success = true, .spin_waited = true, .yield_waited = true };
            }
        }

        // Still full after extended retry - give up
        return .{ .success = false, .spin_waited = true, .yield_waited = true };
    }

    /// Handle a dropped output message - log details and potentially panic.
    fn handleDroppedOutput(self: *Self, out_msg: *const msg.OutputMsg) void {
        const is_critical = switch (out_msg.msg_type) {
            .trade, .reject => true,
            .ack, .cancel_ack, .top_of_book => false,
        };

        if (is_critical) {
            self.critical_drops += 1;

            // Log full details for critical drops
            std.log.err("CRITICAL OUTPUT DROPPED: {s} type={s} client={d} symbol={s} user={d} order={d}", .{
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
            });

            // In debug builds, panic on critical drops - this is unacceptable
            if (PANIC_ON_CRITICAL_DROP) {
                @panic("Critical output message dropped - output queue overflow");
            }
        } else {
            self.non_critical_drops += 1;

            // Log warning for non-critical drops
            std.log.warn("Output dropped: {s} type={s} client={d}", .{
                self.id.name(),
                @tagName(out_msg.msg_type),
                out_msg.client_id,
            });
        }
    }

    fn drainRemaining(self: *Self) void {
        var drained: usize = 0;

        while (self.input.pop()) |input_msg| {
            self.handleMessage(&input_msg);
            drained += 1;
        }

        if (drained > 0) {
            std.log.debug("{s} drained {d} remaining messages", .{
                self.id.name(),
                drained,
            });
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

    /// Check if any critical messages have been dropped.
    /// Returns true if system is healthy (no critical drops).
    pub fn isHealthy(self: *const Self) bool {
        return self.critical_drops == 0;
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
