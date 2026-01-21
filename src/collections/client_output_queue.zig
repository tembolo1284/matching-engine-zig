//! Client Output Queue - Per-client output routing queue
//!
//! This module defines the queue types used for routing output messages
//! from processors to individual TCP/UDP clients.
//!
//! Matches C's output_msg_envelope_t and the per-client queue concept
//! from client_registry.h / output_router.h
//!
//! Architecture:
//! ```
//!   Processor Thread(s)              Output Router Thread
//!        │                                  │
//!        ▼                                  ▼
//!   ┌──────────────────┐            ┌──────────────────┐
//!   │ ProcessorOutput  │            │ ClientOutputQueue│
//!   │ Queue (SPSC)     │ ──────────►│ (per-client)     │
//!   └──────────────────┘            └──────────────────┘
//!                                          │
//!                                          ▼
//!                                   ┌──────────────────┐
//!                                   │ TcpClient send   │
//!                                   └──────────────────┘
//! ```
//!
//! Power of Ten Compliance:
//! - Rule 2: Queue size is bounded (QUEUE_CAPACITY)
//! - Rule 3: No dynamic allocation in queue operations
//! - Rule 5: Assertions validate invariants
//! - Rule 7: All operations return success/failure status

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const config = @import("../transport/config.zig");

// ============================================================================
// Configuration
// ============================================================================

/// Queue capacity - must be power of 2 for efficient modulo
/// Matches C's approach with ring buffer
pub const QUEUE_CAPACITY: usize = 8192;
const QUEUE_MASK: usize = QUEUE_CAPACITY - 1;

// Compile-time validation
comptime {
    std.debug.assert(QUEUE_CAPACITY > 0);
    std.debug.assert((QUEUE_CAPACITY & (QUEUE_CAPACITY - 1)) == 0); // Power of 2
    std.debug.assert(QUEUE_CAPACITY >= 16);
    std.debug.assert(QUEUE_CAPACITY <= 1048576); // Max 1M entries
}

// ============================================================================
// ClientOutput - Output envelope matching C's output_msg_envelope_t
// ============================================================================

/// Output message envelope - wraps OutputMsg with routing info
/// Matches C's output_msg_envelope_t (64 bytes, cache-aligned concept)
///
/// Layout:
///   - message: OutputMsg (the actual ack/trade/TOB)
///   - client_id: Target client (0 = broadcast)
///   - sequence: Message sequence number
pub const ClientOutput = struct {
    message: msg.OutputMsg,
    client_id: config.ClientId = 0,
    sequence: u64 = 0,

    pub fn init(out_msg: msg.OutputMsg, client_id: config.ClientId, seq: u64) ClientOutput {
        return .{
            .message = out_msg,
            .client_id = client_id,
            .sequence = seq,
        };
    }

    /// Check if this is a broadcast message
    pub fn isBroadcast(self: *const ClientOutput) bool {
        return self.client_id == 0;
    }

    /// Check if this message is for a specific client
    pub fn isForClient(self: *const ClientOutput, target_id: config.ClientId) bool {
        return self.client_id == target_id or self.client_id == 0;
    }
};

// ============================================================================
// ClientOutputQueue - SPSC queue for per-client output routing
// ============================================================================

