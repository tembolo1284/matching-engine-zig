//! Zig Matching Engine - Main Entry Point
const std = @import("std");
const builtin = @import("builtin");
const msg = @import("protocol/message_types.zig");
const Order = @import("core/order.zig").Order;
const SpscQueue = @import("threading/spsc_queue.zig");
const InputEnvelopeQueue = SpscQueue.InputEnvelopeQueue;
const OutputEnvelopeQueue = SpscQueue.OutputEnvelopeQueue;
const ProcessorThread = @import("threading/processor.zig").ProcessorThread;
const ThreadedTcpServer = @import("transport/tcp_server_threaded.zig").ThreadedTcpServer;

pub const VERSION = "0.1.0";
pub const BUILD_MODE = @tagName(builtin.mode);

// ============================================================================
// Signal Handling
// ============================================================================
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

fn setupSignalHandlers() void {
    const empty_mask = std.mem.zeroes(std.posix.sigset_t);
    const handler = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &handler, null);
    std.posix.sigaction(std.posix.SIG.TERM, &handler, null);
    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
}

// ============================================================================
// Configuration
// ============================================================================
const Config = struct {
    tcp_port: u16,
    tcp_addr: []const u8,
    verbose: bool,

    pub fn fromEnv() Config {
        return Config{
            .tcp_port = getEnvU16("ENGINE_TCP_PORT", 1234),
            .tcp_addr = "0.0.0.0",
            .verbose = getEnvBool("ENGINE_VERBOSE", false),
        };
    }

    fn getEnvU16(name: []const u8, default: u16) u16 {
        const value = std.posix.getenv(name) orelse return default;
        return std.fmt.parseInt(u16, value, 10) catch default;
    }

    fn getEnvBool(name: []const u8, default: bool) bool {
        const value = std.posix.getenv(name) orelse return default;
        return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }
};

// ============================================================================
// Command Line Options
// ============================================================================
fn parseOptions() Config {
    var config = Config.fromEnv();
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            printVersion();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg[7..];
            config.tcp_port = std.fmt.parseInt(u16, port_str, 10) catch 1234;
        }
    }
    return config;
}

fn printUsage() void {
    std.debug.print(
        \\Zig Matching Engine v{s} ({s})
        \\
        \\Usage: matching_engine [OPTIONS]
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\  --verbose        Enable verbose logging
        \\  --port=PORT      TCP listen port (default: 1234)
        \\
    , .{ VERSION, BUILD_MODE });
}

fn printVersion() void {
    std.debug.print("Zig Matching Engine v{s} ({s})\n", .{ VERSION, BUILD_MODE });
}

// ============================================================================
// Startup Banner
// ============================================================================
fn printStartupBanner(config: *const Config) void {
    std.debug.print("\n", .{});
    std.debug.print("============================================\n", .{});
    std.debug.print("     Zig Matching Engine v{s}\n", .{VERSION});
    std.debug.print("============================================\n", .{});
    std.debug.print("  TCP:       {s}:{d}\n", .{ config.tcp_addr, config.tcp_port });
    std.debug.print("  Protocol:  Binary (0x4D) / FIX 4.2\n", .{});
    std.debug.print("  Mode:      Multi-Threaded (per-client)\n", .{});
    std.debug.print("============================================\n", .{});
    std.debug.print("Press Ctrl+C to shutdown gracefully\n", .{});
    std.debug.print("\n", .{});
}

fn printStats(proc_stats: anytype, server_stats: anytype) void {
    std.debug.print("\n", .{});
    std.debug.print("============ Session Statistics ============\n", .{});
    std.debug.print("  Messages processed: {d}\n", .{proc_stats.messages_processed});
    std.debug.print("  Trades generated:   {d}\n", .{proc_stats.trades_generated});
    std.debug.print("  Acks generated:     {d}\n", .{proc_stats.acks_generated});
    std.debug.print("  Connections:        {d} accepted, {d} closed\n", .{
        server_stats.connections_accepted,
        server_stats.connections_closed,
    });
    std.debug.print("  Messages routed:    {d}\n", .{server_stats.messages_routed});
    std.debug.print("  Route failures:     {d}\n", .{server_stats.route_failures});
    std.debug.print("=============================================\n", .{});
}

// ============================================================================
// Server Runner
// ============================================================================
fn runServer(allocator: std.mem.Allocator, config: *const Config) !void {
    // Create queues
    const input_queue = try allocator.create(InputEnvelopeQueue);
    defer allocator.destroy(input_queue);
    input_queue.* = InputEnvelopeQueue.init();

    const output_queue = try allocator.create(OutputEnvelopeQueue);
    defer allocator.destroy(output_queue);
    output_queue.* = OutputEnvelopeQueue.init();

    // Create processor thread
    const processor_thread = try allocator.create(ProcessorThread);
    defer allocator.destroy(processor_thread);
    processor_thread.initInPlace(input_queue, output_queue);

    // Create threaded TCP server
    var server = ThreadedTcpServer.init(allocator, input_queue, output_queue);

    // Start everything
    const address = try std.net.Address.parseIp4(config.tcp_addr, config.tcp_port);
    try server.start(address);
    try processor_thread.start();

    printStartupBanner(config);

    // Wait for shutdown
    while (!shutdown_requested.load(.acquire)) {
        std.Thread.sleep(100_000_000); // 100ms
    }

    std.debug.print("\nShutting down...\n", .{});

    // Stop processor first (it will drain input queue)
    processor_thread.stop();

    // Give router time to drain output queue
    std.Thread.sleep(500_000_000); // 500ms

    // Stop server (stops all client threads and router)
    server.stop();

    printStats(processor_thread.getStats(), server.getStats());
}

// ============================================================================
// Main Entry Point
// ============================================================================
pub fn main() !void {
    std.debug.print("Struct sizes:\n", .{});
    std.debug.print("  Order:           {d} bytes\n", .{@sizeOf(Order)});
    std.debug.print("  InputMsg:        {d} bytes\n", .{@sizeOf(msg.InputMsg)});
    std.debug.print("  OutputMsg:       {d} bytes\n", .{@sizeOf(msg.OutputMsg)});
    std.debug.print("  InputEnvelope:   {d} bytes\n", .{@sizeOf(SpscQueue.InputEnvelope)});
    std.debug.print("  OutputEnvelope:  {d} bytes\n", .{@sizeOf(SpscQueue.OutputEnvelope)});
    std.debug.print("\n", .{});

    const config = parseOptions();

    setupSignalHandlers();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try runServer(allocator, &config);

    std.debug.print("Shutdown complete\n", .{});
}
