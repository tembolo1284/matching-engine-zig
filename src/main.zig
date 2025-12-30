//! Zig Matching Engine - Main Entry Point
//!
//! A high-performance order matching engine written in Zig.
//!
//! Features:
//! - Single-threaded or dual-processor modes
//! - TCP/UDP/Multicast transport
//! - CSV, Binary, and FIX protocol support
//! - Cross-platform (Linux/macOS)
const std = @import("std");
const builtin = @import("builtin");
const msg = @import("protocol/message_types.zig");
const MemoryPools = @import("core/memory_pool.zig").MemoryPools;
const MatchingEngine = @import("core/matching_engine.zig").MatchingEngine;
const Server = @import("transport/server.zig").Server;
const ThreadedServer = @import("threading/threaded_server.zig").ThreadedServer;
const cfg = @import("transport/config.zig");

pub const VERSION = "0.1.0";
pub const BUILD_MODE = @tagName(builtin.mode);

// ============================================================================
// Platform Detection
// ============================================================================
const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

// ============================================================================
// Signal Handling
// ============================================================================
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

fn setupSignalHandlers() void {
    const sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    const sigterm_action = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    const sigpipe_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    if (is_darwin) {
        // macOS: sigaction returns void
        std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null) catch {};
        std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null) catch {};
        std.posix.sigaction(std.posix.SIG.PIPE, &sigpipe_action, null) catch {};
    } else {
        // Linux: sigaction returns error union
        std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null) catch {};
        std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null) catch {};
        std.posix.sigaction(std.posix.SIG.PIPE, &sigpipe_action, null) catch {};
    }
}

// ============================================================================
// Configuration / Options
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

    var args = std.process.args();
    _ = args.skip();

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

    // Check environment variable
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
        \\A high-performance order matching engine.
        \\
        \\Usage: matching_engine [OPTIONS]
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\  -t, --threaded   Run in dual-processor mode (recommended)
        \\  --verbose        Enable verbose logging
        \\
        \\Environment Variables:
        \\  ENGINE_THREADED=true        Enable dual-processor mode
        \\  ENGINE_TCP_ENABLED=true     Enable TCP transport
        \\  ENGINE_TCP_PORT=1234        TCP listen port
        \\  ENGINE_UDP_ENABLED=true     Enable UDP transport
        \\  ENGINE_UDP_PORT=1235        UDP listen port
        \\  ENGINE_MCAST_ENABLED=true   Enable multicast market data
        \\  ENGINE_MCAST_GROUP=239.255.0.1  Multicast group
        \\  ENGINE_MCAST_PORT=1236      Multicast port
        \\  ENGINE_BINARY_PROTOCOL=false  Use binary protocol (vs CSV)
        \\
        \\Examples:
        \\  matching_engine                    # Single-threaded, default config
        \\  matching_engine -t                 # Dual-processor mode
        \\  ENGINE_TCP_PORT=5000 matching_engine  # Custom TCP port
        \\
    ;
    std.debug.print(usage, .{ VERSION, BUILD_MODE });
}

