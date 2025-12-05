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
//! - All large structures heap-allocated
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

/// Channel capacity (must be power of 2).
/// 8192 provides ~0.8ms buffer at 10M msgs/sec while keeping memory bounded.
pub const CHANNEL_CAPACITY: usize = 8192;

/// Maximum iterations per poll cycle.
const MAX_POLL_ITERATIONS: u32 = 1000;

// ============================================================================
// Message Types
// ============================================================================

/// Input message with metadata for processor.
pub const ProcessorInput = struct {
    /// The actual message.
    message: msg.InputMsg,
    /// Client ID for response routing.
    client_id: u32,
    /// Timestamp when enqueued (for latency tracking).
    enqueue_time_ns: i64,
};

/// Output message with metadata.
pub const ProcessorOutput = struct {
    /// The output message.
    message: msg.OutputMsg,
    /// Processing latency in nanoseconds.
    latency_ns: i64,
};

// ============================================================================
// Channel Types (using raw SPSC queues, heap-allocated)
// ============================================================================

/// Input queue type.
pub const InputQueue = SpscQueue(ProcessorInput, CHANNEL_CAPACITY);

/// Output queue type.
pub const OutputQueue = SpscQueue(ProcessorOutput, CHANNEL_CAPACITY);

// ============================================================================
// Processor ID
// ============================================================================

/// Processor identifier.
pub const ProcessorId = enum(u8) {
    /// Processor 0: handles symbols A-M.
    processor_0 = 0,
    /// Processor 1: handles symbols N-Z.
    processor_1 = 1,

    pub fn name(self: ProcessorId) []const u8 {
        return switch (self) {
            .processor_0 => "Processor-0 (A-M)",
            .processor_1 => "Processor-1 (N-Z)",
        };
    }
};

/// Route symbol to processor based on first character.
/// A-M → processor_0, N-Z → processor_1
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

/// Processor statistics.
pub const ProcessorStats = struct {
    messages_processed: u64,
    outputs_generated: u64,
    input_queue_depth: usize,
    output_queue_depth: usize,
    total_processing_time_ns: i64,
    min_latency_ns: i64,
    max_latency_ns: i64,
    output_backpressure_count: u64,
    idle_cycles: u64,
};

// ============================================================================
// Processor
// ============================================================================

/// Matching processor that runs in its own thread.
/// All large structures are heap-allocated for bounded stack usage.
pub const Processor = struct {
    /// Processor identifier.
    id: ProcessorId,

    /// Memory pools for orders (heap allocated).
    pools: *MemoryPools,

    /// Matching engine (heap allocated - ~7.5GB per engine!).
    engine: *MatchingEngine,

    /// Input queue pointer (heap allocated, owned by ThreadedServer).
    input: *InputQueue,

    /// Output queue pointer (heap allocated, owned by ThreadedServer).
    output: *OutputQueue,

    /// Output buffer (heap allocated - ~800KB).
    output_buffer: *OutputBuffer,

    /// Thread handle.
    thread: ?std.Thread = null,

    /// Running flag.
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Allocator for cleanup.
    allocator: std.mem.Allocator,

    // === Statistics ===
    messages_processed: u64 = 0,
    outputs_generated: u64 = 0,
    total_processing_time_ns: i64 = 0,
    min_latency_ns: i64 = std.math.maxInt(i64),
    max_latency_ns: i64 = 0,
    output_backpressure_count: u64 = 0,
    idle_cycles: u64 = 0,

    const Self = @This();

    /// Initialize processor with pre-allocated queues.
    pub fn init(
        allocator: std.mem.Allocator,
        id: ProcessorId,
        input: *InputQueue,
        output: *OutputQueue,
    ) !Self {
        // Heap allocate pools
        const pools = try allocator.create(MemoryPools);
        errdefer allocator.destroy(pools);
        pools.* = try MemoryPools.init(allocator);
        errdefer pools.deinit();

        // Heap allocate engine (this is ~7.5GB!)
        const engine = try allocator.create(MatchingEngine);
        errdefer allocator.destroy(engine);
        engine.* = MatchingEngine.init(pools);

        // Heap allocate output buffer (~800KB)
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

    /// Cleanup processor.
    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.destroy(self.output_buffer);
        self.allocator.destroy(self.engine);
        self.pools.deinit();
        self.allocator.destroy(self.pools);
    }

    /// Start processor thread.
    pub fn start(self: *Self) !void {
        std.debug.assert(!self.running.load(.acquire));
        std.debug.assert(self.thread == null);

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});

        std.log.info("{s} started", .{self.id.name()});
    }

    /// Stop processor thread.
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

        std.log.info("{s} stopped (processed {d} messages)", .{
            self.id.name(),
            self.messages_processed,
        });
    }

    /// Main processing loop.
    fn runLoop(self: *Self) void {
        std.log.debug("{s} thread started", .{self.id.name()});

        while (self.running.load(.acquire)) {
            const processed = self.pollOnce();

            if (processed == 0) {
                self.idle_cycles += 1;
                std.Thread.yield() catch {};
            }
        }

        self.drainRemaining();
        std.log.debug("{s} thread exiting", .{self.id.name()});
    }

    /// Process one batch of messages.
    fn pollOnce(self: *Self) usize {
        var count: usize = 0;

        while (count < MAX_POLL_ITERATIONS) {
            const input_msg = self.input.pop() orelse break;
            count += 1;
            self.handleMessage(&input_msg);
        }

        return count;
    }

    /// Process a single input message.
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

        for (self.output_buffer.slice()) |out_msg| {
            const proc_output = ProcessorOutput{
                .message = out_msg,
                .latency_ns = queue_latency,
            };

            if (!self.output.push(proc_output)) {
                self.output_backpressure_count += 1;
            } else {
                self.outputs_generated += 1;
            }
        }
    }

    /// Drain remaining messages on shutdown.
    fn drainRemaining(self: *Self) void {
        var drained: usize = 0;

        while (self.input.pop()) |input_msg| {
            self.handleMessage(&input_msg);
            drained += 1;
        }

        if (drained > 0) {
            std.log.debug("{s} drained {d} remaining messages", .{ self.id.name(), drained });
        }
    }

    /// Get statistics snapshot.
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
