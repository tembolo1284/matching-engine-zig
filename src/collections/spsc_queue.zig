//! Lock-free Single Producer Single Consumer (SPSC) queue.
//!
//! A high-performance, cache-optimized queue for communication between
//! exactly one producer thread and one consumer thread.
//!
//! Design:
//! ```
//!   Producer Thread                    Consumer Thread
//!        │                                   │
//!        ▼                                   ▼
//!   ┌─────────┐                        ┌─────────┐
//!   │  tail   │ ◄── cache line ──►     │  head   │
//!   └────┬────┘                        └────┬────┘
//!        │                                   │
//!        ▼                                   ▼
//!   ┌─────────────────────────────────────────────┐
//!   │  buffer[0] │ buffer[1] │ ... │ buffer[N-1]  │
//!   └─────────────────────────────────────────────┘
//! ```
//!
//! Key properties:
//! - **Lock-free**: No mutexes, no syscalls
//! - **Wait-free**: Push/pop always complete in bounded time
//! - **Cache-friendly**: Head and tail on separate cache lines
//! - **Zero allocation**: Fixed-size buffer, no heap usage
//!
//! Memory ordering:
//! - Producer: Writes item, then `release` stores tail
//! - Consumer: `acquire` loads tail, then reads item
//! - This ensures consumer sees item write before consuming
//!
//! Capacity:
//! - Must be power of 2 (for fast modulo via bitmask)
//! - Usable capacity is `capacity - 1` (one slot reserved)
//! - Reserved slot distinguishes full from empty
//!
//! Thread safety:
//! - Safe for exactly ONE producer and ONE consumer
//! - Multiple producers or consumers will cause data races
//! - Use separate queues for multi-producer/multi-consumer
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: All loops bounded by capacity
//! - Rule 5: Assertions validate invariants
//! - Rule 9: Unsafe pointer access clearly marked

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Configuration
// ============================================================================

/// Cache line size for alignment.
/// 64 bytes is standard for x86_64, ARM64, and most modern CPUs.
pub const CACHE_LINE_SIZE: usize = 64;

/// Whether to track statistics (adds ~5-10ns overhead per operation).
/// Disabled in ReleaseFast for maximum performance.
pub const TRACK_STATS: bool = builtin.mode != .ReleaseFast;

/// Warning threshold for item size relative to cache line.
/// Items larger than this may cause cache thrashing.
const LARGE_ITEM_THRESHOLD: usize = CACHE_LINE_SIZE * 2;

// ============================================================================
// Statistics
// ============================================================================

/// Queue statistics for monitoring.
pub const QueueStats = struct {
    /// Total successful pushes.
    pushed: u64,
    /// Total successful pops.
    popped: u64,
    /// Push attempts that failed (queue full).
    /// Note: pushBatch increments by 1 per failed batch, not per item.
    push_failures: u64,
    /// Pop attempts that failed (queue empty).
    /// Note: popBatch increments by 1 per failed batch, not per item.
    pop_failures: u64,
    /// High water mark (max observed size).
    high_water_mark: u64,

    pub fn init() QueueStats {
        return .{
            .pushed = 0,
            .popped = 0,
            .push_failures = 0,
            .pop_failures = 0,
            .high_water_mark = 0,
        };
    }
};

// ============================================================================
// SPSC Queue
// ============================================================================