fn printVersion() void {
    std.debug.print("Zig Matching Engine v{s} ({s})\n", .{ VERSION, BUILD_MODE });
    std.debug.print("Platform: {s} {s}\n", .{
        if (is_linux) "Linux" else if (is_darwin) "macOS" else @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
}

// ============================================================================
// Startup Validation
// ============================================================================
fn validateConfig(config: *const cfg.Config) !void {
    config.validate() catch |err| {
        std.log.err("Configuration error: {any}", .{err});
        return err;
    };

    if (!config.tcp_enabled and !config.udp_enabled) {
        std.log.err("At least one transport (TCP or UDP) must be enabled", .{});
        return error.NoTransportEnabled;
    }
}

fn validateSystem() void {
    if (!is_linux and !is_darwin) {
        std.log.warn("This engine is optimized for Linux/macOS. Performance may vary on {s}.", .{
            @tagName(builtin.os.tag),
        });
    }

    const platform_str = if (is_linux) "Linux" else if (is_darwin) "macOS" else @tagName(builtin.os.tag);
    std.log.info("System: {s} {s}", .{
        platform_str,
        @tagName(builtin.cpu.arch),
    });
}

// ============================================================================
// Graceful Shutdown
// ============================================================================

/// Number of poll cycles to allow for draining pending messages.
const SHUTDOWN_DRAIN_CYCLES: usize = 10;

/// Timeout per drain cycle in milliseconds.
const SHUTDOWN_DRAIN_TIMEOUT_MS: i32 = 50;

// ============================================================================
// Server Runners
// ============================================================================
fn runSingleThreaded(allocator: std.mem.Allocator, config: cfg.Config, verbose: bool) !void {
    if (verbose) std.log.info("Initializing single-threaded mode...", .{});

    // Heap-allocate memory pools (large structure)
    const pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    if (verbose) std.log.info("Memory pools initialized", .{});

    // Heap-allocate matching engine (contains large hash tables)
    const engine = try allocator.create(MatchingEngine);
    defer {
        engine.deinit();
        allocator.destroy(engine);
    }
    engine.initInPlace(pools);

    if (verbose) std.log.info("Matching engine initialized", .{});

    // Heap-allocate server (contains sizable buffers)
    const server = try allocator.create(Server);
    defer {
        server.deinit();
        allocator.destroy(server);
    }
    server.initInPlace(allocator, engine, config);

    if (verbose) std.log.info("Server initialized", .{});

    try server.start();
    printStartupBanner(config, false);

    // Main event loop
    while (!shutdown_requested.load(.acquire)) {
        server.pollOnce(100) catch |err| {
            std.log.err("Server error: {any}", .{err});
            if (err == error.NotStarted) break;
        };
    }

    // Graceful shutdown: drain pending messages
    std.log.info("Shutting down (draining pending messages)...", .{});
    for (0..SHUTDOWN_DRAIN_CYCLES) |_| {
        server.pollOnce(SHUTDOWN_DRAIN_TIMEOUT_MS) catch break;
    }

    server.stop();

    // Print final statistics
    const stats = server.getStats();
    std.log.info("Session complete: {} messages processed", .{stats.messages_processed});
}

fn runThreaded(allocator: std.mem.Allocator, config: cfg.Config, verbose: bool) !void {
    if (verbose) std.log.info("Initializing threaded mode...", .{});

    var server = try ThreadedServer.init(allocator, config);
    defer server.deinit();

    if (verbose) std.log.info("Threaded server initialized", .{});

    try server.start();
    printStartupBanner(config, true);

    // Main event loop
    while (!shutdown_requested.load(.acquire)) {
        server.pollOnce(100) catch |err| {
            std.log.err("Server error: {any}", .{err});
        };
    }

    // Graceful shutdown: drain pending messages
    std.log.info("Shutting down (draining pending messages)...", .{});
    for (0..SHUTDOWN_DRAIN_CYCLES) |_| {
        server.pollOnce(SHUTDOWN_DRAIN_TIMEOUT_MS) catch break;
    }

    // Print statistics before stopping
    printThreadedStats(server);

    server.stop();
}

fn printStartupBanner(config: cfg.Config, threaded: bool) void {
    const backend = if (is_linux) "epoll" else if (is_darwin) "kqueue" else "poll";

    std.log.info("", .{});
    std.log.info("╔════════════════════════════════════════════╗", .{});
    std.log.info("║     Zig Matching Engine v{s}             ║", .{VERSION});
    std.log.info("╠════════════════════════════════════════════╣", .{});

    if (config.tcp_enabled) {
        std.log.info("║  TCP:       {s}:{d:<5}                  ║", .{
            config.tcp_addr,
            config.tcp_port,
        });
    }

    if (config.udp_enabled) {
        std.log.info("║  UDP:       {s}:{d:<5}                  ║", .{
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

    const protocol_str = if (config.use_binary_protocol) "Binary" else "CSV";
    std.log.info("║  Protocol:  {s:<30} ║", .{protocol_str});
    std.log.info("║  I/O:       {s:<30} ║", .{backend});

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

fn printThreadedStats(server: *ThreadedServer) void {
    const stats = server.getStats();

    std.log.info("", .{});
    std.log.info("═══════════════ Session Statistics ═══════════════", .{});
    std.log.info("  Messages routed:    Proc0={d}, Proc1={d}", .{
        stats.messages_routed[0],
        stats.messages_routed[1],
    });
    std.log.info("  Total processed:    {d}", .{stats.totalProcessed()});
    std.log.info("  Outputs dispatched: {d}", .{stats.outputs_dispatched});
    std.log.info("  Messages dropped:   {d}", .{stats.messages_dropped});
    std.log.info("  Disconnect cancels: {d}", .{stats.disconnect_cancels});

    for (0..2) |i| {
        const ps = stats.processor_stats[i];
        std.log.info("  Processor {d}:", .{i});
        std.log.info("    Messages:    {d}", .{ps.messages_processed});
        std.log.info("    Outputs:     {d}", .{ps.outputs_generated});
        std.log.info("    Backpressure:{d}", .{ps.output_backpressure_count});

        if (ps.messages_processed > 0) {
            const total_time: i128 = ps.total_processing_time_ns;
            const msg_count: i128 = @intCast(ps.messages_processed);
            const avg_ns = @divTrunc(total_time, msg_count);
            std.log.info("    Avg latency: {d}ns", .{avg_ns});
        }
    }

    std.log.info("═══════════════════════════════════════════════════", .{});
    std.log.info("", .{});
}

// ============================================================================
// Main Entry Point
// ============================================================================
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const opts = parseOptions(allocator);

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

    setupSignalHandlers();
    validateSystem();
    try validateConfig(&opts.config);

    if (opts.verbose) {
        opts.config.log();
    }

    switch (opts.mode) {
        .single_threaded => try runSingleThreaded(allocator, opts.config, opts.verbose),
        .threaded => try runThreaded(allocator, opts.config, opts.verbose),
        else => unreachable,
    }

    std.log.info("Shutdown complete", .{});
}

// ============================================================================
// Tests
// ============================================================================
test "signal handler setup" {
    // Just verify it doesn't crash
    setupSignalHandlers();
}

test "option parsing defaults" {
    const opts = Options{
        .mode = .single_threaded,
        .config = cfg.Config{},
        .verbose = false,
    };

    try std.testing.expectEqual(RunMode.single_threaded, opts.mode);
    try std.testing.expect(!opts.verbose);
}
