//! Zig Matching Engine - Main Entry Point

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
// Signal Handling
// ============================================================================

var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn signalHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    shutdown_requested.store(true, .release);
    std.log.info("Shutdown signal received", .{});
}

fn setupSignalHandlers() void {
    const sigint_action = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null) catch {};

    const sigterm_action = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null) catch {};

    const sigpipe_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &sigpipe_action, null) catch {};
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
        \\  ENGINE_TCP_PORT=1234        TCP listen port
        \\  ENGINE_UDP_PORT=1235        UDP listen port
        \\  ENGINE_MCAST_PORT=1236      Multicast port
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
    config.validate() catch |err| {
        std.log.err("Configuration error: {any}", .{err});
        return err;
    };

    if (!config.tcp_enabled and !config.udp_enabled) {
        std.log.err("At least one transport (TCP or UDP) must be enabled", .{});
        return error.NoTransportEnabled;
    }

    config.log();
}

fn validateSystem() !void {
    if (builtin.os.tag != .linux) {
        std.log.warn("This engine is optimized for Linux. Performance may vary on {s}.", .{
            @tagName(builtin.os.tag),
        });
    }

    std.log.info("System: {s} {s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
}

// ============================================================================
// Server Runners
// ============================================================================

fn runSingleThreaded(allocator: std.mem.Allocator, config: cfg.Config) !void {
    std.debug.print("DEBUG 1: Entering runSingleThreaded\n", .{});
    std.log.info("Starting in SINGLE-THREADED mode", .{});

    std.debug.print("DEBUG 2: About to init MemoryPools\n", .{});
    // Heap-allocate memory pools: no large stack frames.
    const pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    std.debug.print("DEBUG 3: MemoryPools done, creating engine\n", .{});
    // Heap-allocate matching engine (large hash tables inside).
    const engine = try allocator.create(MatchingEngine);
    defer {
        engine.deinit();
        allocator.destroy(engine);
    }
    std.debug.print("DEBUG 4: Engine created, calling initInPlace\n", .{});
    engine.initInPlace(pools);

    std.debug.print("DEBUG 5: Engine initialized, creating server\n", .{});
    // Heap-allocate server (contains sizable buffers).
    const server = try allocator.create(Server);
    defer {
        server.deinit();
        allocator.destroy(server);
    }
    std.debug.print("DEBUG 6: Server created, calling initInPlace\n", .{});
    server.initInPlace(allocator, engine, config);

    std.debug.print("DEBUG 7: Starting server\n", .{});
    try server.start();

    printStartupBanner(config, false);

    while (!shutdown_requested.load(.acquire)) {
        server.pollOnce(100) catch |err| {
            std.log.err("Server error: {any}", .{err});
            if (err == error.NotStarted) break;
        };
    }

    std.log.info("Shutting down...", .{});
    server.stop();
}

fn runThreaded(allocator: std.mem.Allocator, config: cfg.Config) !void {
    std.log.info("Starting in THREADED mode (dual-processor)", .{});

    var server = try ThreadedServer.init(allocator, config);
    defer server.deinit();

    try server.start();

    printStartupBanner(config, true);

    while (!shutdown_requested.load(.acquire)) {
        server.pollOnce(100) catch |err| {
            std.log.err("Server error: {any}", .{err});
        };
    }

    std.log.info("Shutting down...", .{});

    printThreadedStats(server);
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
    const protocol_str = if (config.use_binary_protocol) "Binary" else "CSV";
    std.log.info("║  Protocol:  {s:<30} ║", .{protocol_str});
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
            const avg_ns = @divTrunc(ps.total_processing_time_ns, @as(i64, @intCast(ps.messages_processed)));
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
    std.debug.print("MAIN 1: Starting\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("MAIN 2: Parsing Options\n", .{});
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
    std.debug.print("MAIN 3: Setting up signal handlers\n", .{});
    setupSignalHandlers();
    std.debug.print("MAIN 4: Validating system\n", .{});
    try validateSystem();

    std.debug.print("MAIN 5: Validating config\n", .{});
    try validateConfig(&opts.config);

    std.debug.print("MAIN 6: About to enter switch for mode\n", .{});
    switch (opts.mode) {
        .single_threaded => {
            std.debug.print("MAIN 7: Calling runSingleThreaded\n", .{});
            try runSingleThreaded(allocator, opts.config);
        },
        .threaded => {
            std.debug.print("MAIN 7: Calling runThreaded\n", .{});
            try runThreaded(allocator, opts.config);
        },
        else => unreachable,
    }

    std.log.info("Shutdown complete", .{});
}

