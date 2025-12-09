//! Build configuration for the Zig Matching Engine.
//!
//! Build targets:
//! - `zig build`       - Build the matching engine executable
//! - `zig build run`   - Build and run the engine
//! - `zig build test`  - Run all unit tests
//! - `zig build bench` - Run performance benchmarks
//! - `zig build check` - Fast type-check without codegen
//! - `zig build client`- Build the test client tool
//! - `zig build docs`  - Generate HTML documentation

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
    const test_step = b.step("test", "Run all unit tests");

    // Main test through main.zig (tests all imported modules)
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.linkLibC();
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Standalone module tests (for modules that can be tested independently)
    const standalone_tests = [_][]const u8{
        // Protocol layer
        "src/protocol/message_types.zig",
        "src/protocol/codec.zig",
        "src/protocol/binary_codec.zig",
        "src/protocol/csv_codec.zig",
        "src/protocol/fix_codec.zig",

        // Collections
        "src/collections/spsc_queue.zig",
        "src/collections/bounded_channel.zig",

        // Transport
        "src/transport/config.zig",
        "src/transport/net_utils.zig",
        "src/transport/tcp_client.zig",
        "src/transport/multicast.zig",
    };

    for (standalone_tests) |path| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        unit_test.linkLibC();
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
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
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

    const run_client = b.addRunArtifact(client_exe);
    if (b.args) |args| {
        run_client.addArgs(args);
    }
    const client_step = b.step("client", "Build and run the test client");
    client_step.dependOn(&run_client.step);

    // === Documentation ===
    // Generate HTML documentation from source comments
    const docs_step = b.step("docs", "Generate HTML documentation");

    // Use Zig's built-in documentation generator
    const docs_obj = b.addObject(.{
        .name = "matching_engine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    docs_obj.linkLibC();

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    // === Release Build ===
    const release_step = b.step("release", "Build optimized release binary");

    const release_exe = b.addExecutable(.{
        .name = "matching_engine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    release_exe.linkLibC();

    // Strip debug symbols for smaller binary
    release_exe.root_module.strip = true;

    const install_release = b.addInstallArtifact(release_exe, .{});
    release_step.dependOn(&install_release.step);

    // === Clean (informational) ===
    // Note: `zig build` doesn't have a built-in clean, but users can use:
    // rm -rf zig-out .zig-cache
}