/// Lock-free Single Producer Single Consumer queue.
///
/// Parameters:
/// - `T`: Element type (should be small, ideally ≤ cache line)
/// - `capacity`: Queue size, must be power of 2
///
/// Example:
/// ```zig
/// var queue = SpscQueue(Message, 1024).init();
///
/// // Producer thread
/// if (!queue.push(msg)) {
///     // Handle backpressure
/// }
///
/// // Consumer thread
/// if (queue.pop()) |msg| {
///     process(msg);
/// }
/// ```
pub fn SpscQueue(comptime T: type, comptime capacity: usize) type {
    // Compile-time validation
    comptime {
        if (capacity == 0) {
            @compileError("SpscQueue capacity must be > 0");
        }
        if (capacity & (capacity - 1) != 0) {
            @compileError("SpscQueue capacity must be power of 2");
        }
        if (capacity > 1 << 30) {
            @compileError("SpscQueue capacity too large (max 2^30)");
        }
        // Warn about large items (compile-time note via assert message)
        if (@sizeOf(T) > LARGE_ITEM_THRESHOLD) {
            @compileLog("SpscQueue: Item size exceeds 2 cache lines, consider using pointers");
        }
    }

    return struct {
        /// Ring buffer for items.
        /// Aligned to cache line for optimal memory access.
        buffer: [capacity]T align(CACHE_LINE_SIZE) = undefined,

        /// Read position (consumer only).
        /// Isolated on its own cache line to prevent false sharing.
        head: CacheLineAtomic = CacheLineAtomic.init(0),

        /// Write position (producer only).
        /// Isolated on its own cache line to prevent false sharing.
        tail: CacheLineAtomic = CacheLineAtomic.init(0),

        /// Statistics (conditional compilation).
        stats: if (TRACK_STATS) StatsBlock else void = if (TRACK_STATS) StatsBlock.init() else {},

        const Self = @This();

        /// Bitmask for fast modulo (capacity - 1).
        const MASK: usize = capacity - 1;

        /// Usable capacity (one slot reserved).
        pub const USABLE_CAPACITY: usize = capacity - 1;

        /// Cache-line-aligned atomic counter.
        const CacheLineAtomic = struct {
            value: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
            /// Padding to fill cache line.
            _padding: [CACHE_LINE_SIZE - @sizeOf(std.atomic.Value(usize))]u8 = undefined,

            comptime {
                std.debug.assert(@sizeOf(CacheLineAtomic) == CACHE_LINE_SIZE);
            }

            fn init(val: usize) CacheLineAtomic {
                return .{ .value = std.atomic.Value(usize).init(val) };
            }
        };

        /// Statistics block with cache-line separation to prevent false sharing.
        ///
        /// Producer and consumer stats are on separate cache lines since they're
        /// written by different threads.
        const StatsBlock = struct {
            // === Producer stats (cache line 1) ===
            pushed: std.atomic.Value(u64) align(CACHE_LINE_SIZE),
            push_failures: std.atomic.Value(u64),
            high_water_mark: std.atomic.Value(u64),
            _pad_producer: [CACHE_LINE_SIZE - 24]u8 = undefined,

            // === Consumer stats (cache line 2) ===
            popped: std.atomic.Value(u64) align(CACHE_LINE_SIZE),
            pop_failures: std.atomic.Value(u64),
            _pad_consumer: [CACHE_LINE_SIZE - 16]u8 = undefined,

            comptime {
                // Verify cache line alignment
                std.debug.assert(@offsetOf(StatsBlock, "popped") == CACHE_LINE_SIZE);
            }

            fn init() StatsBlock {
                return .{
                    .pushed = std.atomic.Value(u64).init(0),
                    .push_failures = std.atomic.Value(u64).init(0),
                    .high_water_mark = std.atomic.Value(u64).init(0),
                    .popped = std.atomic.Value(u64).init(0),
                    .pop_failures = std.atomic.Value(u64).init(0),
                };
            }
        };

        // ====================================================================
        // Lifecycle
        // ====================================================================

        /// Initialize an empty queue.
        pub fn init() Self {
            return .{};
        }

        /// Reset queue to empty state.
        /// NOT thread-safe - call only when no other threads are accessing.
        pub fn reset(self: *Self) void {
            self.head.value.store(0, .monotonic);
            self.tail.value.store(0, .monotonic);
            if (TRACK_STATS) {
                self.resetStats();
            }
        }

        // ====================================================================
        // Producer Operations
        // ====================================================================

        /// Push an item onto the queue.
        ///
        /// Returns:
        /// - `true` if item was enqueued
        /// - `false` if queue is full (backpressure)
        ///
        /// Thread safety: Call from producer thread only.
        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.value.load(.monotonic);
            const next_tail = (tail +% 1) & MASK;

            // P10 Rule 5: Verify index is in bounds
            std.debug.assert(tail < capacity);
            std.debug.assert(next_tail < capacity);

            // Check if full: next_tail would collide with head
            // Acquire ensures we see consumer's latest head update
            const head = self.head.value.load(.acquire);
            if (next_tail == head) {
                if (TRACK_STATS) {
                    _ = self.stats.push_failures.fetchAdd(1, .monotonic);
                }
                return false;
            }

            // Write item to buffer
            self.buffer[tail] = item;

            // Publish new tail
            // Release ensures item write is visible before tail update
            self.tail.value.store(next_tail, .release);

            if (TRACK_STATS) {
                _ = self.stats.pushed.fetchAdd(1, .monotonic);
                self.updateHighWaterMark();
            }

            return true;
        }

        /// Try to push, with prefetch hint for next slot.
        /// Use when pushing in a tight loop for better cache behavior.
        pub fn pushWithPrefetch(self: *Self, item: T) bool {
            const result = self.push(item);
            if (result) {
                // Prefetch next write location
                const tail = self.tail.value.load(.monotonic);
                const next = (tail +% 1) & MASK;
                std.debug.assert(next < capacity);
                @prefetch(&self.buffer[next], .{ .locality = 3, .cache = .data });
            }
            return result;
        }

        /// Batch push multiple items.
        /// Returns number of items successfully pushed.
        ///
        /// More efficient than individual pushes when sending bursts.
        ///
        /// Statistics note: If the batch partially fits, only successfully pushed
        /// items are counted in `pushed`. If zero items fit, `push_failures` is
        /// incremented by 1 (not by `items.len`).
        pub fn pushBatch(self: *Self, items: []const T) usize {
            // P10 Rule 5: Validate input
            std.debug.assert(items.len <= USABLE_CAPACITY);

            const tail = self.tail.value.load(.monotonic);
            const head = self.head.value.load(.acquire);

            // Calculate available space
            const available = (head -% tail -% 1) & MASK;
            const to_push = @min(items.len, available);

            if (to_push == 0) {
                if (TRACK_STATS) {
                    _ = self.stats.push_failures.fetchAdd(1, .monotonic);
                }
                return 0;
            }

            // Copy items to buffer
            var pos = tail;
            for (items[0..to_push]) |item| {
                std.debug.assert(pos < capacity);
                self.buffer[pos] = item;
                pos = (pos +% 1) & MASK;
            }

            // Publish new tail
            self.tail.value.store(pos, .release);

            if (TRACK_STATS) {
                _ = self.stats.pushed.fetchAdd(to_push, .monotonic);
                self.updateHighWaterMark();
            }

            return to_push;
        }

        // ====================================================================
        // Consumer Operations
        // ====================================================================

        /// Pop an item from the queue.
        ///
        /// Returns:
        /// - Item if available
        /// - `null` if queue is empty
        ///
        /// Thread safety: Call from consumer thread only.
        pub fn pop(self: *Self) ?T {
            const head = self.head.value.load(.monotonic);

            // P10 Rule 5: Verify index is in bounds
            std.debug.assert(head < capacity);

            // Check if empty: head equals tail
            // Acquire ensures we see producer's item write
            const tail = self.tail.value.load(.acquire);
            if (head == tail) {
                if (TRACK_STATS) {
                    _ = self.stats.pop_failures.fetchAdd(1, .monotonic);
                }
                return null;
            }

            // Read item from buffer
            const item = self.buffer[head];

            // Advance head
            // Release ensures our read completes before head update
            const next_head = (head +% 1) & MASK;
            std.debug.assert(next_head < capacity);
            self.head.value.store(next_head, .release);

            if (TRACK_STATS) {
                _ = self.stats.popped.fetchAdd(1, .monotonic);
            }

            return item;
        }

        /// Peek at front item and return a copy (safe version).
        ///
        /// Returns null if empty.
        /// Returns a copy of the item, safe to use after pop().
        pub fn peek(self: *Self) ?T {
            const head = self.head.value.load(.monotonic);
            const tail = self.tail.value.load(.acquire);

            if (head == tail) {
                return null;
            }

            std.debug.assert(head < capacity);
            return self.buffer[head];
        }

        /// Peek at front item without removing (returns pointer).
        ///
        /// Returns null if empty.
        ///
        /// **WARNING: UNSAFE - Pointer lifetime is limited!**
        /// The returned pointer points directly into the ring buffer.
        /// It is only valid until the next call to `pop()`, `popBatch()`,
        /// or `drain()`. After popping, the producer may overwrite the slot
        /// on wraparound, causing the pointer to reference stale or corrupt data.
        ///
        /// Safe usage:
        /// ```zig
        /// if (queue.peekPtr()) |item| {
        ///     // Use item immediately
        ///     process(item.*);
        /// }
        /// // Do NOT hold the pointer across pop()
        /// ```
        ///
        /// Unsafe usage:
        /// ```zig
        /// const ptr = queue.peekPtr().?;  // Get pointer
        /// _ = queue.pop();                 // Slot now available to producer
        /// use(ptr.*);                      // DANGER: may be overwritten!
        /// ```
        ///
        /// Prefer `peek()` which returns a safe copy unless you need to avoid
        /// copying large items and understand the lifetime constraints.
        pub fn peekPtr(self: *Self) ?*const T {
            const head = self.head.value.load(.monotonic);
            const tail = self.tail.value.load(.acquire);

            if (head == tail) {
                return null;
            }

            std.debug.assert(head < capacity);
            return &self.buffer[head];
        }

        /// Batch pop multiple items.
        /// Returns slice of items popped (up to `out.len`).
        ///
        /// More efficient than individual pops when draining.
        ///
        /// Statistics note: If queue is empty, `pop_failures` is incremented
        /// by 1 (not by `out.len`).
        pub fn popBatch(self: *Self, out: []T) usize {
            // P10 Rule 5: Validate output buffer
            std.debug.assert(out.len > 0);

            const head = self.head.value.load(.monotonic);
            const tail = self.tail.value.load(.acquire);

            // Calculate available items
            const available = (tail -% head) & MASK;
            const to_pop = @min(out.len, available);

            if (to_pop == 0) {
                if (TRACK_STATS) {
                    _ = self.stats.pop_failures.fetchAdd(1, .monotonic);
                }
                return 0;
            }

            // Copy items from buffer
            var pos = head;
            for (out[0..to_pop]) |*slot| {
                std.debug.assert(pos < capacity);
                slot.* = self.buffer[pos];
                pos = (pos +% 1) & MASK;
            }

            // Advance head
            self.head.value.store(pos, .release);

            if (TRACK_STATS) {
                _ = self.stats.popped.fetchAdd(to_pop, .monotonic);
            }

            return to_pop;
        }

        /// Drain all available items, calling handler for each.
        /// Returns number of items processed.
        ///
        /// Bounded: processes at most `capacity - 1` items per call.
        pub fn drain(self: *Self, handler: *const fn (T) void) usize {
            var count: usize = 0;
            const max_drain = USABLE_CAPACITY;

            // P10 Rule 2: Loop bounded by max_drain
            while (count < max_drain) {
                if (self.pop()) |item| {
                    handler(item);
                    count += 1;
                } else {
                    break;
                }
            }

            return count;
        }

        /// Drain with context pointer.
        pub fn drainCtx(
            self: *Self,
            ctx: anytype,
            handler: *const fn (@TypeOf(ctx), T) void,
        ) usize {
            var count: usize = 0;
            const max_drain = USABLE_CAPACITY;

            // P10 Rule 2: Loop bounded by max_drain
            while (count < max_drain) {
                if (self.pop()) |item| {
                    handler(ctx, item);
                    count += 1;
                } else {
                    break;
                }
            }

            return count;
        }

        // ====================================================================
        // Status Queries
        // ====================================================================

        /// Check if queue is empty.
        /// Note: Result may be stale immediately after return.
        pub fn isEmpty(self: *const Self) bool {
            const head = self.head.value.load(.acquire);
            const tail = self.tail.value.load(.acquire);
            return head == tail;
        }

        /// Check if queue is full.
        /// Note: Result may be stale immediately after return.
        pub fn isFull(self: *const Self) bool {
            const head = self.head.value.load(.acquire);
            const tail = self.tail.value.load(.acquire);
            const next_tail = (tail +% 1) & MASK;
            return next_tail == head;
        }

        /// Get current size (approximate).
        /// Note: May race with concurrent push/pop.
        pub fn size(self: *const Self) usize {
            const head = self.head.value.load(.acquire);
            const tail = self.tail.value.load(.acquire);
            return (tail -% head) & MASK;
        }

        /// Get usable capacity.
        pub fn getCapacity() usize {
            return USABLE_CAPACITY;
        }

        /// Get fill percentage (0-100).
        pub fn getFillPercent(self: *const Self) u8 {
            const current = self.size();
            return @intCast((current * 100) / USABLE_CAPACITY);
        }

        // ====================================================================
        // Statistics
        // ====================================================================

        /// Get statistics snapshot.
        pub fn getStats(self: *const Self) QueueStats {
            if (TRACK_STATS) {
                return .{
                    .pushed = self.stats.pushed.load(.monotonic),
                    .popped = self.stats.popped.load(.monotonic),
                    .push_failures = self.stats.push_failures.load(.monotonic),
                    .pop_failures = self.stats.pop_failures.load(.monotonic),
                    .high_water_mark = self.stats.high_water_mark.load(.monotonic),
                };
            } else {
                return QueueStats.init();
            }
        }

        /// Reset statistics counters.
        pub fn resetStats(self: *Self) void {
            if (TRACK_STATS) {
                self.stats.pushed.store(0, .monotonic);
                self.stats.popped.store(0, .monotonic);
                self.stats.push_failures.store(0, .monotonic);
                self.stats.pop_failures.store(0, .monotonic);
                self.stats.high_water_mark.store(0, .monotonic);
            }
        }

        fn updateHighWaterMark(self: *Self) void {
            if (!TRACK_STATS) return;

            const current = self.size();
            var high = self.stats.high_water_mark.load(.monotonic);

            // P10 Rule 2: CAS loop bounded by practical limit
            var attempts: usize = 0;
            const max_attempts: usize = 10;

            while (current > high and attempts < max_attempts) : (attempts += 1) {
                const result = self.stats.high_water_mark.cmpxchgWeak(
                    high,
                    current,
                    .monotonic,
                    .monotonic,
                );
                if (result) |actual| {
                    high = actual;
                } else {
                    break;
                }
            }
        }

        // ====================================================================
        // Debug
        // ====================================================================

        /// Format for debug printing.
        pub fn format(
            self: *const Self,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            const head = self.head.value.load(.monotonic);
            const tail = self.tail.value.load(.monotonic);
            const current_size = (tail -% head) & MASK;

            try writer.print("SpscQueue({s}, {}){{ size={}/{}, head={}, tail={} }}", .{
                @typeName(T),
                capacity,
                current_size,
                USABLE_CAPACITY,
                head,
                tail,
            });
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "SpscQueue - basic push/pop" {
    var queue = SpscQueue(u32, 16).init();

    // Push items
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    try std.testing.expectEqual(@as(usize, 3), queue.size());

    // Pop items (FIFO order)
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());
    try std.testing.expectEqual(@as(?u32, 3), queue.pop());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());

    try std.testing.expectEqual(@as(usize, 0), queue.size());
}

