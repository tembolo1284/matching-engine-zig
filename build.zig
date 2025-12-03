const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "matching_engine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the matching engine");
    run_step.dependOn(&run_cmd.step);

    // Unit tests for each module
    const test_targets = [_][]const u8{
        "src/protocol/message_types.zig",
        "src/protocol/codec.zig",
        "src/protocol/binary_codec.zig",
        "src/protocol/csv_codec.zig",
        "src/core/order.zig",
        "src/core/memory_pool.zig",
        "src/core/order_book.zig",
        "src/transport/tcp_server.zig",
        "src/transport/udp_server.zig",
        "src/transport/multicast.zig",
    };

    const test_step = b.step("test", "Run unit tests");
    
    for (test_targets) |test_file| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        const run_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_test.step);
    }
}
