//! Performance benchmarks for the matching engine.
//!
//! Benchmarks:
//! - Order insertion throughput
//! - Order matching (trade generation)
//! - Order cancellation
//! - SPSC queue operations
//! - Codec encode/decode
//! - Hash map lookups
//!
//! Usage:
//!   zig build bench              # Run all benchmarks
//!   zig build bench -- --quick   # Quick mode (fewer iterations)

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const MemoryPools = @import("../core/memory_pool.zig").MemoryPools;
const MatchingEngine = @import("../core/matching_engine.zig").MatchingEngine;
const OutputBuffer = @import("../core/order_book.zig").OutputBuffer;
const SpscQueue = @import("../collections/spsc_queue.zig").SpscQueue;
const binary_codec = @import("../protocol/binary_codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");

// ============================================================================
// Configuration
// ============================================================================

const BenchConfig = struct {
    warmup_iterations: usize = 10_000,
    bench_iterations: usize = 1_000_000,
    quick_mode: bool = false,

    fn effective_iterations(self: BenchConfig) usize {
        return if (self.quick_mode) self.bench_iterations / 10 else self.bench_iterations;
    }

    fn effective_warmup(self: BenchConfig) usize {
        return if (self.quick_mode) self.warmup_iterations / 10 else self.warmup_iterations;
    }
};

var config = BenchConfig{};

// ============================================================================
// Benchmark Utilities
// ============================================================================

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

fn formatThroughput(ops_per_sec: u64) struct { value: f64, unit: []const u8 } {
    if (ops_per_sec < 1_000) {
        return .{ .value = @floatFromInt(ops_per_sec), .unit = "ops/s" };
    } else if (ops_per_sec < 1_000_000) {
        return .{ .value = @as(f64, @floatFromInt(ops_per_sec)) / 1_000.0, .unit = "K ops/s" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(ops_per_sec)) / 1_000_000.0, .unit = "M ops/s" };
    }
}

fn printResult(name: []const u8, total_ns: u64, iterations: usize) void {
    const per_op = total_ns / iterations;
    const ops_per_sec = if (per_op > 0) 1_000_000_000 / per_op else 0;
    const latency = formatNanos(per_op);
    const throughput = formatThroughput(ops_per_sec);

    std.debug.print("  {s:<24} {d:>8.2} {s:<3}  ({d:>6.2} {s})\n", .{
        name,
        latency.value,
        latency.unit,
        throughput.value,
        throughput.unit,
    });
}

fn printResultWithStats(name: []const u8, latencies: []u64) void {
    if (latencies.len == 0) return;

    // Sort for percentiles
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));

    const p50_idx = latencies.len / 2;
    const p99_idx = latencies.len * 99 / 100;
    const p999_idx = latencies.len * 999 / 1000;

    const p50 = latencies[p50_idx];
    const p99 = latencies[p99_idx];
    const p999 = latencies[@min(p999_idx, latencies.len - 1)];

    // Calculate average
    var sum: u64 = 0;
    for (latencies) |l| {
        sum += l;
    }
    const avg = sum / latencies.len;

    std.debug.print("  {s:<24} avg={d}ns  p50={d}ns  p99={d}ns  p99.9={d}ns\n", .{
        name,
        avg,
        p50,
        p99,
        p999,
    });
}

// ============================================================================
// Core Benchmarks
// ============================================================================