/// Single-producer single-consumer lock-free queue for client outputs
///
/// Design matches C's lockfree_queue.h:
/// - Fixed-size ring buffer (power of 2 for efficient modulo)
/// - Lock-free using atomic operations
/// - Cache-line considerations for head/tail separation
///
/// Producer: Output router thread
/// Consumer: TcpClient send thread (or output sender thread)
pub const ClientOutputQueue = struct {
    /// Ring buffer storage
    buffer: [QUEUE_CAPACITY]ClientOutput = undefined,

    /// Head index (consumer side) - where to read from
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Tail index (producer side) - where to write to
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Statistics (non-atomic, updated by owning thread only)
    stats: QueueStats = .{},

    const Self = @This();

    /// Queue statistics
    pub const QueueStats = struct {
        total_enqueues: u64 = 0,
        failed_enqueues: u64 = 0,
        total_dequeues: u64 = 0,
        peak_size: u64 = 0,
    };

    /// Initialize queue (explicit init for heap-allocated queues)
    pub fn init() Self {
        return .{
            .buffer = undefined,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .stats = .{},
        };
    }

    /// Reset queue to empty state
    pub fn reset(self: *Self) void {
        self.head.store(0, .release);
        self.tail.store(0, .release);
        self.stats = .{};
    }

    /// Enqueue an item (producer only)
    /// Returns true on success, false if queue is full
    pub fn push(self: *Self, item: ClientOutput) bool {
        const current_tail = self.tail.load(.monotonic);
        const next_tail = (current_tail + 1) & QUEUE_MASK;

        // Check if full - acquire to see consumer's progress
        const current_head = self.head.load(.acquire);
        if (next_tail == current_head) {
            self.stats.failed_enqueues += 1;
            return false;
        }

        // Store item
        self.buffer[current_tail] = item;

        // Publish tail - release so consumer sees the item
        self.tail.store(next_tail, .release);

        // Update stats
        self.stats.total_enqueues += 1;
        const current_size = (next_tail -% current_head) & QUEUE_MASK;
        if (current_size > self.stats.peak_size) {
            self.stats.peak_size = current_size;
        }

        return true;
    }

    /// Dequeue an item (consumer only)
    /// Returns the item or null if queue is empty
    pub fn pop(self: *Self) ?ClientOutput {
        const current_head = self.head.load(.monotonic);

        // Check if empty - acquire to see producer's writes
        const current_tail = self.tail.load(.acquire);
        if (current_head == current_tail) {
            return null;
        }

        // Load item
        const item = self.buffer[current_head];

        // Advance head - release so producer can reuse slot
        self.head.store((current_head + 1) & QUEUE_MASK, .release);

        self.stats.total_dequeues += 1;

        return item;
    }

    /// Batch dequeue - dequeue up to max_items in one operation
    /// Returns number of items actually dequeued
    pub fn popBatch(self: *Self, items: []ClientOutput) usize {
        if (items.len == 0) return 0;

        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);

        // Calculate available items
        const available = (tail -% head) & QUEUE_MASK;
        const to_dequeue = @min(available, items.len);

        if (to_dequeue == 0) return 0;

        // Copy items
        for (0..to_dequeue) |i| {
            items[i] = self.buffer[(head + i) & QUEUE_MASK];
        }

        // Single atomic store for entire batch
        self.head.store((head + to_dequeue) & QUEUE_MASK, .release);

        self.stats.total_dequeues += to_dequeue;

        return to_dequeue;
    }

    /// Check if queue is empty
    /// NOTE: Result may be stale due to concurrency
    pub fn isEmpty(self: *const Self) bool {
        return self.head.load(.acquire) == self.tail.load(.acquire);
    }

    /// Get approximate queue size
    /// NOTE: Result may be stale due to concurrency
    pub fn size(self: *const Self) usize {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return (tail -% head) & QUEUE_MASK;
    }

    /// Get queue capacity (always QUEUE_CAPACITY - 1)
    pub fn capacity(self: *const Self) usize {
        _ = self;
        return QUEUE_CAPACITY - 1; // One slot reserved for full detection
    }

    /// Get statistics snapshot
    pub fn getStats(self: *const Self) QueueStats {
        return self.stats;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ClientOutputQueue - basic operations" {
    var queue = ClientOutputQueue.init();

    // Initially empty
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.size());

    // Push an item
    const out_msg = msg.OutputMsg{
        .msg_type = .ack,
        .client_id = 1,
        .symbol = [_]u8{0} ** 16,
        .data = .{ .ack = .{ .user_id = 100, .user_order_id = 1 } },
    };
    const item = ClientOutput.init(out_msg, 1, 1);

    try std.testing.expect(queue.push(item));
    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), queue.size());

    // Pop the item
    const popped = queue.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(u64, 1), popped.?.sequence);
    try std.testing.expect(queue.isEmpty());
}

test "ClientOutputQueue - batch operations" {
    var queue = ClientOutputQueue.init();

    // Push multiple items
    for (0..10) |i| {
        const out_msg = msg.OutputMsg{
            .msg_type = .ack,
            .client_id = 1,
            .symbol = [_]u8{0} ** 16,
            .data = .{ .ack = .{ .user_id = 100, .user_order_id = @intCast(i) } },
        };
        try std.testing.expect(queue.push(ClientOutput.init(out_msg, 1, i)));
    }

    try std.testing.expectEqual(@as(usize, 10), queue.size());

    // Batch pop
    var batch: [5]ClientOutput = undefined;
    const count = queue.popBatch(&batch);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqual(@as(usize, 5), queue.size());

    // Verify sequence numbers
    for (0..5) |i| {
        try std.testing.expectEqual(i, batch[i].sequence);
    }
}

test "ClientOutput - helper functions" {
    const out_msg = msg.OutputMsg{
        .msg_type = .trade,
        .client_id = 0, // broadcast
        .symbol = [_]u8{0} ** 16,
        .data = .{ .trade = std.mem.zeroes(msg.TradeData) },
    };

    const broadcast = ClientOutput.init(out_msg, 0, 1);
    try std.testing.expect(broadcast.isBroadcast());
    try std.testing.expect(broadcast.isForClient(42));

    var unicast_msg = out_msg;
    unicast_msg.client_id = 42;
    const unicast = ClientOutput.init(unicast_msg, 42, 2);
    try std.testing.expect(!unicast.isBroadcast());
    try std.testing.expect(unicast.isForClient(42));
    try std.testing.expect(!unicast.isForClient(99));
}
