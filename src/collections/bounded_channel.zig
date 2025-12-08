//! Bounded channel for typed message passing between threads.
//!
//! Provides a high-level interface over SpscQueue for common patterns:
//! - Blocking/non-blocking send
//! - Blocking/non-blocking receive with timeout
//! - Backpressure handling
//! - Shutdown signaling
//!
//! Architecture:
//! ```
//!   Producer Thread          BoundedChannel           Consumer Thread
//!        │                        │                        │
//!        │  send(msg) ──────────► │ ◄─────────── tryRecv() │
//!        │                    [SpscQueue]                  │
//!        │  trySend(msg) ──────►  │ ◄──────── recvTimeout()│
//!        │                        │                        │
//! ```
//!
//! Thread safety:
//! - Exactly ONE sender and ONE receiver
//! - Not safe for multiple producers or consumers
//!
//! Performance notes:
//! - Timeout-based operations use `nanoTimestamp()` which is a syscall on Linux
//!   (~50-100ns overhead per call). For ultra-low-latency paths, prefer the
//!   non-blocking `send()`/`tryRecv()` or bounded-spin variants.
//! - Spin-based operations burn CPU but avoid syscall overhead.
//!
//! Example:
//! ```zig
//! const Channel = BoundedChannel(Message, 1024);
//! var channel = Channel.init();
//!
//! // Producer
//! if (!channel.send(msg)) {
//!     handleBackpressure();
//! }
//!
//! // Consumer
//! while (channel.tryRecv()) |msg| {
//!     process(msg);
//! }
//! ```

const std = @import("std");
const SpscQueue = @import("spsc_queue.zig").SpscQueue;
const QueueStats = @import("spsc_queue.zig").QueueStats;

// ============================================================================
// Configuration
// ============================================================================

/// Default spin iterations before yielding.
pub const DEFAULT_SPIN_ITERATIONS: u32 = 100;

/// Default yield iterations before sleeping.
pub const DEFAULT_YIELD_ITERATIONS: u32 = 10;

/// Minimum sleep duration (nanoseconds).
pub const MIN_SLEEP_NS: u64 = 1_000; // 1μs

/// Maximum sleep duration (nanoseconds).
pub const MAX_SLEEP_NS: u64 = 1_000_000; // 1ms

// ============================================================================
// Receive Result
// ============================================================================

/// Result of a receive operation with timeout.
pub fn RecvResult(comptime T: type) type {
    return union(enum) {
        /// Successfully received message.
        message: T,
        /// Channel is empty (non-blocking) or timeout expired.
        empty,
        /// Channel was closed.
        closed,
    };
}

// ============================================================================
// Bounded Channel
// ============================================================================

