//! Lock-Free SPSC Queue - Single Producer Single Consumer
//!
//! Design principles (Power of Ten + cache optimization):
//! - Cache-line aligned head/tail to prevent false sharing
//! - Power-of-2 capacity for fast masking
//! - No dynamic allocation (Rule 3)
//! - Bounded operations (Rule 2)
//! - Atomic operations for thread safety

const std = @import("std");

pub const DEFAULT_CAPACITY: u32 = 8192;
const CACHE_LINE_SIZE: usize = 64;

/// Cache-line aligned atomic counter
const AlignedAtomicU64 = struct {
    value: std.atomic.Value(u64) align(CACHE_LINE_SIZE),
    _pad: [CACHE_LINE_SIZE - @sizeOf(std.atomic.Value(u64))]u8 = undefined,

    comptime {
        std.debug.assert(@sizeOf(AlignedAtomicU64) == CACHE_LINE_SIZE);
        std.debug.assert(@alignOf(AlignedAtomicU64) == CACHE_LINE_SIZE);
    }

    pub fn init(val: u64) AlignedAtomicU64 {
        return AlignedAtomicU64{
            .value = std.atomic.Value(u64).init(val),
            ._pad = undefined,
        };
    }

    pub fn load(self: *const AlignedAtomicU64, comptime ordering: std.builtin.AtomicOrder) u64 {
        return self.value.load(ordering);
    }

    pub fn store(self: *AlignedAtomicU64, val: u64, comptime ordering: std.builtin.AtomicOrder) void {
        self.value.store(val, ordering);
    }
};

/// Lock-free single-producer single-consumer queue
pub fn SpscQueue(comptime T: type, comptime capacity: u32) type {
    comptime {
        std.debug.assert(capacity > 0);
        std.debug.assert((capacity & (capacity - 1)) == 0);
    }

    const mask: u64 = capacity - 1;

    return struct {
        head: AlignedAtomicU64 align(CACHE_LINE_SIZE),
        tail: AlignedAtomicU64 align(CACHE_LINE_SIZE),
        cached_head: u64 align(CACHE_LINE_SIZE),
        cached_tail: u64,
        data: [capacity]T align(CACHE_LINE_SIZE),

        const Self = @This();

        comptime {
            std.debug.assert(@offsetOf(Self, "tail") >= CACHE_LINE_SIZE);
        }

        pub fn init() Self {
            return Self{
                .head = AlignedAtomicU64.init(0),
                .tail = AlignedAtomicU64.init(0),
                .cached_head = 0,
                .cached_tail = 0,
                .data = undefined,
            };
        }

        pub fn push(self: *Self, item: T) bool {
            const head = self.head.load(.monotonic);
            const next_head = head + 1;

            if (next_head - self.cached_tail > capacity) {
                self.cached_tail = self.tail.load(.acquire);

                if (next_head - self.cached_tail > capacity) {
                    return false;
                }
            }

            self.data[head & mask] = item;
            self.head.store(next_head, .release);

            return true;
        }

        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);

            if (tail >= self.cached_head) {
                self.cached_head = self.head.load(.acquire);

                if (tail >= self.cached_head) {
                    return null;
                }
            }

            const item = self.data[tail & mask];
            self.tail.store(tail + 1, .release);

            return item;
        }

        pub fn peek(self: *Self) ?*const T {
            const tail = self.tail.load(.monotonic);

            if (tail >= self.cached_head) {
                self.cached_head = self.head.load(.acquire);

                if (tail >= self.cached_head) {
                    return null;
                }
            }

            return &self.data[tail & mask];
        }

        pub fn isEmpty(self: *Self) bool {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return head == tail;
        }

        pub fn isFull(self: *Self) bool {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return (head - tail) >= capacity;
        }

        pub fn size(self: *Self) u64 {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return head - tail;
        }

        pub fn getCapacity(self: *const Self) u32 {
            _ = self;
            return capacity;
        }

        pub fn pushBatch(self: *Self, items: []const T) usize {
            const head = self.head.load(.monotonic);

            if (head - self.cached_tail >= capacity) {
                self.cached_tail = self.tail.load(.acquire);
            }

            const available = capacity - (head - self.cached_tail);
            const to_push = @min(items.len, available);

            if (to_push == 0) return 0;

            var i: usize = 0;
            while (i < to_push) : (i += 1) {
                self.data[(head + i) & mask] = items[i];
            }

            self.head.store(head + to_push, .release);

            return to_push;
        }

        pub fn popBatch(self: *Self, buffer: []T) usize {
            const tail = self.tail.load(.monotonic);

            if (tail >= self.cached_head) {
                self.cached_head = self.head.load(.acquire);
            }

            const available = self.cached_head - tail;
            const to_pop = @min(buffer.len, available);

            if (to_pop == 0) return 0;

            var i: usize = 0;
            while (i < to_pop) : (i += 1) {
                buffer[i] = self.data[(tail + i) & mask];
            }

            self.tail.store(tail + to_pop, .release);

            return to_pop;
        }

        pub fn reset(self: *Self) void {
            self.head.store(0, .seq_cst);
            self.tail.store(0, .seq_cst);
            self.cached_head = 0;
            self.cached_tail = 0;
        }

        pub const Stats = struct {
            head: u64,
            tail: u64,
            queue_size: u64,
            capacity: u32,
        };

        pub fn getStats(self: *Self) Stats {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            return Stats{
                .head = h,
                .tail = t,
                .queue_size = h - t,
                .capacity = capacity,
            };
        }
    };
}

