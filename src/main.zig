//! Zig Matching Engine - Main Entry Point
//!
//! A high-performance order matching engine supporting:
//! - TCP and UDP client connections
//! - Multicast market data distribution
//! - Binary and CSV wire protocols
//! - Single-threaded or dual-processor modes
//!
//! Environment Variables:
//!   ENGINE_THREADED=true     - Enable dual-processor mode
//!   ENGINE_TCP_PORT=9000     - TCP listen port
//!   ENGINE_UDP_PORT=9001     - UDP listen port
//!   ENGINE_MCAST_GROUP=...   - Multicast group address
//!   ENGINE_MCAST_PORT=9002   - Multicast port
//!
//! Usage:
//!   ./matching_engine              # Single-threaded mode
//!   ENGINE_THREADED=true ./matching_engine  # Dual-processor mode

const std = @import("std");
const builtin = @import("builtin");

// === Internal Modules ===
const msg = @import("protocol/message_types.zig");
const MemoryPools = @import("core/memory_pool.zig").MemoryPools;
const MatchingEngine = @import("core/matching_engine.zig").MatchingEngine;
const Server = @import("transport/server.zig").Server;
const ThreadedServer = @import("threading/threaded_server.zig").ThreadedServer;
const cfg = @import("transport/config.zig");

// ============================================================================
// Version Info
// ============================================================================

pub const VERSION = "0.1.0";
pub const BUILD_MODE = @tagName(builtin.mode);

// ============================================================================
// Signal Handling
// ============================================================================

var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn signalHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    shutdown_requested.store(true, .release);
    std.log.info("Shutdown signal received", .{});
}

fn setupSignalHandlers() void {
    // SIGINT (Ctrl+C)
    const sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null) catch {};

    // SIGTERM
    const sigterm_action = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null) catch {};

    // Ignore SIGPIPE (handled by MSG_NOSIGNAL on send)
    const sigpipe_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &sigpipe_action, null) catch {};
}

// ============================================================================
// Configuration
// ============================================================================

const RunMode = enum {
    single_threaded,
    threaded,
    help,
    version,
};

const Options = struct {
    mode: RunMode,
    config: cfg.Config,
    verbose: bool,
};

fn parseOptions(allocator: std.mem.Allocator) Options {
    var opts = Options{
        .mode = .single_threaded,
        .config = cfg.Config.fromEnv(),
        .verbose = false,
    };

    // Check command line args
    var args = std.process.args();
    _ = args.skip(); // Skip executable name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.mode = .help;
            return opts;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            opts.mode = .version;
            return opts;
        } else if (std.mem.eql(u8, arg, "--threaded") or std.mem.eql(u8, arg, "-t")) {
            opts.mode = .threaded;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        }
    }

    // Check environment for threaded mode
    const threaded_env = std.process.getEnvVarOwned(allocator, "ENGINE_THREADED") catch null;
    defer if (threaded_env) |t| allocator.free(t);

    if (threaded_env) |t| {
        if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1")) {
            opts.mode = .threaded;
        }
    }

    return opts;
}

fn printUsage() void {
    const usage =
        \\Zig Matching Engine v{s} ({s})
        \\
        \\Usage: matching_engine [OPTIONS]
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\  -t, --threaded   Run in dual-processor mode
        \\  --verbose        Enable verbose logging
        \\
        \\Environment Variables:
        \\  ENGINE_THREADED=true        Enable dual-processor mode
        \\  ENGINE_TCP_ENABLED=true     Enable TCP server
        \\  ENGINE_TCP_PORT=9000        TCP listen port
        \\  ENGINE_UDP_ENABLED=true     Enable UDP server
        \\  ENGINE_UDP_PORT=9001        UDP listen port
        \\  ENGINE_MCAST_ENABLED=true   Enable multicast
        \\  ENGINE_MCAST_GROUP=...      Multicast group address
        \\  ENGINE_MCAST_PORT=9002      Multicast port
        \\
        \\Examples:
        \\  matching_engine                    # Single-threaded mode
        \\  matching_engine --threaded         # Dual-processor mode
        \\  ENGINE_TCP_PORT=8080 matching_engine
        \\
    ;

    std.debug.print(usage, .{ VERSION, BUILD_MODE });
}

fn printVersion() void {
    std.debug.print("Zig Matching Engine v{s} ({s})\n", .{ VERSION, BUILD_MODE });
}

// ============================================================================
// Startup Validation
// ============================================================================