test "SpscQueue - full queue behavior" {
    var queue = SpscQueue(u32, 4).init(); // 3 usable slots

    try std.testing.expectEqual(@as(usize, 3), SpscQueue(u32, 4).getCapacity());

    // Fill queue
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    // Should be full
    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.push(4));

    // Pop one, should allow push
    _ = queue.pop();
    try std.testing.expect(!queue.isFull());
    try std.testing.expect(queue.push(4));
}

test "SpscQueue - empty queue behavior" {
    var queue = SpscQueue(u32, 16).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());

    try std.testing.expect(queue.push(42));
    try std.testing.expect(!queue.isEmpty());

    _ = queue.pop();
    try std.testing.expect(queue.isEmpty());
}

test "SpscQueue - wraparound" {
    var queue = SpscQueue(u32, 4).init();

    // Fill and drain multiple times to test wraparound
    for (0..10) |i| {
        try std.testing.expect(queue.push(@intCast(i)));
        try std.testing.expect(queue.push(@intCast(i + 100)));
        try std.testing.expect(queue.push(@intCast(i + 200)));

        try std.testing.expectEqual(@as(?u32, @intCast(i)), queue.pop());
        try std.testing.expectEqual(@as(?u32, @intCast(i + 100)), queue.pop());
        try std.testing.expectEqual(@as(?u32, @intCast(i + 200)), queue.pop());
    }
}

