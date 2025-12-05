//! Performance benchmarks for the matching engine.
//!
//! Benchmarks:
//! - Order insertion throughput
//! - Order matching latency
//! - Cancel performance
//! - SPSC queue throughput

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const MemoryPools = @import("../core/memory_pool.zig").MemoryPools;
const MatchingEngine = @import("../core/matching_engine.zig").MatchingEngine;
const OutputBuffer = @import("../core/order_book.zig").OutputBuffer;
const SpscQueue = @import("../collections/spsc_queue.zig").SpscQueue;

// ============================================================================
// Benchmark Utilities
// ============================================================================

const WARMUP_ITERATIONS: usize = 10_000;
const BENCH_ITERATIONS: usize = 1_000_000;

fn formatNanos(nanos: u64) struct { value: f64, unit: []const u8 } {
    if (nanos < 1_000) {
        return .{ .value = @floatFromInt(nanos), .unit = "ns" };
    } else if (nanos < 1_000_000) {
        return .{ .value = @as(f64, @floatFromInt(nanos)) / 1_000.0, .unit = "μs" };
    } else if (nanos < 1_000_000_000) {
        return .{ .value = @as(f64, @floatFromInt(nanos)) / 1_000_000.0, .unit = "ms" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(nanos)) / 1_000_000_000.0, .unit = "s" };
    }
}

fn printResult(name: []const u8, total_ns: u64, iterations: usize) void {
    const per_op = total_ns / iterations;
    const ops_per_sec = if (per_op > 0) 1_000_000_000 / per_op else 0;
    const fmt = formatNanos(per_op);

    std.debug.print("  {s}: {d:.2} {s}/op ({d} ops/sec)\n", .{
        name,
        fmt.value,
        fmt.unit,
        ops_per_sec,
    });
}

// ============================================================================
// Benchmarks
// ============================================================================

fn benchOrderInsertion(allocator: std.mem.Allocator) !void {
    var pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    var engine = MatchingEngine.init(&pools);
    var output = OutputBuffer.init();

    // Create test orders (non-matching prices to avoid trade overhead)
    var orders: [BENCH_ITERATIONS]msg.InputMsg = undefined;
    for (&orders, 0..) |*order, i| {
        order.* = msg.InputMsg.newOrder(.{
            .user_id = 1,
            .user_order_id = @intCast(i),
            .price = 100, // All same price - will queue, not match
            .quantity = 100,
            .side = .buy,
            .symbol = msg.makeSymbol("BENCH"),
        });
    }

    // Warmup
    for (0..WARMUP_ITERATIONS) |i| {
        engine.processMessage(&orders[i], 1, &output);
        output.clear();
    }

    // Reset for actual benchmark
    engine.handleFlush(&output);
    output.clear();

    // Benchmark
    var timer = try std.time.Timer.start();

    for (&orders) |*order| {
        engine.processMessage(order, 1, &output);
        output.clear();
    }

    const elapsed = timer.read();
    printResult("Order Insertion", elapsed, BENCH_ITERATIONS);
}

fn benchSpscQueue() void {
    var queue = SpscQueue(u64, 65536).init();

    // Warmup
    for (0..WARMUP_ITERATIONS) |i| {
        _ = queue.push(i);
        _ = queue.pop();
    }

    // Benchmark push
    var timer = try std.time.Timer.start();

    for (0..BENCH_ITERATIONS) |i| {
        _ = queue.push(i);
    }

    const push_elapsed = timer.read();

    // Benchmark pop
    timer.reset();

    for (0..BENCH_ITERATIONS) |_| {
        _ = queue.pop();
    }

    const pop_elapsed = timer.read();

    printResult("SPSC Push", push_elapsed, BENCH_ITERATIONS);
    printResult("SPSC Pop", pop_elapsed, BENCH_ITERATIONS);
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Zig Matching Engine Benchmarks ===\n\n", .{});
    std.debug.print("Iterations: {d}\n", .{BENCH_ITERATIONS});
    std.debug.print("Warmup: {d}\n\n", .{WARMUP_ITERATIONS});

    std.debug.print("Core:\n", .{});
    try benchOrderInsertion(allocator);

    std.debug.print("\nCollections:\n", .{});
    benchSpscQueue();

    std.debug.print("\n=== Benchmarks Complete ===\n\n", .{});
}
