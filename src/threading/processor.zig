//! Order Processor - Main Processing Loop
//!
//! Processes input messages through the matching engine and generates output.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const MatchingEngine = @import("../core/matching_engine.zig").MatchingEngine;
const OutputBuffer = @import("../core/output_buffer.zig").OutputBuffer;
const SpscQueue = @import("spsc_queue.zig");
const InputEnvelope = SpscQueue.InputEnvelope;
const OutputEnvelope = SpscQueue.OutputEnvelope;
const InputEnvelopeQueue = SpscQueue.InputEnvelopeQueue;
const OutputEnvelopeQueue = SpscQueue.OutputEnvelopeQueue;

pub const BATCH_SIZE: u32 = 32;
pub const MAX_LOOP_ITERATIONS: u32 = 1_000_000;
pub const SPIN_COUNT: u32 = 1000;

pub const ProcessorState = enum {
    idle,
    running,
    stopping,
    stopped,
};

pub const ProcessorStats = struct {
    messages_processed: u64,
    batches_processed: u64,
    trades_generated: u64,
    acks_generated: u64,
    cancel_acks_generated: u64,
    tob_generated: u64,
    flush_count: u64,
    empty_polls: u64,
    output_queue_full: u64,

    pub fn init() ProcessorStats {
        return ProcessorStats{
            .messages_processed = 0,
            .batches_processed = 0,
            .trades_generated = 0,
            .acks_generated = 0,
            .cancel_acks_generated = 0,
            .tob_generated = 0,
            .flush_count = 0,
            .empty_polls = 0,
            .output_queue_full = 0,
        };
    }
};

pub const Processor = struct {
    engine: MatchingEngine,
    output_buffer: OutputBuffer,
    state: ProcessorState,
    stats: ProcessorStats,
    sequence: u64,
    current_client_id: u32,
    flush_in_progress: bool,

    const Self = @This();

    /// Initialize processor in-place (avoids stack allocation of large struct)
    pub fn initInPlace(self: *Self) void {
        self.engine.initInPlace();
        self.output_buffer = OutputBuffer.init();
        self.state = .idle;
        self.stats = ProcessorStats.init();
        self.sequence = 0;
        self.current_client_id = 0;
        self.flush_in_progress = false;
    }

    /// Legacy init - WARNING: creates large struct on stack, may cause stack overflow
    pub fn init() Self {
        var self: Self = undefined;
        self.initInPlace();
        return self;
    }

    pub fn processMessage(self: *Self, input: *const msg.InputMsg, client_id: u32) void {
        std.debug.assert(self.state == .running or self.state == .idle);

        self.current_client_id = client_id;
        self.output_buffer.reset();

        switch (input.type) {
            .new_order => {
                self.engine.processNewOrder(&input.data.new_order, client_id, &self.output_buffer);
                self.stats.messages_processed += 1;
            },
            .cancel => {
                self.engine.processCancelOrder(&input.data.cancel, &self.output_buffer);
                self.stats.messages_processed += 1;
            },
            .flush => {
                self.engine.processFlush(&self.output_buffer);
                self.flush_in_progress = self.engine.hasFlushInProgress();
                self.stats.flush_count += 1;
                self.stats.messages_processed += 1;
            },
        }

        self.updateStats();
    }

    fn updateStats(self: *Self) void {
        for (self.output_buffer.slice()) |*out_msg| {
            switch (out_msg.type) {
                .ack => self.stats.acks_generated += 1,
                .cancel_ack => self.stats.cancel_acks_generated += 1,
                .trade => self.stats.trades_generated += 1,
                .top_of_book => self.stats.tob_generated += 1,
            }
        }
    }

    pub fn continueFlush(self: *Self) bool {
        if (!self.flush_in_progress) return true;

        self.output_buffer.reset();
        const complete = self.engine.continueFlush(&self.output_buffer);

        if (complete) {
            self.flush_in_progress = false;
        }

        self.updateStats();
        return complete;
    }

    pub fn drainOutputToQueue(self: *Self, output_queue: *OutputEnvelopeQueue) u32 {
        var drained: u32 = 0;

        for (self.output_buffer.slice()) |*out_msg| {
            const target_client = self.getTargetClientId(out_msg);

            const envelope = OutputEnvelope{
                .message = out_msg.*,
                .client_id = target_client,
                .sequence = self.sequence,
            };

            if (output_queue.push(envelope)) {
                self.sequence += 1;
                drained += 1;
            } else {
                self.stats.output_queue_full += 1;
                break;
            }
        }

        return drained;
    }

    fn getTargetClientId(self: *Self, out_msg: *const msg.OutputMsg) u32 {
        return switch (out_msg.type) {
            .ack, .cancel_ack => self.current_client_id,
            .trade, .top_of_book => 0,
        };
    }

    pub fn processBatch(
        self: *Self,
        input_queue: *InputEnvelopeQueue,
        output_queue: *OutputEnvelopeQueue,
    ) u32 {
        var processed: u32 = 0;

        if (self.flush_in_progress) {
            _ = self.continueFlush();
            _ = self.drainOutputToQueue(output_queue);
        }

        while (processed < BATCH_SIZE) {
            const envelope = input_queue.pop() orelse break;

            self.processMessage(&envelope.message, envelope.client_id);
            _ = self.drainOutputToQueue(output_queue);

            processed += 1;

            if (self.flush_in_progress) {
                break;
            }
        }

        if (processed > 0) {
            self.stats.batches_processed += 1;
        } else {
            self.stats.empty_polls += 1;
        }

        return processed;
    }

    pub fn run(
        self: *Self,
        input_queue: *InputEnvelopeQueue,
        output_queue: *OutputEnvelopeQueue,
    ) void {
        self.state = .running;

        var iterations: u32 = 0;

        while (self.state == .running and iterations < MAX_LOOP_ITERATIONS) {
            const processed = self.processBatch(input_queue, output_queue);

            if (processed == 0) {
                var spin: u32 = 0;
                while (spin < SPIN_COUNT and input_queue.isEmpty()) : (spin += 1) {
                    std.atomic.spinLoopHint();
                }

                if (input_queue.isEmpty()) {
                    std.Thread.sleep(100_000);
                }
            }

            iterations += 1;
        }

        self.state = .stopped;
    }

    pub fn stop(self: *Self) void {
        self.state = .stopping;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.state == .running;
    }

    pub fn getStats(self: *const Self) ProcessorStats {
        return self.stats;
    }

    pub fn resetStats(self: *Self) void {
        self.stats = ProcessorStats.init();
    }

    pub fn getEngine(self: *Self) *MatchingEngine {
        return &self.engine;
    }

    pub fn cancelClientOrders(self: *Self, client_id: u32) void {
        self.output_buffer.reset();
        self.engine.cancelClientOrders(client_id, &self.output_buffer);
    }

    pub fn generateTopOfBook(self: *Self, symbol: []const u8) void {
        self.output_buffer.reset();
        self.engine.generateTopOfBook(symbol, &self.output_buffer);
    }

    pub fn generateAllTopOfBook(self: *Self) void {
        self.output_buffer.reset();
        self.engine.generateAllTopOfBook(&self.output_buffer);
    }
};