test "SpscQueue - batch operations" {
    var queue = SpscQueue(u32, 16).init();

    // Batch push
    const items = [_]u32{ 1, 2, 3, 4, 5 };
    const pushed = queue.pushBatch(&items);
    try std.testing.expectEqual(@as(usize, 5), pushed);

    // Batch pop
    var out: [10]u32 = undefined;
    const popped = queue.popBatch(&out);
    try std.testing.expectEqual(@as(usize, 5), popped);
    try std.testing.expectEqualSlices(u32, &items, out[0..5]);
}

test "SpscQueue - peek (safe copy)" {
    var queue = SpscQueue(u32, 16).init();

    try std.testing.expect(queue.peek() == null);

    _ = queue.push(42);

    const peeked = queue.peek();
    try std.testing.expect(peeked != null);
    try std.testing.expectEqual(@as(u32, 42), peeked.?);

    // Peek doesn't consume
    try std.testing.expectEqual(@as(usize, 1), queue.size());

    // Pop returns same value
    try std.testing.expectEqual(@as(?u32, 42), queue.pop());
}

test "SpscQueue - peekPtr (unsafe pointer)" {
    var queue = SpscQueue(u32, 16).init();

    try std.testing.expect(queue.peekPtr() == null);

    _ = queue.push(42);

    const peeked = queue.peekPtr();
    try std.testing.expect(peeked != null);
    try std.testing.expectEqual(@as(u32, 42), peeked.?.*);

    // Peek doesn't consume
    try std.testing.expectEqual(@as(usize, 1), queue.size());

    // Pop returns same value
    try std.testing.expectEqual(@as(?u32, 42), queue.pop());
}

