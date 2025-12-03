//! Matching engine processor thread.
//!
//! Each processor handles a subset of symbols and runs on its own thread.
//! Receives messages from I/O thread via input channel.
//! Sends responses back via output channel.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const MatchingEngine = @import("../core/matching_engine.zig").MatchingEngine;
const OutputBuffer = @import("../core/order_book.zig").OutputBuffer;
const MemoryPools = @import("../core/memory_pool.zig").MemoryPools;
const BoundedChannel = @import("../collections/bounded_channel.zig").BoundedChannel;
const config = @import("../transport/config.zig");

/// Channel capacity - must be power of 2
pub const CHANNEL_CAPACITY = 65536;

/// Message sent from I/O thread to processor
pub const ProcessorInput = struct {
    message: msg.InputMsg,
    client_id: config.ClientId,
};

/// Message sent from processor back to I/O thread
pub const ProcessorOutput = struct {
    message: msg.OutputMsg,
};

/// Input channel type
pub const InputChannel = BoundedChannel(ProcessorInput, CHANNEL_CAPACITY);

/// Output channel type  
pub const OutputChannel = BoundedChannel(ProcessorOutput, CHANNEL_CAPACITY);

/// Processor ID
pub const ProcessorId = enum(u8) {
    processor_0 = 0, // Symbols A-M
    processor_1 = 1, // Symbols N-Z
};

/// Determine which processor handles a symbol
pub fn routeSymbol(symbol: msg.Symbol) ProcessorId {
    const first = symbol[0];

    // Normalize to uppercase
    const upper: u8 = if (first >= 'a' and first <= 'z')
        first - 'a' + 'A'
    else
        first;

    // A-M → Processor 0, N-Z → Processor 1
    if (upper >= 'A' and upper <= 'M') {
        return .processor_0;
    } else if (upper >= 'N' and upper <= 'Z') {
        return .processor_1;
    } else {
        // Non-alphabetic defaults to processor 0
        return .processor_0;
    }
}

/// Processor thread state
pub const Processor = struct {
    id: ProcessorId,
    engine: MatchingEngine,
    pools: MemoryPools,

    input: *InputChannel,
    output: *OutputChannel,

    output_buffer: OutputBuffer,

    // Thread handle
    thread: ?std.Thread = null,

    // Control
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Statistics
    messages_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    outputs_generated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        id: ProcessorId,
        input: *InputChannel,
        output: *OutputChannel,
    ) !Self {
        var pools = try MemoryPools.init(allocator);

        return .{
            .id = id,
            .engine = MatchingEngine.init(&pools),
            .pools = pools,
            .input = input,
            .output = output,
            .output_buffer = OutputBuffer.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.pools.deinit();
    }

    /// Start processor thread
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, processorLoop, .{self});

        std.log.info("Processor {} started", .{@intFromEnum(self.id)});
    }

    /// Stop processor thread
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        std.log.info("Processor {} stopped", .{@intFromEnum(self.id)});
    }

    /// Main processor loop (runs in separate thread)
    fn processorLoop(self: *Self) void {
        std.log.info("Processor {} loop started", .{@intFromEnum(self.id)});

        while (self.running.load(.acquire)) {
            // Try to get message from input channel
            if (self.input.tryRecv()) |input| {
                self.processMessage(&input);
            } else {
                // No message - brief pause to avoid burning CPU
                std.atomic.spinLoopHint();
            }
        }

        std.log.info("Processor {} loop ended", .{@intFromEnum(self.id)});
    }

    fn processMessage(self: *Self, input: *const ProcessorInput) void {
        self.output_buffer.clear();

        // Process through matching engine
        self.engine.processMessage(&input.message, input.client_id, &self.output_buffer);

        _ = self.messages_processed.fetchAdd(1, .monotonic);

        // Send outputs back to I/O thread
        for (self.output_buffer.slice()) |*out_msg| {
            const output = ProcessorOutput{ .message = out_msg.* };

            // Spin if output channel is full (backpressure)
            while (!self.output.send(output)) {
                std.atomic.spinLoopHint();
            }

            _ = self.outputs_generated.fetchAdd(1, .monotonic);
        }
    }

    /// Get statistics
    pub fn getStats(self: *const Self) struct { processed: u64, outputs: u64 } {
        return .{
            .processed = self.messages_processed.load(.monotonic),
            .outputs = self.outputs_generated.load(.monotonic),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "symbol routing" {
    // A-M → Processor 0
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("AAPL")));
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("IBM")));
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("META")));

    // N-Z → Processor 1
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("NVDA")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("TSLA")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("ZM")));

    // Lowercase should work too
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("aapl")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("nvda")));
}
