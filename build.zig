//! Build configuration for the Zig Matching Engine.
//!
//! Targets:
//!   zig build           - Build the matching engine
//!   zig build run       - Run the matching engine
//!   zig build test      - Run all unit tests
//!   zig build bench     - Run benchmarks
//!   zig build check     - Type-check without codegen (fast)
//!   zig build docs      - Generate documentation
//!
//! Options:
//!   -Doptimize=ReleaseFast  - Optimized build
//!   -Doptimize=ReleaseSafe  - Optimized with safety checks
//!   -Doptimize=Debug        - Debug build (default)

const std = @import("std");

pub fn build(b: *std.Build) void {
    // === Standard Options ===
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // === Main Executable ===
    const exe = b.addExecutable(.{
        .name = "matching_engine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link libc for POSIX functionality
    exe.linkLibC();

    b.installArtifact(exe);

    // === Run Command ===
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the matching engine");
    run_step.dependOn(&run_cmd.step);

    // === Unit Tests ===
    const test_step = b.step("test", "Run all unit tests");

    // Protocol layer
    addTest(b, test_step, "src/protocol/message_types.zig", target, optimize);
    addTest(b, test_step, "src/protocol/codec.zig", target, optimize);
    addTest(b, test_step, "src/protocol/binary_codec.zig", target, optimize);
    addTest(b, test_step, "src/protocol/csv_codec.zig", target, optimize);
    addTest(b, test_step, "src/protocol/fix_codec.zig", target, optimize);

    // Core layer
    addTest(b, test_step, "src/core/order.zig", target, optimize);
    addTest(b, test_step, "src/core/memory_pool.zig", target, optimize);
    addTest(b, test_step, "src/core/order_book.zig", target, optimize);
    addTest(b, test_step, "src/core/matching_engine.zig", target, optimize);

    // Collections
    addTest(b, test_step, "src/collections/spsc_queue.zig", target, optimize);
    addTest(b, test_step, "src/collections/bounded_channel.zig", target, optimize);

    // Transport layer
    addTest(b, test_step, "src/transport/config.zig", target, optimize);
    addTest(b, test_step, "src/transport/net_utils.zig", target, optimize);
    addTest(b, test_step, "src/transport/tcp_client.zig", target, optimize);
    addTest(b, test_step, "src/transport/tcp_server.zig", target, optimize);
    addTest(b, test_step, "src/transport/udp_server.zig", target, optimize);
    addTest(b, test_step, "src/transport/multicast.zig", target, optimize);

    // Threading layer
    addTest(b, test_step, "src/threading/processor.zig", target, optimize);
    addTest(b, test_step, "src/threading/threaded_server.zig", target, optimize);

    // === Fast Type-Check (no codegen) ===
    const check_exe = b.addExecutable(.{
        .name = "matching_engine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_exe.linkLibC();

    const check_step = b.step("check", "Type-check without code generation");
    check_step.dependOn(&check_exe.step);

    // === Benchmarks ===
    const bench_step = b.step("bench", "Run performance benchmarks");

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize benchmarks
    });
    bench_exe.linkLibC();

    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // === Client Tool ===
    const client_exe = b.addExecutable(.{
        .name = "engine_client",
        .root_source_file = b.path("src/tools/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_exe.linkLibC();
    b.installArtifact(client_exe);

    const client_step = b.step("client", "Build the test client");
    client_step.dependOn(&client_exe.step);

    // === Documentation ===
    // Note: Zig's autodoc is still evolving; this is a placeholder
    const docs_step = b.step("docs", "Generate documentation");
    _ = docs_step;

    // === Clean ===
    // Zig build system handles this automatically with `zig build --clean`
}

/// Helper to add a test target.
fn addTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const unit_test = b.addTest(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });

    const run_test = b.addRunArtifact(unit_test);
    test_step.dependOn(&run_test.step);
}