/// A bounded channel for passing messages of type T.
///
/// Parameters:
/// - `T`: Message type
/// - `capacity`: Maximum messages in flight (must be power of 2)
pub fn BoundedChannel(comptime T: type, comptime capacity: usize) type {
    return struct {
        /// Underlying lock-free queue.
        queue: SpscQueue(T, capacity),

        /// Closed flag for graceful shutdown.
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        const Self = @This();

        /// Usable capacity (one slot reserved in underlying queue).
        pub const CAPACITY: usize = SpscQueue(T, capacity).USABLE_CAPACITY;

        // ====================================================================
        // Lifecycle
        // ====================================================================

        /// Initialize an empty channel.
        pub fn init() Self {
            return .{
                .queue = SpscQueue(T, capacity).init(),
            };
        }

        /// Close the channel for graceful shutdown.
        ///
        /// After closing:
        /// - `send()` will return false (eventually)
        /// - Pending messages can still be received via `tryRecv()`
        /// - `tryRecv()` returns null only when closed AND empty
        ///
        /// **Race condition note:** Close is not instantaneous. A `send()` that
        /// races with `close()` may succeed in enqueuing its message. This is
        /// intentional for graceful shutdown — it allows the consumer to drain
        /// all pending work before terminating. The sequence:
        ///
        /// 1. Producer: `send(final_msg)` — may succeed if close() hasn't propagated
        /// 2. Main: `channel.close()`
        /// 3. Consumer: drain with `while (tryRecv()) |msg| { process(msg); }`
        ///
        /// This guarantees no messages are lost during shutdown.
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }

        /// Check if channel is closed.
        pub fn isClosed(self: *const Self) bool {
            return self.closed.load(.acquire);
        }

        /// Reset channel to initial state.
        /// NOT thread-safe - call only when no threads are accessing.
        pub fn reset(self: *Self) void {
            self.queue.reset();
            self.closed.store(false, .monotonic);
        }

        // ====================================================================
        // Send Operations
        // ====================================================================

        /// Send a message (non-blocking).
        ///
        /// Returns:
        /// - `true` if message was enqueued
        /// - `false` if channel is full or closed
        ///
        /// Note: A send racing with close() may still succeed. See `close()` docs.
        pub fn send(self: *Self, message: T) bool {
            if (self.isClosed()) return false;
            return self.queue.push(message);
        }

        /// Send with prefetch hint for better cache behavior.
        pub fn sendWithPrefetch(self: *Self, message: T) bool {
            if (self.isClosed()) return false;
            return self.queue.pushWithPrefetch(message);
        }

        /// Send multiple messages (batch).
        /// Returns number of messages sent.
        pub fn sendBatch(self: *Self, messages: []const T) usize {
            if (self.isClosed()) return 0;
            return self.queue.pushBatch(messages);
        }

        /// Send with bounded spinning if full.
        ///
        /// Spins up to `max_spins` times before returning false.
        /// More aggressive than plain send(), use for low-latency paths.
        ///
        /// CPU cost: Burns CPU during spin. Use when latency matters more than
        /// throughput, and when you expect the queue to drain quickly.
        pub fn sendSpin(self: *Self, message: T, max_spins: u32) bool {
            var spins: u32 = 0;

            while (spins < max_spins) : (spins += 1) {
                if (self.isClosed()) return false;

                if (self.queue.push(message)) {
                    return true;
                }

                std.atomic.spinLoopHint();
            }

            return false;
        }

        /// Send with backoff strategy if full.
        ///
        /// Strategy: spin → yield → sleep (exponential backoff)
        /// Returns false if timeout expires or channel closes.
        ///
        /// Performance note: Uses `nanoTimestamp()` which is a syscall on Linux.
        /// For tighter latency bounds, use `sendSpin()` with a fixed iteration count.
        pub fn sendBackoff(self: *Self, message: T, timeout_ns: u64) bool {
            const deadline = std.time.nanoTimestamp() + @as(i128, timeout_ns);

            var sleep_ns: u64 = MIN_SLEEP_NS;
            var spins: u32 = 0;
            var yields: u32 = 0;

            while (std.time.nanoTimestamp() < deadline) {
                if (self.isClosed()) return false;

                if (self.queue.push(message)) {
                    return true;
                }

                // Backoff strategy: spin → yield → sleep
                if (spins < DEFAULT_SPIN_ITERATIONS) {
                    std.atomic.spinLoopHint();
                    spins += 1;
                } else if (yields < DEFAULT_YIELD_ITERATIONS) {
                    // yield() can fail on some platforms; if so, proceed to sleep phase
                    std.Thread.yield() catch {};
                    yields += 1;
                } else {
                    std.time.sleep(sleep_ns);
                    sleep_ns = @min(sleep_ns * 2, MAX_SLEEP_NS);
                }
            }

            return false;
        }

        // ====================================================================
        // Receive Operations
        // ====================================================================

        /// Try to receive a message (non-blocking).
        ///
        /// Returns:
        /// - Message if available
        /// - `null` if channel is empty
        pub fn tryRecv(self: *Self) ?T {
            return self.queue.pop();
        }

        /// Receive with full result information.
        pub fn tryRecvResult(self: *Self) RecvResult(T) {
            if (self.queue.pop()) |message| {
                return .{ .message = message };
            }

            if (self.isClosed()) {
                return .closed;
            }

            return .empty;
        }

        /// Receive multiple messages (batch).
        /// Returns number of messages received.
        pub fn recvBatch(self: *Self, out: []T) usize {
            return self.queue.popBatch(out);
        }

        /// Receive with bounded spinning.
        ///
        /// Spins up to `max_spins` times waiting for a message.
        ///
        /// CPU cost: Burns CPU during spin. Use sparingly, only when you expect
        /// messages to arrive very soon and latency is critical.
        pub fn recvSpin(self: *Self, max_spins: u32) ?T {
            var spins: u32 = 0;

            while (spins < max_spins) : (spins += 1) {
                if (self.queue.pop()) |message| {
                    return message;
                }

                if (self.isClosed() and self.queue.isEmpty()) {
                    return null;
                }

                std.atomic.spinLoopHint();
            }

            return null;
        }

        /// Receive with timeout.
        ///
        /// Uses backoff strategy: spin → yield → sleep
        /// Returns null if timeout expires or channel closes with no pending.
        ///
        /// Performance note: Uses `nanoTimestamp()` which is a syscall on Linux.
        /// For tighter latency bounds, use `recvSpin()` with a fixed iteration count.
        pub fn recvTimeout(self: *Self, timeout_ns: u64) ?T {
            const deadline = std.time.nanoTimestamp() + @as(i128, timeout_ns);

            var sleep_ns: u64 = MIN_SLEEP_NS;
            var spins: u32 = 0;
            var yields: u32 = 0;

            while (std.time.nanoTimestamp() < deadline) {
                if (self.queue.pop()) |message| {
                    return message;
                }

                if (self.isClosed() and self.queue.isEmpty()) {
                    return null;
                }

                // Backoff strategy: spin → yield → sleep
                if (spins < DEFAULT_SPIN_ITERATIONS) {
                    std.atomic.spinLoopHint();
                    spins += 1;
                } else if (yields < DEFAULT_YIELD_ITERATIONS) {
                    // yield() can fail on some platforms; if so, proceed to sleep phase
                    std.Thread.yield() catch {};
                    yields += 1;
                } else {
                    std.time.sleep(sleep_ns);
                    sleep_ns = @min(sleep_ns * 2, MAX_SLEEP_NS);
                }
            }

            return null;
        }

        /// Receive with result and timeout.
        pub fn recvTimeoutResult(self: *Self, timeout_ns: u64) RecvResult(T) {
            if (self.recvTimeout(timeout_ns)) |message| {
                return .{ .message = message };
            }

            if (self.isClosed()) {
                return .closed;
            }

            return .empty;
        }

        /// Drain all available messages.
        /// Returns number of messages processed.
        ///
        /// Bounded: processes at most CAPACITY messages per call.
        pub fn drain(self: *Self, handler: *const fn (T) void) usize {
            return self.queue.drain(handler);
        }

        /// Drain with context.
        pub fn drainCtx(
            self: *Self,
            ctx: anytype,
            handler: *const fn (@TypeOf(ctx), T) void,
        ) usize {
            return self.queue.drainCtx(ctx, handler);
        }

        // ====================================================================
        // Status
        // ====================================================================

        /// Check if channel is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.queue.isEmpty();
        }

        /// Check if channel is full.
        pub fn isFull(self: *const Self) bool {
            return self.queue.isFull();
        }

        /// Get approximate number of pending messages.
        pub fn pending(self: *const Self) usize {
            return self.queue.size();
        }

        /// Get capacity.
        pub fn getCapacity() usize {
            return CAPACITY;
        }

        /// Get fill percentage (0-100).
        pub fn getFillPercent(self: *const Self) u8 {
            return self.queue.getFillPercent();
        }

        // ====================================================================
        // Statistics
        // ====================================================================

        /// Get statistics.
        pub fn getStats(self: *const Self) QueueStats {
            return self.queue.getStats();
        }

        /// Reset statistics.
        pub fn resetStats(self: *Self) void {
            self.queue.resetStats();
        }

        // ====================================================================
        // Debug
        // ====================================================================

        /// Format for debug printing.
        pub fn format(
            self: *const Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            const closed_str = if (self.isClosed()) " CLOSED" else "";
            try writer.print("BoundedChannel({s}, {}){{ pending={}/{}{s} }}", .{
                @typeName(T),
                capacity,
                self.pending(),
                CAPACITY,
                closed_str,
            });
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "BoundedChannel - basic send/recv" {
    var channel = BoundedChannel(u32, 16).init();

    try std.testing.expect(channel.send(1));
    try std.testing.expect(channel.send(2));
    try std.testing.expect(channel.send(3));

    try std.testing.expectEqual(@as(?u32, 1), channel.tryRecv());
    try std.testing.expectEqual(@as(?u32, 2), channel.tryRecv());
    try std.testing.expectEqual(@as(?u32, 3), channel.tryRecv());
    try std.testing.expectEqual(@as(?u32, null), channel.tryRecv());
}

test "BoundedChannel - full channel" {
    var channel = BoundedChannel(u32, 4).init();

    try std.testing.expect(channel.send(1));
    try std.testing.expect(channel.send(2));
    try std.testing.expect(channel.send(3));
    try std.testing.expect(!channel.send(4)); // Full

    try std.testing.expect(channel.isFull());
}

test "BoundedChannel - close behavior" {
    var channel = BoundedChannel(u32, 16).init();

    try std.testing.expect(channel.send(1));
    try std.testing.expect(channel.send(2));

    channel.close();

    // Can't send after close
    try std.testing.expect(!channel.send(3));
    try std.testing.expect(channel.isClosed());

    // Can still receive pending
    try std.testing.expectEqual(@as(?u32, 1), channel.tryRecv());
    try std.testing.expectEqual(@as(?u32, 2), channel.tryRecv());
    try std.testing.expectEqual(@as(?u32, null), channel.tryRecv());
}

test "BoundedChannel - recv result" {
    var channel = BoundedChannel(u32, 16).init();

    // Empty
    const r1 = channel.tryRecvResult();
    try std.testing.expect(r1 == .empty);

    // With message
    _ = channel.send(42);
    const r2 = channel.tryRecvResult();
    switch (r2) {
        .message => |message| try std.testing.expectEqual(@as(u32, 42), message),
        else => return error.ExpectedMessage,
    }

    // Closed
    channel.close();
    const r3 = channel.tryRecvResult();
    try std.testing.expect(r3 == .closed);
}

test "BoundedChannel - batch operations" {
    var channel = BoundedChannel(u32, 16).init();

    const items = [_]u32{ 1, 2, 3, 4, 5 };
    const sent = channel.sendBatch(&items);
    try std.testing.expectEqual(@as(usize, 5), sent);

    var out: [10]u32 = undefined;
    const received = channel.recvBatch(&out);
    try std.testing.expectEqual(@as(usize, 5), received);
    try std.testing.expectEqualSlices(u32, &items, out[0..5]);
}

test "BoundedChannel - recv spin bounded" {
    var channel = BoundedChannel(u32, 16).init();

    // Empty channel with bounded spin
    const result = channel.recvSpin(10);
    try std.testing.expectEqual(@as(?u32, null), result);

    // With message
    _ = channel.send(42);
    const result2 = channel.recvSpin(10);
    try std.testing.expectEqual(@as(?u32, 42), result2);
}

test "BoundedChannel - capacity" {
    try std.testing.expectEqual(@as(usize, 15), BoundedChannel(u32, 16).CAPACITY);
    try std.testing.expectEqual(@as(usize, 15), BoundedChannel(u32, 16).getCapacity());
}

test "BoundedChannel - reset" {
    var channel = BoundedChannel(u32, 16).init();

    _ = channel.send(1);
    _ = channel.send(2);
    channel.close();

    channel.reset();

    try std.testing.expect(!channel.isClosed());
    try std.testing.expect(channel.isEmpty());
    try std.testing.expect(channel.send(42));
}

test "BoundedChannel - fill percent" {
    var channel = BoundedChannel(u32, 16).init();

    try std.testing.expectEqual(@as(u8, 0), channel.getFillPercent());

    for (0..8) |_| {
        _ = channel.send(1);
    }

    const percent = channel.getFillPercent();
    try std.testing.expect(percent >= 50 and percent <= 55);
}
