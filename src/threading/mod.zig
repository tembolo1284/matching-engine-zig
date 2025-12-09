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
//!
//! NASA Power of Ten Compliance:
//! - Rule 2: All loops in processor and server have explicit bounds
//! - Rule 5: Critical state transitions validated with assertions
//! - Rule 7: All queue operations and results checked

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
// Compile-Time Validation
// ============================================================================

comptime {
    // Validate channel capacity is power of 2
    std.debug.assert(CHANNEL_CAPACITY > 0);
    std.debug.assert((CHANNEL_CAPACITY & (CHANNEL_CAPACITY - 1)) == 0);

    // Validate reasonable number of processors
    std.debug.assert(NUM_PROCESSORS > 0);
    std.debug.assert(NUM_PROCESSORS <= 8);
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Check if the threading system is configured for production use.
/// Returns true if latency tracking is disabled (lower overhead).
pub fn isProductionConfig() bool {
    return !TRACK_LATENCY;
}

/// Get recommended channel capacity based on expected throughput.
/// Returns minimum capacity needed for given orders per second with ~1ms buffer.
pub fn recommendedCapacity(orders_per_sec: u64) u64 {
    // Assume ~2 outputs per order average
    const outputs_per_sec = orders_per_sec * 2;
    // 1ms buffer at given throughput
    const min_capacity = outputs_per_sec / 1000;
    // Round up to next power of 2
    if (min_capacity == 0) return 64;

    var cap: u64 = 64;
    while (cap < min_capacity and cap < 1 << 20) {
        cap *= 2;
    }
    return cap;
}

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

test "routeSymbol partitioning" {
    const msg = @import("../protocol/message_types.zig");

    // A-M should go to processor 0
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("AAPL")));
    try std.testing.expectEqual(ProcessorId.processor_0, routeSymbol(msg.makeSymbol("MSFT")));

    // N-Z should go to processor 1
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("NVDA")));
    try std.testing.expectEqual(ProcessorId.processor_1, routeSymbol(msg.makeSymbol("TSLA")));
}

test "channel capacity is power of 2" {
    try std.testing.expect(CHANNEL_CAPACITY > 0);
    try std.testing.expect((CHANNEL_CAPACITY & (CHANNEL_CAPACITY - 1)) == 0);
}

test "recommended capacity" {
    // Low throughput
    try std.testing.expectEqual(@as(u64, 64), recommendedCapacity(0));
    try std.testing.expectEqual(@as(u64, 64), recommendedCapacity(1000));

    // Medium throughput (100K orders/sec)
    const med = recommendedCapacity(100_000);
    try std.testing.expect(med >= 200); // At least 200 capacity for 100K orders
    try std.testing.expect((med & (med - 1)) == 0); // Power of 2

    // High throughput (1M orders/sec)
    const high = recommendedCapacity(1_000_000);
    try std.testing.expect(high >= 2000);
    try std.testing.expect((high & (high - 1)) == 0);
}

test "isProductionConfig" {
    // Just verify function exists and returns a bool
    const result = isProductionConfig();
    try std.testing.expect(result == true or result == false);
}
