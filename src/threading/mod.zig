//! Threading layer for dual-processor matching engine.
//!
//! Architecture overview:
//! - I/O thread handles all network communication (TCP, UDP, Multicast)
//! - Two processor threads handle order matching (partitioned by symbol)
//! - SPSC queues connect I/O thread to processors (zero-copy, lock-free)
//!
//! Symbol partitioning:
//! - Processor 0: Symbols starting with A-M (or non-alphabetic)
//! - Processor 1: Symbols starting with N-Z
//!
//! Thread safety:
//! - Each processor owns its MatchingEngine exclusively
//! - Communication via lock-free SPSC queues only
//! - No shared mutable state between threads
//!
//! Backpressure handling:
//! - Output queues have 64K capacity (~1ms buffer at high throughput)
//! - Spin-wait with yield on output queue full
//! - Critical message drops (trades/rejects) logged and optionally panic in debug
//!
//! Latency tracking:
//! - Configurable via TRACK_LATENCY flag in processor.zig
//! - When enabled: tracks queue latency and processing time per message
//! - When disabled: eliminates syscall overhead (~100-200ns per message)

const std = @import("std");

// ============================================================================
// Processor Types
// ============================================================================

pub const Processor = @import("processor.zig").Processor;
pub const ProcessorId = @import("processor.zig").ProcessorId;
pub const ProcessorInput = @import("processor.zig").ProcessorInput;
pub const ProcessorOutput = @import("processor.zig").ProcessorOutput;
pub const ProcessorStats = @import("processor.zig").ProcessorStats;
pub const routeSymbol = @import("processor.zig").routeSymbol;

// ============================================================================
// Server Types
// ============================================================================

pub const ThreadedServer = @import("threaded_server.zig").ThreadedServer;
pub const ServerStats = @import("threaded_server.zig").ServerStats;

// ============================================================================
// Queue Types (for external use)
// ============================================================================

pub const InputQueue = @import("processor.zig").InputQueue;
pub const OutputQueue = @import("processor.zig").OutputQueue;

// ============================================================================
// Configuration Constants
// ============================================================================

/// Channel capacity for I/O ↔ Processor communication.
/// Must be power of 2. 64K provides ~1ms buffer at 60M msg/sec.
pub const CHANNEL_CAPACITY = @import("processor.zig").CHANNEL_CAPACITY;

/// Number of processor threads.
pub const NUM_PROCESSORS = @import("threaded_server.zig").NUM_PROCESSORS;

/// Whether latency tracking is enabled (affects syscall overhead).
pub const TRACK_LATENCY = @import("processor.zig").TRACK_LATENCY;

// ============================================================================
// Tests
// ============================================================================

test "module exports" {
    // Verify all exports are accessible
    try std.testing.expectEqual(@as(usize, 65536), CHANNEL_CAPACITY);
    try std.testing.expectEqual(@as(usize, 2), NUM_PROCESSORS);

    // Verify type exports
    _ = Processor;
    _ = ProcessorId;
    _ = ThreadedServer;
    _ = ServerStats;
}

test "routeSymbol consistency" {
    const msg = @import("../protocol/message_types.zig");

    // Verify routing is deterministic
    const sym1 = msg.makeSymbol("AAPL");
    const sym2 = msg.makeSymbol("AAPL");

    try std.testing.expectEqual(routeSymbol(sym1), routeSymbol(sym2));
}