fn benchOrderInsertion(allocator: std.mem.Allocator) !void {
    const iterations = config.effective_iterations();
    const warmup = config.effective_warmup();

    var pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    var engine = try allocator.create(MatchingEngine);
    defer {
        engine.deinit();
        allocator.destroy(engine);
    }
    engine.initInPlace(pools);

    var output = OutputBuffer.init();

    // Pre-allocate test orders (non-matching prices to avoid trade overhead)
    const orders = try allocator.alloc(msg.InputMsg, iterations);
    defer allocator.free(orders);

    for (orders, 0..) |*order, i| {
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
    for (0..warmup) |i| {
        engine.processMessage(&orders[i], 1, &output);
        output.clear();
    }

    // Reset for actual benchmark
    engine.handleFlush(&output);
    output.clear();

    // Benchmark
    var timer = try std.time.Timer.start();

    for (orders) |*order| {
        engine.processMessage(order, 1, &output);
        output.clear();
    }

    const elapsed = timer.read();
    printResult("Order Insertion", elapsed, iterations);
}

fn benchOrderMatching(allocator: std.mem.Allocator) !void {
    const iterations = config.effective_iterations() / 10; // Matching is slower
    const warmup = config.effective_warmup() / 10;

    var pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    var engine = try allocator.create(MatchingEngine);
    defer {
        engine.deinit();
        allocator.destroy(engine);
    }
    engine.initInPlace(pools);

    var output = OutputBuffer.init();

    // Pre-allocate crossing orders
    const buy_orders = try allocator.alloc(msg.InputMsg, iterations);
    defer allocator.free(buy_orders);

    const sell_orders = try allocator.alloc(msg.InputMsg, iterations);
    defer allocator.free(sell_orders);

    for (0..iterations) |i| {
        buy_orders[i] = msg.InputMsg.newOrder(.{
            .user_id = 1,
            .user_order_id = @intCast(i * 2),
            .price = 100,
            .quantity = 100,
            .side = .buy,
            .symbol = msg.makeSymbol("MATCH"),
        });

        sell_orders[i] = msg.InputMsg.newOrder(.{
            .user_id = 2,
            .user_order_id = @intCast(i * 2 + 1),
            .price = 100, // Same price = immediate match
            .quantity = 100,
            .side = .sell,
            .symbol = msg.makeSymbol("MATCH"),
        });
    }

    // Warmup
    for (0..warmup) |i| {
        engine.processMessage(&buy_orders[i], 1, &output);
        output.clear();
        engine.processMessage(&sell_orders[i], 2, &output);
        output.clear();
    }

    // Reset
    engine.handleFlush(&output);
    output.clear();

    // Benchmark - insert buy, then sell (which triggers match)
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        engine.processMessage(&buy_orders[i], 1, &output);
        output.clear();
        engine.processMessage(&sell_orders[i], 2, &output);
        output.clear();
    }

    const elapsed = timer.read();
    // Each iteration is 2 orders + 1 trade
    printResult("Order Matching (pair)", elapsed, iterations);
}

fn benchOrderCancel(allocator: std.mem.Allocator) !void {
    const iterations = config.effective_iterations() / 2;

    var pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    var engine = try allocator.create(MatchingEngine);
    defer {
        engine.deinit();
        allocator.destroy(engine);
    }
    engine.initInPlace(pools);

    var output = OutputBuffer.init();

    // Insert orders first
    for (0..iterations) |i| {
        const order = msg.InputMsg.newOrder(.{
            .user_id = 1,
            .user_order_id = @intCast(i),
            .price = @intCast(100 + (i % 100)), // Spread across price levels
            .quantity = 100,
            .side = .buy,
            .symbol = msg.makeSymbol("CANCL"),
        });
        engine.processMessage(&order, 1, &output);
        output.clear();
    }

    // Pre-allocate cancel messages
    const cancels = try allocator.alloc(msg.InputMsg, iterations);
    defer allocator.free(cancels);

    for (cancels, 0..) |*cancel, i| {
        cancel.* = msg.InputMsg.cancel(.{
            .user_id = 1,
            .user_order_id = @intCast(i),
            .symbol = msg.makeSymbol("CANCL"),
        });
    }

    // Benchmark cancels
    var timer = try std.time.Timer.start();

    for (cancels) |*cancel| {
        engine.processMessage(cancel, 1, &output);
        output.clear();
    }

    const elapsed = timer.read();
    printResult("Order Cancel", elapsed, iterations);
}

// ============================================================================
// Collections Benchmarks
// ============================================================================

fn benchSpscQueue() !void {
    const iterations = config.effective_iterations();
    const warmup = config.effective_warmup();

    var queue = SpscQueue(u64, 65536).init();

    // Warmup
    for (0..warmup) |i| {
        _ = queue.push(i);
        _ = queue.pop();
    }

    // Benchmark push
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        _ = queue.push(i);
    }

    const push_elapsed = timer.read();

    // Benchmark pop
    timer.reset();

    for (0..iterations) |_| {
        _ = queue.pop();
    }

    const pop_elapsed = timer.read();

    printResult("SPSC Push", push_elapsed, iterations);
    printResult("SPSC Pop", pop_elapsed, iterations);

    // Benchmark round-trip
    timer.reset();

    for (0..iterations) |i| {
        _ = queue.push(i);
        _ = queue.pop();
    }

    const roundtrip_elapsed = timer.read();
    printResult("SPSC Roundtrip", roundtrip_elapsed, iterations);
}

// ============================================================================
// Codec Benchmarks
// ============================================================================