// ============================================================================
// Processor Thread Wrapper
// ============================================================================

pub const ProcessorThread = struct {
    processor: Processor,
    input_queue: *InputEnvelopeQueue,
    output_queue: *OutputEnvelopeQueue,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    const Self = @This();

    /// Initialize in-place to avoid stack overflow from large Processor struct
    pub fn initInPlace(self: *Self, input_queue: *InputEnvelopeQueue, output_queue: *OutputEnvelopeQueue) void {
        self.processor.initInPlace();
        self.input_queue = input_queue;
        self.output_queue = output_queue;
        self.thread = null;
        self.running = std.atomic.Value(bool).init(false);
    }

    /// Legacy init - WARNING: may cause stack overflow due to large Processor
    pub fn init(input_queue: *InputEnvelopeQueue, output_queue: *OutputEnvelopeQueue) Self {
        var self: Self = undefined;
        self.initInPlace(input_queue, output_queue);
        return self;
    }

    pub fn start(self: *Self) !void {
        std.debug.assert(self.thread == null);

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runThread, .{self});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running.load(.acquire);
    }

    pub fn getStats(self: *const Self) ProcessorStats {
        return self.processor.stats;
    }

    fn runThread(self: *Self) void {
        self.processor.state = .running;

        while (self.running.load(.acquire)) {
            const processed = self.processor.processBatch(self.input_queue, self.output_queue);

            if (processed == 0) {
                var spin: u32 = 0;
                while (spin < SPIN_COUNT and self.input_queue.isEmpty()) : (spin += 1) {
                    std.atomic.spinLoopHint();
                }

                if (self.input_queue.isEmpty()) {
                    std.Thread.sleep(100_000);
                }
            }
        }

        self.processor.state = .stopped;
    }
};

// ============================================================================
// Sync Processor (for testing - uses heap allocation internally)
// ============================================================================

pub const SyncProcessor = struct {
    processor: Processor,

    const Self = @This();

    pub fn init() Self {
        var self: Self = undefined;
        self.processor.initInPlace();
        return self;
    }

    pub fn processNewOrder(self: *Self, order: *const msg.NewOrderMsg, client_id: u32) []const msg.OutputMsg {
        var input: msg.InputMsg = undefined;
        input.type = .new_order;
        input.data.new_order = order.*;

        self.processor.processMessage(&input, client_id);
        return self.processor.output_buffer.slice();
    }

    pub fn processCancelOrder(self: *Self, cancel: *const msg.CancelMsg) []const msg.OutputMsg {
        var input: msg.InputMsg = undefined;
        input.type = .cancel;
        input.data.cancel = cancel.*;

        self.processor.processMessage(&input, 0);
        return self.processor.output_buffer.slice();
    }

    pub fn processFlush(self: *Self) []const msg.OutputMsg {
        var input: msg.InputMsg = undefined;
        input.type = .flush;

        self.processor.processMessage(&input, 0);

        while (self.processor.flush_in_progress) {
            _ = self.processor.continueFlush();
        }

        return self.processor.output_buffer.slice();
    }

    pub fn getStats(self: *const Self) ProcessorStats {
        return self.processor.stats;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "processor stats init" {
    const stats = ProcessorStats.init();
    try std.testing.expectEqual(@as(u64, 0), stats.messages_processed);
    try std.testing.expectEqual(@as(u64, 0), stats.trades_generated);
}
