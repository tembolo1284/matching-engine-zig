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

        std.log.info("{s} started", .{self.id.name()});
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

        std.log.info("{s} stopped (processed {d} messages, {d} outputs, {d} backpressure, {d} spin waits)", .{
            self.id.name(),
            self.messages_processed,
            self.outputs_generated,
            self.output_backpressure_count,
            self.output_spin_waits,
        });
    }

    fn runLoop(self: *Self) void {
        std.log.debug("{s} thread started", .{self.id.name()});

        while (self.running.load(.acquire)) {
            const processed = self.pollOnce();

            if (processed == 0) {
                self.idle_cycles += 1;
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
        const start_time: i64 = @truncate(std.time.nanoTimestamp());

        self.output_buffer.clear();
        self.engine.processMessage(&input.message, input.client_id, self.output_buffer);

        const end_time: i64 = @truncate(std.time.nanoTimestamp());
        const processing_time = end_time - start_time;
        const queue_latency = start_time - input.enqueue_time_ns;

        self.messages_processed += 1;
        self.total_processing_time_ns += processing_time;
        self.min_latency_ns = @min(self.min_latency_ns, queue_latency);
        self.max_latency_ns = @max(self.max_latency_ns, queue_latency);

        // Send outputs with retry on backpressure
        for (self.output_buffer.slice()) |out_msg| {
            const proc_output = ProcessorOutput{
                .message = out_msg,
                .latency_ns = queue_latency,
            };

            if (!self.pushOutputWithRetry(proc_output)) {
                // After retries, still couldn't push - count as dropped
                self.output_backpressure_count += 1;
            } else {
                self.outputs_generated += 1;
            }
        }
    }

    /// Try to push output, with brief spin-wait on backpressure
    /// This gives the I/O thread time to drain before we drop
    fn pushOutputWithRetry(self: *Self, output: ProcessorOutput) bool {
        // First try - fast path
        if (self.output.push(output)) {
            return true;
        }

        // Queue is full - spin briefly waiting for space
        var spins: u32 = 0;
        while (spins < OUTPUT_SPIN_COUNT) : (spins += 1) {
            // Hint to CPU we're spinning
            std.atomic.spinLoopHint();

            if (self.output.push(output)) {
                self.output_spin_waits += 1;
                return true;
            }
        }

        // Still full after spinning - give up
        return false;
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
            .idle_cycles = self.idle_cycles,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "routeSymbol - A-M to processor 0" {
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("AAPL")));
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("MSFT")));
}

test "routeSymbol - N-Z to processor 1" {
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("NVDA")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("TSLA")));
}

test "routeSymbol - empty symbol" {
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.EMPTY_SYMBOL));
}