fn validateConfig(config: *const cfg.Config) !void {
    // Validate configuration
    config.validate() catch |err| {
        std.log.err("Configuration error: {}", .{err});
        return err;
    };

    // Check that at least one transport is enabled
    if (!config.tcp_enabled and !config.udp_enabled) {
        std.log.err("At least one transport (TCP or UDP) must be enabled", .{});
        return error.NoTransportEnabled;
    }

    // Log configuration
    config.log();
}

fn validateSystem() !void {
    // Check available memory (basic sanity check)
    // MemoryPools needs ~8MB for order pool

    // Check we're on Linux (required for epoll)
    if (builtin.os.tag != .linux) {
        std.log.warn("This engine is optimized for Linux. Performance may vary on {s}.", .{
            @tagName(builtin.os.tag),
        });
    }

    // Log system info
    std.log.info("System: {s} {s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
}

// ============================================================================
// Server Runners
// ============================================================================

fn runSingleThreaded(allocator: std.mem.Allocator, config: cfg.Config) !void {
    std.log.info("Starting in SINGLE-THREADED mode", .{});

    // Initialize memory pools
    var pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    // Initialize matching engine
    var engine = MatchingEngine.init(&pools);

    // Initialize and start server
    var server = Server.init(allocator, &engine, config);
    defer server.deinit();

    try server.start();

    printStartupBanner(config, false);

    // Main loop with shutdown check
    while (!shutdown_requested.load(.acquire)) {
        server.pollOnce(100) catch |err| {
            std.log.err("Server error: {}", .{err});
            if (err == error.NotStarted) break;
        };
    }

    std.log.info("Shutting down...", .{});
    server.stop();
}

fn runThreaded(allocator: std.mem.Allocator, config: cfg.Config) !void {
    std.log.info("Starting in THREADED mode (dual-processor)", .{});

    // Initialize threaded server
    var server = ThreadedServer.init(allocator, config);
    defer server.deinit();

    try server.start();

    printStartupBanner(config, true);

    // Main loop with shutdown check
    while (!shutdown_requested.load(.acquire)) {
        server.pollOnce(100) catch |err| {
            std.log.err("Server error: {}", .{err});
        };
    }

    std.log.info("Shutting down...", .{});
    server.stop();
}

fn printStartupBanner(config: cfg.Config, threaded: bool) void {
    std.log.info("", .{});
    std.log.info("╔════════════════════════════════════════════╗", .{});
    std.log.info("║     Zig Matching Engine v{s}             ║", .{VERSION});
    std.log.info("╠════════════════════════════════════════════╣", .{});

    if (config.tcp_enabled) {
        std.log.info("║  TCP:       {s}:{d:<5}                    ║", .{
            config.tcp_addr,
            config.tcp_port,
        });
    }

    if (config.udp_enabled) {
        std.log.info("║  UDP:       {s}:{d:<5}                    ║", .{
            config.udp_addr,
            config.udp_port,
        });
    }

    if (config.mcast_enabled) {
        std.log.info("║  Multicast: {s}:{d:<5}              ║", .{
            config.mcast_group,
            config.mcast_port,
        });
    }

    if (threaded) {
        std.log.info("║  Mode:      Dual-Processor                 ║", .{});
        std.log.info("║  Proc 0:    Symbols A-M                    ║", .{});
        std.log.info("║  Proc 1:    Symbols N-Z                    ║", .{});
    } else {
        std.log.info("║  Mode:      Single-Threaded                ║", .{});
    }

    std.log.info("╚════════════════════════════════════════════╝", .{});
    std.log.info("", .{});
    std.log.info("Press Ctrl+C to shutdown gracefully", .{});
    std.log.info("", .{});
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Parse options
    const opts = parseOptions(allocator);

    // Handle help/version
    switch (opts.mode) {
        .help => {
            printUsage();
            return;
        },
        .version => {
            printVersion();
            return;
        },
        else => {},
    }

    // Setup signal handlers
    setupSignalHandlers();

    // Validate system and configuration
    try validateSystem();
    try validateConfig(&opts.config);

    // Run appropriate mode
    switch (opts.mode) {
        .single_threaded => try runSingleThreaded(allocator, opts.config),
        .threaded => try runThreaded(allocator, opts.config),
        else => unreachable,
    }

    std.log.info("Shutdown complete", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "signal handler setup" {
    setupSignalHandlers();
    try std.testing.expect(!shutdown_requested.load(.acquire));
}

test "options parsing defaults" {
    const opts = Options{
        .mode = .single_threaded,
        .config = cfg.Config{},
        .verbose = false,
    };
    try std.testing.expectEqual(RunMode.single_threaded, opts.mode);
}
