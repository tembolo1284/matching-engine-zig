//! Benchmark - Performance Testing for Matching Engine
//!
//! Tests throughput and latency of core components.

const std = @import("std");
const msg = @import("protocol/message_types.zig");
const OrderBook = @import("core/order_book.zig").OrderBook;
const MatchingEngine = @import("core/matching_engine.zig").MatchingEngine;
const OutputBuffer = @import("core/output_buffer.zig").OutputBuffer;
const SyncProcessor = @import("threading/processor.zig").SyncProcessor;
const SpscQueue = @import("threading/spsc_queue.zig").SpscQueue;

const WARMUP_ITERATIONS: usize = 10_000;
const BENCH_ITERATIONS: usize = 1_000_000;

fn benchmarkOrderBook() !void {
    std.debug.print("\n=== Order Book Benchmark ===\n", .{});

    var book = OrderBook.init("BENCH");
    var output = OutputBuffer.init();

    // Warmup
    for (0..WARMUP_ITERATIONS) |i| {
        var order = msg.NewOrderMsg{
            .user_id = 1,
            .user_order_id = @intCast(i),
            .price = 100 + @as(u32, @intCast(i % 10)),
            .quantity = 100,
            .side = if (i % 2 == 0) .buy else .sell,
            ._pad = .{ 0, 0, 0 },
            .symbol = undefined,
        };
        msg.copySymbol(&order.symbol, "BENCH");
        book.addOrder(&order, 0, &output);
        output.reset();
    }

    // Reset for benchmark
    _ = book.flush(&output);
    output.reset();

    // Benchmark: Add orders
    var timer = try std.time.Timer.start();

    for (0..BENCH_ITERATIONS) |i| {
        var order = msg.NewOrderMsg{
            .user_id = 1,
            .user_order_id = @intCast(i),
            .price = 100 + @as(u32, @intCast(i % 100)),
            .quantity = 100,
            .side = if (i % 2 == 0) .buy else .sell,
            ._pad = .{ 0, 0, 0 },
            .symbol = undefined,
        };
        msg.copySymbol(&order.symbol, "BENCH");
        book.addOrder(&order, 0, &output);
        output.reset();
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(BENCH_ITERATIONS)) / (elapsed_ms / 1000.0);
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS));

    std.debug.print("  Orders processed: {d}\n", .{BENCH_ITERATIONS});
    std.debug.print("  Time:             {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Throughput:       {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("  Latency:          {d:.1} ns/op\n", .{ns_per_op});
}

fn benchmarkSpscQueue() !void {
    std.debug.print("\n=== SPSC Queue Benchmark ===\n", .{});

    var queue = SpscQueue(u64, 8192).init();

    // Warmup
    for (0..WARMUP_ITERATIONS) |i| {
        _ = queue.push(i);
        _ = queue.pop();
    }

    // Benchmark: Push/Pop pairs
    var timer = try std.time.Timer.start();

    for (0..BENCH_ITERATIONS) |i| {
        _ = queue.push(i);
        _ = queue.pop();
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(BENCH_ITERATIONS * 2)) / (elapsed_ms / 1000.0);
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS * 2));

    std.debug.print("  Operations:       {d} (push+pop pairs)\n", .{BENCH_ITERATIONS});
    std.debug.print("  Time:             {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Throughput:       {d:.0} ops/sec\n", .{ops_per_sec});
    std.debug.print("  Latency:          {d:.1} ns/op\n", .{ns_per_op});
}

fn benchmarkSyncProcessor() !void {
    std.debug.print("\n=== Sync Processor Benchmark ===\n", .{});

    var processor = SyncProcessor.init();

    // Warmup
    for (0..WARMUP_ITERATIONS) |i| {
        var order = msg.NewOrderMsg{
            .user_id = 1,
            .user_order_id = @intCast(i),
            .price = 100,
            .quantity = 100,
            .side = if (i % 2 == 0) .buy else .sell,
            ._pad = .{ 0, 0, 0 },
            .symbol = undefined,
        };
        msg.copySymbol(&order.symbol, "TEST");
        _ = processor.processNewOrder(&order, 0);
    }

    // Flush and reset
    _ = processor.processFlush();

    // Benchmark
    var timer = try std.time.Timer.start();

    for (0..BENCH_ITERATIONS) |i| {
        var order = msg.NewOrderMsg{
            .user_id = @intCast((i % 1000) + 1),
            .user_order_id = @intCast(i),
            .price = 100 + @as(u32, @intCast(i % 50)),
            .quantity = 100,
            .side = if (i % 2 == 0) .buy else .sell,
            ._pad = .{ 0, 0, 0 },
            .symbol = undefined,
        };
        // Spread across multiple symbols
        const symbols = [_][]const u8{ "AAPL", "IBM", "GOOG", "MSFT", "AMZN" };
        msg.copySymbol(&order.symbol, symbols[i % symbols.len]);
        _ = processor.processNewOrder(&order, 0);
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(BENCH_ITERATIONS)) / (elapsed_ms / 1000.0);
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(BENCH_ITERATIONS));

    std.debug.print("  Orders processed: {d}\n", .{BENCH_ITERATIONS});
    std.debug.print("  Symbols:          5\n", .{});
    std.debug.print("  Time:             {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Throughput:       {d:.0} orders/sec\n", .{ops_per_sec});
    std.debug.print("  Latency:          {d:.1} ns/order\n", .{ns_per_op});
}

pub fn main() !void {
    std.debug.print("╔════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     Matching Engine Benchmark Suite        ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════╝\n", .{});

    try benchmarkSpscQueue();
    try benchmarkOrderBook();
    try benchmarkSyncProcessor();

    std.debug.print("\n", .{});
}
