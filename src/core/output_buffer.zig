//! Bounded output buffer for messages generated during order processing.
//!
//! Design principles:
//! - Fixed capacity, no dynamic allocation (NASA Rule 3)
//! - Critical messages use addChecked() which panics on overflow
//! - Overflow tracking for monitoring
//!
//! Usage:
//! - Trades, Acks, Rejects: Use addChecked() — these MUST NOT be lost
//! - Informational messages: Use add() if dropping is acceptable
//!
//! Sizing:
//! - Default capacity: 8,192 messages
//! - Worst case: 100K orders × 2 messages each (ack + trade) + TOB updates
//! - If you hit overflow, increase MAX_OUTPUT_MESSAGES or batch processing

const std = @import("std");
const msg = @import("../protocol/message_types.zig");

// ============================================================================
// Configuration
// ============================================================================

/// Output buffer capacity. Sized for worst case: 100K orders generating
/// 2 messages each (ack + trade) plus TOB updates.
pub const MAX_OUTPUT_MESSAGES: u32 = 8_192;

// ============================================================================
// Output Buffer
// ============================================================================

/// Buffer for outgoing messages generated during order processing.
///
/// CRITICAL: This buffer MUST NOT overflow for trade messages.
/// Use addChecked() for critical messages - it panics on overflow.
/// Use add() only for messages that can be safely dropped (none currently).
pub const OutputBuffer = struct {
    /// Message storage.
    messages: [MAX_OUTPUT_MESSAGES]msg.OutputMsg,

    /// Current number of messages in buffer.
    count: u32,

    /// Total overflow attempts (messages that couldn't be added).
    overflow_count: u64,

    /// Peak count seen (high water mark).
    peak_count: u32,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Create a new empty buffer.
    pub fn init() Self {
        return .{
            .messages = undefined,
            .count = 0,
            .overflow_count = 0,
            .peak_count = 0,
        };
    }

    // ========================================================================
    // Capacity Queries
    // ========================================================================

    /// Check if buffer has space for N more messages.
    pub fn hasSpace(self: *const Self, needed: u32) bool {
        return (self.count + needed) <= MAX_OUTPUT_MESSAGES;
    }

    /// Get remaining capacity.
    pub fn remaining(self: *const Self) u32 {
        return MAX_OUTPUT_MESSAGES - self.count;
    }

    /// Check if buffer is empty.
    pub fn isEmpty(self: *const Self) bool {
        return self.count == 0;
    }

    /// Check if buffer is full.
    pub fn isFull(self: *const Self) bool {
        return self.count >= MAX_OUTPUT_MESSAGES;
    }

    // ========================================================================
    // Adding Messages
    // ========================================================================

    /// Add message, returning false if buffer is full.
    ///
    /// WARNING: Use addChecked() for critical messages that must not be lost
    /// (trades, acks, rejects). This method is for optional/droppable messages.
    pub fn add(self: *Self, message: msg.OutputMsg) bool {
        if (self.count >= MAX_OUTPUT_MESSAGES) {
            self.overflow_count += 1;
            return false;
        }

        self.messages[self.count] = message;
        self.count += 1;
        self.peak_count = @max(self.peak_count, self.count);

        return true;
    }

    /// Add message, panicking if buffer is full.
    ///
    /// Use for critical messages (trades, acks, rejects) that MUST NOT be lost.
    /// A panic here indicates a serious sizing problem that must be fixed.
    pub fn addChecked(self: *Self, message: msg.OutputMsg) void {
        if (self.count >= MAX_OUTPUT_MESSAGES) {
            std.debug.panic(
                "OutputBuffer overflow: {d}/{d} messages, dropping critical message type={c}",
                .{ self.count, MAX_OUTPUT_MESSAGES, @intFromEnum(message.msg_type) },
            );
        }

        self.messages[self.count] = message;
        self.count += 1;
        self.peak_count = @max(self.peak_count, self.count);
    }

    /// Add multiple messages at once.
    /// Returns number of messages actually added (may be less than requested if buffer fills).
    pub fn addBatch(self: *Self, messages_to_add: []const msg.OutputMsg) u32 {
        var added: u32 = 0;
        for (messages_to_add) |message| {
            if (!self.add(message)) break;
            added += 1;
        }
        return added;
    }

    // ========================================================================
    // Accessing Messages
    // ========================================================================

    /// Get slice of all messages in buffer.
    pub fn slice(self: *const Self) []const msg.OutputMsg {
        return self.messages[0..self.count];
    }

    /// Get a specific message by index.
    /// Returns null if index is out of bounds.
    pub fn get(self: *const Self, index: u32) ?*const msg.OutputMsg {
        if (index >= self.count) return null;
        return &self.messages[index];
    }

    // ========================================================================
    // Buffer Management
    // ========================================================================

    /// Clear all messages from buffer.
    /// Does NOT reset overflow_count or peak_count (lifetime stats).
    pub fn clear(self: *Self) void {
        self.count = 0;
    }

    /// Reset buffer including statistics.
    pub fn reset(self: *Self) void {
        self.count = 0;
        self.overflow_count = 0;
        self.peak_count = 0;
    }

    // ========================================================================
    // Overflow Detection
    // ========================================================================

    /// Check if any overflow has occurred since creation/reset.
    pub fn hasOverflowed(self: *const Self) bool {
        return self.overflow_count > 0;
    }

    /// Get utilization as percentage (0-100).
    pub fn getUtilization(self: *const Self) u32 {
        return (self.count * 100) / MAX_OUTPUT_MESSAGES;
    }

    /// Get peak utilization as percentage (0-100).
    pub fn getPeakUtilization(self: *const Self) u32 {
        return (self.peak_count * 100) / MAX_OUTPUT_MESSAGES;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OutputBuffer basic operations" {
    var buf = OutputBuffer.init();

    try std.testing.expect(buf.isEmpty());
    try std.testing.expect(!buf.isFull());
    try std.testing.expectEqual(MAX_OUTPUT_MESSAGES, buf.remaining());

    const ack = msg.OutputMsg.makeAck(1, 100, msg.makeSymbol("IBM"), 42);
    try std.testing.expect(buf.add(ack));

    try std.testing.expect(!buf.isEmpty());
    try std.testing.expectEqual(@as(u32, 1), buf.count);
    try std.testing.expectEqual(MAX_OUTPUT_MESSAGES - 1, buf.remaining());

    buf.clear();
    try std.testing.expect(buf.isEmpty());
}

test "OutputBuffer overflow tracking" {
    var buf = OutputBuffer.init();

    // Fill the buffer
    var i: u32 = 0;
    while (i < MAX_OUTPUT_MESSAGES) : (i += 1) {
        try std.testing.expect(buf.add(std.mem.zeroes(msg.OutputMsg)));
    }

    try std.testing.expect(buf.isFull());
    try std.testing.expect(!buf.hasOverflowed());

    // Next add should fail
    try std.testing.expect(!buf.add(std.mem.zeroes(msg.OutputMsg)));
    try std.testing.expect(buf.hasOverflowed());
    try std.testing.expectEqual(@as(u64, 1), buf.overflow_count);

    // Multiple overflow attempts
    try std.testing.expect(!buf.add(std.mem.zeroes(msg.OutputMsg)));
    try std.testing.expect(!buf.add(std.mem.zeroes(msg.OutputMsg)));
    try std.testing.expectEqual(@as(u64, 3), buf.overflow_count);
}

test "OutputBuffer remaining capacity" {
    var buf = OutputBuffer.init();

    try std.testing.expectEqual(MAX_OUTPUT_MESSAGES, buf.remaining());

    _ = buf.add(std.mem.zeroes(msg.OutputMsg));
    _ = buf.add(std.mem.zeroes(msg.OutputMsg));

    try std.testing.expectEqual(MAX_OUTPUT_MESSAGES - 2, buf.remaining());
    try std.testing.expect(buf.hasSpace(MAX_OUTPUT_MESSAGES - 2));
    try std.testing.expect(!buf.hasSpace(MAX_OUTPUT_MESSAGES - 1));
}

test "OutputBuffer slice access" {
    var buf = OutputBuffer.init();

    const ack1 = msg.OutputMsg.makeAck(1, 100, msg.makeSymbol("IBM"), 42);
    const ack2 = msg.OutputMsg.makeAck(2, 200, msg.makeSymbol("AAPL"), 43);

    _ = buf.add(ack1);
    _ = buf.add(ack2);

    const messages = buf.slice();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(@as(u32, 1), messages[0].data.ack.user_id);
    try std.testing.expectEqual(@as(u32, 2), messages[1].data.ack.user_id);
}

test "OutputBuffer get by index" {
    var buf = OutputBuffer.init();

    const ack = msg.OutputMsg.makeAck(1, 100, msg.makeSymbol("IBM"), 42);
    _ = buf.add(ack);

    const msg0 = buf.get(0);
    try std.testing.expect(msg0 != null);
    try std.testing.expectEqual(@as(u32, 1), msg0.?.data.ack.user_id);

    const msg1 = buf.get(1);
    try std.testing.expect(msg1 == null);

    const msg_oob = buf.get(MAX_OUTPUT_MESSAGES);
    try std.testing.expect(msg_oob == null);
}

test "OutputBuffer peak tracking" {
    var buf = OutputBuffer.init();

    // Add 100 messages
    for (0..100) |_| {
        _ = buf.add(std.mem.zeroes(msg.OutputMsg));
    }

    try std.testing.expectEqual(@as(u32, 100), buf.peak_count);

    // Clear and add fewer
    buf.clear();
    for (0..50) |_| {
        _ = buf.add(std.mem.zeroes(msg.OutputMsg));
    }

    // Peak should remain at 100
    try std.testing.expectEqual(@as(u32, 100), buf.peak_count);
    try std.testing.expectEqual(@as(u32, 50), buf.count);
}

test "OutputBuffer utilization" {
    var buf = OutputBuffer.init();

    try std.testing.expectEqual(@as(u32, 0), buf.getUtilization());

    // Fill to ~50%
    const half = MAX_OUTPUT_MESSAGES / 2;
    for (0..half) |_| {
        _ = buf.add(std.mem.zeroes(msg.OutputMsg));
    }

    try std.testing.expectEqual(@as(u32, 50), buf.getUtilization());
}

test "OutputBuffer addBatch" {
    var buf = OutputBuffer.init();

    var batch: [5]msg.OutputMsg = undefined;
    for (&batch, 0..) |*m, i| {
        m.* = msg.OutputMsg.makeAck(@intCast(i), 100, msg.makeSymbol("IBM"), 42);
    }

    const added = buf.addBatch(&batch);
    try std.testing.expectEqual(@as(u32, 5), added);
    try std.testing.expectEqual(@as(u32, 5), buf.count);
}

test "OutputBuffer reset vs clear" {
    var buf = OutputBuffer.init();

    // Add some messages and cause overflow
    for (0..MAX_OUTPUT_MESSAGES) |_| {
        _ = buf.add(std.mem.zeroes(msg.OutputMsg));
    }
    _ = buf.add(std.mem.zeroes(msg.OutputMsg)); // overflow

    try std.testing.expect(buf.hasOverflowed());
    try std.testing.expect(buf.peak_count > 0);

    // Clear preserves stats
    buf.clear();
    try std.testing.expectEqual(@as(u32, 0), buf.count);
    try std.testing.expect(buf.hasOverflowed()); // Still true
    try std.testing.expect(buf.peak_count > 0); // Still set

    // Reset clears everything
    buf.reset();
    try std.testing.expectEqual(@as(u32, 0), buf.count);
    try std.testing.expect(!buf.hasOverflowed());
    try std.testing.expectEqual(@as(u32, 0), buf.peak_count);
}