// ============================================================================
// Type Aliases
// ============================================================================

const msg = @import("../protocol/message_types.zig");

pub const InputQueue = SpscQueue(msg.InputMsg, DEFAULT_CAPACITY);
pub const OutputQueue = SpscQueue(msg.OutputMsg, DEFAULT_CAPACITY);

pub const InputEnvelope = extern struct {
    message: msg.InputMsg,
    client_id: u32,
    _pad: [20]u8,

    comptime {
        std.debug.assert(@sizeOf(InputEnvelope) == 64);
    }
};

pub const OutputEnvelope = extern struct {
    message: msg.OutputMsg,
    client_id: u32,
    sequence: u64,

    comptime {
        std.debug.assert(@sizeOf(OutputEnvelope) == 64);
    }
};

pub const InputEnvelopeQueue = SpscQueue(InputEnvelope, DEFAULT_CAPACITY);
pub const OutputEnvelopeQueue = SpscQueue(OutputEnvelope, DEFAULT_CAPACITY);

// ============================================================================
// Tests
// ============================================================================

test "spsc queue basic operations" {
    var queue = SpscQueue(u32, 16).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), queue.size());

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    try std.testing.expectEqual(@as(u64, 3), queue.size());
    try std.testing.expect(!queue.isEmpty());

    try std.testing.expectEqual(@as(u32, 1), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 2), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 3), queue.pop().?);

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "spsc queue full" {
    var queue = SpscQueue(u32, 4).init();

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));
    try std.testing.expect(queue.push(4));

    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.push(5));

    _ = queue.pop();
    try std.testing.expect(queue.push(5));
}

test "spsc queue wrap around" {
    var queue = SpscQueue(u32, 4).init();

    for (0..10) |i| {
        try std.testing.expect(queue.push(@intCast(i)));
        try std.testing.expectEqual(@as(u32, @intCast(i)), queue.pop().?);
    }
}

test "spsc queue peek" {
    var queue = SpscQueue(u32, 16).init();

    try std.testing.expectEqual(@as(?*const u32, null), queue.peek());

    _ = queue.push(42);

    const peeked = queue.peek();
    try std.testing.expect(peeked != null);
    try std.testing.expectEqual(@as(u32, 42), peeked.?.*);

    try std.testing.expectEqual(@as(u64, 1), queue.size());
    try std.testing.expectEqual(@as(u32, 42), queue.pop().?);
}

test "spsc queue batch push" {
    var queue = SpscQueue(u32, 16).init();

    const items = [_]u32{ 1, 2, 3, 4, 5 };
    const pushed = queue.pushBatch(&items);

    try std.testing.expectEqual(@as(usize, 5), pushed);
    try std.testing.expectEqual(@as(u64, 5), queue.size());

    try std.testing.expectEqual(@as(u32, 1), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 2), queue.pop().?);
}

test "spsc queue batch pop" {
    var queue = SpscQueue(u32, 16).init();

    for (0..5) |i| {
        _ = queue.push(@intCast(i));
    }

    var buffer: [10]u32 = undefined;
    const popped = queue.popBatch(&buffer);

    try std.testing.expectEqual(@as(usize, 5), popped);
    try std.testing.expectEqual(@as(u32, 0), buffer[0]);
    try std.testing.expectEqual(@as(u32, 4), buffer[4]);
    try std.testing.expect(queue.isEmpty());
}

test "spsc queue batch push partial" {
    var queue = SpscQueue(u32, 4).init();

    const items = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const pushed = queue.pushBatch(&items);

    try std.testing.expectEqual(@as(usize, 4), pushed);
    try std.testing.expect(queue.isFull());
}

test "spsc queue reset" {
    var queue = SpscQueue(u32, 16).init();

    _ = queue.push(1);
    _ = queue.push(2);
    try std.testing.expectEqual(@as(u64, 2), queue.size());

    queue.reset();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), queue.size());
}

test "spsc queue stats" {
    var queue = SpscQueue(u32, 16).init();

    _ = queue.push(1);
    _ = queue.push(2);
    _ = queue.pop();

    const stats = queue.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.head);
    try std.testing.expectEqual(@as(u64, 1), stats.tail);
    try std.testing.expectEqual(@as(u64, 1), stats.queue_size);
    try std.testing.expectEqual(@as(u32, 16), stats.capacity);
}

test "aligned atomic size" {
    try std.testing.expectEqual(@as(usize, CACHE_LINE_SIZE), @sizeOf(AlignedAtomicU64));
    try std.testing.expectEqual(@as(usize, CACHE_LINE_SIZE), @alignOf(AlignedAtomicU64));
}

test "input envelope size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(InputEnvelope));
}

test "output envelope size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(OutputEnvelope));
}

test "message queue types compile" {
    var input_queue = InputQueue.init();
    var output_queue = OutputQueue.init();

    try std.testing.expect(input_queue.isEmpty());
    try std.testing.expect(output_queue.isEmpty());
}