fn benchBinaryCodec() !void {
    const iterations = config.effective_iterations();

    var encode_buf: [256]u8 = undefined;
    var total_encode_ns: u64 = 0;
    var total_decode_ns: u64 = 0;

    const test_order = msg.InputMsg.newOrder(.{
        .user_id = 12345,
        .user_order_id = 67890,
        .price = 10050,
        .quantity = 1000,
        .side = .buy,
        .symbol = msg.makeSymbol("AAPL"),
    });

    // Benchmark encode
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        _ = binary_codec.encodeInput(&test_order, &encode_buf) catch continue;
    }

    total_encode_ns = timer.read();

    // Encode once for decode benchmark
    const encoded_len = binary_codec.encodeInput(&test_order, &encode_buf) catch 0;
    const encoded = encode_buf[0..encoded_len];

    // Benchmark decode
    timer.reset();

    for (0..iterations) |_| {
        _ = binary_codec.decodeInput(encoded) catch continue;
    }

    total_decode_ns = timer.read();

    printResult("Binary Encode", total_encode_ns, iterations);
    printResult("Binary Decode", total_decode_ns, iterations);
}

fn benchCsvCodec() !void {
    const iterations = config.effective_iterations();

    var encode_buf: [256]u8 = undefined;
    var total_encode_ns: u64 = 0;
    var total_decode_ns: u64 = 0;

    const test_order = msg.InputMsg.newOrder(.{
        .user_id = 12345,
        .user_order_id = 67890,
        .price = 10050,
        .quantity = 1000,
        .side = .buy,
        .symbol = msg.makeSymbol("AAPL"),
    });

    // Benchmark encode
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        _ = csv_codec.encodeInput(&test_order, &encode_buf) catch continue;
    }

    total_encode_ns = timer.read();

    // Encode once for decode benchmark
    const encoded_len = csv_codec.encodeInput(&test_order, &encode_buf) catch 0;
    const encoded = encode_buf[0..encoded_len];

    // Benchmark decode
    timer.reset();

    for (0..iterations) |_| {
        _ = csv_codec.decodeInput(encoded) catch continue;
    }

    total_decode_ns = timer.read();

    printResult("CSV Encode", total_encode_ns, iterations);
    printResult("CSV Decode", total_decode_ns, iterations);
}

// ============================================================================
// Latency Distribution Benchmark
// ============================================================================

fn benchLatencyDistribution(allocator: std.mem.Allocator) !void {
    const iterations: usize = if (config.quick_mode) 10_000 else 100_000;

    var pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    var engine = try allocator.create(MatchingEngine);
    defer {
        engine.deinit();
        allocator.destroy(engine);
    }
    engine.initInPlace(pools);

    var output = OutputBuffer.init();

    // Collect latencies
    const latencies = try allocator.alloc(u64, iterations);
    defer allocator.free(latencies);

    for (0..iterations) |i| {
        const order = msg.InputMsg.newOrder(.{
            .user_id = 1,
            .user_order_id = @intCast(i),
            .price = 100,
            .quantity = 100,
            .side = .buy,
            .symbol = msg.makeSymbol("LATCY"),
        });

        var timer = try std.time.Timer.start();
        engine.processMessage(&order, 1, &output);
        latencies[i] = timer.read();
        output.clear();
    }

    printResultWithStats("Latency Distribution", latencies);
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments
    var args = std.process.args();
    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quick") or std.mem.eql(u8, arg, "-q")) {
            config.quick_mode = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Zig Matching Engine Benchmarks
                \\
                \\Usage: benchmark [OPTIONS]
                \\
                \\Options:
                \\  -q, --quick   Quick mode (10x fewer iterations)
                \\  -h, --help    Show this help
                \\
            , .{});
            return;
        }
    }

    const mode_str = if (config.quick_mode) "QUICK" else "FULL";

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         Zig Matching Engine Benchmarks ({s})            ║\n", .{mode_str});
    std.debug.print("╠═══════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Iterations: {d:<10} Warmup: {d:<10}              ║\n", .{
        config.effective_iterations(),
        config.effective_warmup(),
    });
    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Core benchmarks
    std.debug.print("── Core Engine ──────────────────────────────────────────────\n", .{});
    try benchOrderInsertion(allocator);
    try benchOrderMatching(allocator);
    try benchOrderCancel(allocator);
    std.debug.print("\n", .{});

    // Collections benchmarks
    std.debug.print("── Collections ──────────────────────────────────────────────\n", .{});
    try benchSpscQueue();
    std.debug.print("\n", .{});

    // Codec benchmarks
    std.debug.print("── Protocol Codecs ──────────────────────────────────────────\n", .{});
    try benchBinaryCodec();
    try benchCsvCodec();
    std.debug.print("\n", .{});

    // Latency distribution
    std.debug.print("── Latency Distribution ─────────────────────────────────────\n", .{});
    try benchLatencyDistribution(allocator);
    std.debug.print("\n", .{});

    std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("                     Benchmarks Complete\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════\n\n", .{});
}
