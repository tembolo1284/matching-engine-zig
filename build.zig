//! Build configuration for the Zig Matching Engine.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // === Main Executable ===
    const exe = b.addExecutable(.{
        .name = "matching_engine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    // Test through main.zig to ensure all module paths resolve correctly
    const test_step = b.step("test", "Run all unit tests");

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.linkLibC();
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Also test standalone modules that don't have cross-module imports
    const standalone_tests = [_][]const u8{
        "src/protocol/message_types.zig",
        "src/protocol/codec.zig",
        "src/protocol/binary_codec.zig",
        "src/protocol/csv_codec.zig",
        "src/protocol/fix_codec.zig",
        "src/collections/spsc_queue.zig",
        "src/collections/bounded_channel.zig",
        "src/transport/config.zig",
        "src/transport/net_utils.zig",
    };

    for (standalone_tests) |path| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        const run_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_test.step);
    }

    // === Fast Type-Check ===
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
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_exe.linkLibC();
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
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
    const docs_step = b.step("docs", "Generate documentation");
    _ = docs_step;
}
