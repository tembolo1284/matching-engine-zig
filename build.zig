//! Build configuration for the Zig Matching Engine.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // Main Executable
    // =========================================================================
    const exe = b.addExecutable(.{
        .name = "matching_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
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

    // =========================================================================
    // Unit Tests
    // =========================================================================
    const test_step = b.step("test", "Run all unit tests");

    // Main test through main.zig
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Standalone module tests
    const standalone_tests = [_][]const u8{
        "src/protocol/message_types.zig",
        "src/collections/spsc_queue.zig",
        "src/collections/bounded_channel.zig",
        "src/transport/config.zig",
        "src/transport/net_utils.zig",
    };

    for (standalone_tests) |path| {
        const unit_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_test.step);
    }

    // =========================================================================
    // Fast Type-Check
    // =========================================================================
    const check_exe = b.addExecutable(.{
        .name = "matching_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const check_step = b.step("check", "Type-check without code generation");
    check_step.dependOn(&check_exe.step);

    // =========================================================================
    // Client Tool
    // =========================================================================
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    client_mod.addImport("message_types", b.createModule(.{
        .root_source_file = b.path("src/protocol/message_types.zig"),
        .target = target,
        .optimize = optimize,
    }));
    client_mod.addImport("codec", b.createModule(.{
        .root_source_file = b.path("src/protocol/codec.zig"),
        .target = target,
        .optimize = optimize,
    }));
    client_mod.addImport("csv_codec", b.createModule(.{
        .root_source_file = b.path("src/protocol/csv_codec.zig"),
        .target = target,
        .optimize = optimize,
    }));
    client_mod.addImport("binary_codec", b.createModule(.{
        .root_source_file = b.path("src/protocol/binary_codec.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const client_exe = b.addExecutable(.{
        .name = "engine_client",
        .root_module = client_mod,
    });
    b.installArtifact(client_exe);

    const run_client = b.addRunArtifact(client_exe);
    if (b.args) |args| {
        run_client.addArgs(args);
    }
    const client_step = b.step("client", "Build and run the test client");
    client_step.dependOn(&run_client.step);

    // =========================================================================
    // Documentation
    // =========================================================================
    const docs_step = b.step("docs", "Generate HTML documentation");
    const docs_obj = b.addObject(.{
        .name = "matching_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    // =========================================================================
    // Release Build
    // =========================================================================
    const release_step = b.step("release", "Build optimized release binary");
    const release_exe = b.addExecutable(.{
        .name = "matching_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .strip = true,
        }),
    });
    const install_release = b.addInstallArtifact(release_exe, .{});
    release_step.dependOn(&install_release.step);
}