test "SpscQueue - drain" {
    var queue = SpscQueue(u32, 16).init();

    _ = queue.push(1);
    _ = queue.push(2);
    _ = queue.push(3);

    const sum: u32 = 0;
    const handler = struct {
        fn handle(item: u32) void {
            _ = item;
            // Can't capture, but demonstrates the API
        }
    }.handle;

    const drained = queue.drain(handler);
    try std.testing.expectEqual(@as(usize, 3), drained);
    try std.testing.expect(queue.isEmpty());
    _ = sum;
}

test "SpscQueue - statistics" {
    if (!TRACK_STATS) return;

    var queue = SpscQueue(u32, 4).init();

    _ = queue.push(1);
    _ = queue.push(2);
    _ = queue.push(3);
    _ = queue.push(4); // Fails - full

    _ = queue.pop();
    _ = queue.pop();
    _ = queue.pop();
    _ = queue.pop(); // Fails - empty

    const stats = queue.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.pushed);
    try std.testing.expectEqual(@as(u64, 3), stats.popped);
    try std.testing.expectEqual(@as(u64, 1), stats.push_failures);
    try std.testing.expectEqual(@as(u64, 1), stats.pop_failures);
}

test "SpscQueue - cache line alignment" {
    const Queue = SpscQueue(u64, 64);

    // Verify cache line alignment
    try std.testing.expectEqual(@as(usize, 64), @alignOf(Queue.CacheLineAtomic));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Queue.CacheLineAtomic));
}

test "SpscQueue - stats block cache line separation" {
    if (!TRACK_STATS) return;

    const Queue = SpscQueue(u64, 64);

    // Verify producer and consumer stats are on separate cache lines
    try std.testing.expectEqual(@as(usize, CACHE_LINE_SIZE), @offsetOf(Queue.StatsBlock, "popped"));
}

test "SpscQueue - fill percent" {
    var queue = SpscQueue(u32, 16).init(); // 15 usable

    try std.testing.expectEqual(@as(u8, 0), queue.getFillPercent());

    for (0..8) |_| {
        _ = queue.push(1);
    }

    // 8/15 ≈ 53%
    const percent = queue.getFillPercent();
    try std.testing.expect(percent >= 50 and percent <= 55);
}
