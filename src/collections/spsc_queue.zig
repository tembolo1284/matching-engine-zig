//! Lock-free Single Producer Single Consumer queue.
//! 
//! Cache-line aligned to prevent false sharing between producer and consumer.
//! Uses acquire/release memory ordering for correct synchronization.
//!
//! Performance characteristics:
//! - O(1) push and pop
//! - No locks, no syscalls
//! - Cache-friendly sequential access

const std = @import("std");

pub fn SpscQueue(comptime T: type, comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity > 0);
        std.debug.assert(capacity & (capacity - 1) == 0); // Must be power of 2
    }

    return struct {
        // Buffer holds the actual items
        buffer: [capacity]T align(64) = undefined,

        // Head: read position (modified by consumer only)
        // Aligned to separate cache line to prevent false sharing
        head: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        _pad_head: [64 - @sizeOf(std.atomic.Value(usize))]u8 = undefined,

        // Tail: write position (modified by producer only)
        // Aligned to separate cache line to prevent false sharing
        tail: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        _pad_tail: [64 - @sizeOf(std.atomic.Value(usize))]u8 = undefined,

        // Statistics (optional, for monitoring)
        push_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        pop_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        push_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        const Self = @This();
        const MASK = capacity - 1;

        pub fn init() Self {
            return .{};
        }

        /// Producer: attempt to push an item onto the queue.
        /// Returns true if successful, false if queue is full.
        /// Thread-safe for single producer.
        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.monotonic);
            const next_tail = (tail + 1) & MASK;

            // Check if full (next_tail would equal head)
            if (next_tail == self.head.load(.acquire)) {
                _ = self.push_failures.fetchAdd(1, .monotonic);
                return false;
            }

            // Write item to buffer
            self.buffer[tail] = item;

            // Publish the new tail (release ensures item write is visible)
            self.tail.store(next_tail, .release);

            _ = self.push_count.fetchAdd(1, .monotonic);
            return true;
        }

        /// Consumer: attempt to pop an item from the queue.
        /// Returns the item if available, null if queue is empty.
        /// Thread-safe for single consumer.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);

            // Check if empty (head equals tail)
            if (head == self.tail.load(.acquire)) {
                return null;
            }

            // Read item from buffer (acquire on tail ensures we see the written data)
            const item = self.buffer[head];

            // Advance head (release not strictly needed but good for consistency)
            self.head.store((head + 1) & MASK, .release);

            _ = self.pop_count.fetchAdd(1, .monotonic);
            return item;
        }

        /// Check if queue is empty (approximate, may race)
        pub fn isEmpty(self: *const Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }

        /// Check if queue is full (approximate, may race)
        pub fn isFull(self: *const Self) bool {
            const tail = self.tail.load(.acquire);
            const next_tail = (tail + 1) & MASK;
            return next_tail == self.head.load(.acquire);
        }

        /// Get approximate size (may race)
        pub fn size(self: *const Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return (tail -% head) & MASK;
        }

        /// Get capacity
        pub fn getCapacity(self: *const Self) usize {
            _ = self;
            return capacity - 1; // One slot always empty to distinguish full from empty
        }

        /// Get statistics
        pub fn getStats(self: *const Self) struct { pushed: u64, popped: u64, failures: u64 } {
            return .{
                .pushed = self.push_count.load(.monotonic),
                .popped = self.pop_count.load(.monotonic),
                .failures = self.push_failures.load(.monotonic),
            };
        }

        /// Reset statistics
        pub fn resetStats(self: *Self) void {
            self.push_count.store(0, .monotonic);
            self.pop_count.store(0, .monotonic);
            self.push_failures.store(0, .monotonic);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "spsc basic operations" {
    var queue = SpscQueue(u32, 16).init();

    // Push some items
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    // Pop them back
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());
    try std.testing.expectEqual(@as(?u32, 3), queue.pop());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "spsc full queue" {
    var queue = SpscQueue(u32, 4).init(); // Capacity 4 means 3 usable slots

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));
    try std.testing.expect(!queue.push(4)); // Should fail - full

    // Pop one and try again
    _ = queue.pop();
    try std.testing.expect(queue.push(4)); // Should succeed now
}

test "spsc empty queue" {
    var queue = SpscQueue(u32, 16).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());

    try std.testing.expect(queue.push(42));
    try std.testing.expect(!queue.isEmpty());

    _ = queue.pop();
    try std.testing.expect(queue.isEmpty());
}
