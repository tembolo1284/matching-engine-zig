//! Thread-safe collections for high-performance message passing.
//!
//! This module provides lock-free data structures optimized for
//! inter-thread communication in trading systems.
//!
//! Components:
//!
//! - **SpscQueue**: Lock-free single-producer single-consumer queue.
//!   O(1) push/pop, cache-line aligned, zero allocation.
//!
//! - **BoundedChannel**: Higher-level wrapper around SpscQueue with
//!   timeout support, backoff strategies, and graceful shutdown.
//!
//! Usage patterns:
//!
//! ```
//! I/O Thread                      Processor Thread
//!     │                                 │
//!     │  ┌──────────────────────┐       │
//!     ├─►│   InputChannel       │──────►│
//!     │  │  (orders, cancels)   │       │
//!     │  └──────────────────────┘       │
//!     │                                 │
//!     │  ┌──────────────────────┐       │
//!     │◄─│   OutputChannel      │◄──────│
//!     │  │  (acks, trades)      │       │
//!     │  └──────────────────────┘       │
//! ```
//!
//! Thread safety:
//! - All collections are designed for exactly ONE producer and ONE consumer
//! - Multiple producers/consumers require multiple queues or external sync
//!
//! Performance characteristics:
//! - Lock-free (no mutex, no syscalls in hot path)
//! - Cache-line aligned (no false sharing)
//! - Wait-free push/pop (bounded time)
//! - Zero allocation after init

const std = @import("std");

// ============================================================================
// Re-exports
// ============================================================================

/// Lock-free single-producer single-consumer queue.
pub const SpscQueue = @import("spsc_queue.zig").SpscQueue;

/// Queue statistics.
pub const QueueStats = @import("spsc_queue.zig").QueueStats;

/// Cache line size used for alignment.
pub const CACHE_LINE_SIZE = @import("spsc_queue.zig").CACHE_LINE_SIZE;

/// Whether statistics tracking is enabled.
pub const TRACK_STATS = @import("spsc_queue.zig").TRACK_STATS;

/// Bounded channel for message passing.
pub const BoundedChannel = @import("bounded_channel.zig").BoundedChannel;

/// Receive result type.
pub const RecvResult = @import("bounded_channel.zig").RecvResult;

/// Type alias for input channels (semantic clarity).
pub const InputChannel = @import("bounded_channel.zig").InputChannel;

/// Type alias for output channels (semantic clarity).
pub const OutputChannel = @import("bounded_channel.zig").OutputChannel;

// ============================================================================
// Convenience Functions
// ============================================================================

/// Create a standard input channel for processor messages.
/// Default capacity: 64K messages.
pub fn createInputChannel(comptime T: type) BoundedChannel(T, 65536) {
    return BoundedChannel(T, 65536).init();
}

/// Create a standard output channel for responses.
/// Default capacity: 64K messages.
pub fn createOutputChannel(comptime T: type) BoundedChannel(T, 65536) {
    return BoundedChannel(T, 65536).init();
}

// ============================================================================
// Tests
// ============================================================================

test "module exports" {
    // Verify all exports are accessible
    var queue = SpscQueue(u32, 16).init();
    var channel = BoundedChannel(u32, 16).init();

    _ = queue.push(1);
    _ = channel.send(1);

    try std.testing.expect(CACHE_LINE_SIZE == 64);
}

test "convenience functions" {
    const InputChan = @TypeOf(createInputChannel(u32));
    const OutputChan = @TypeOf(createOutputChannel(u32));

    try std.testing.expectEqual(@as(usize, 65535), InputChan.CAPACITY);
    try std.testing.expectEqual(@as(usize, 65535), OutputChan.CAPACITY);
}
