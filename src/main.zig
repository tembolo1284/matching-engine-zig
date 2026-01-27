//! Zig Matching Engine - Main Entry Point
const std = @import("std");
const builtin = @import("builtin");
const msg = @import("protocol/message_types.zig");
const binary = @import("protocol/binary_codec.zig");
const fix = @import("protocol/fix_codec.zig");
const Order = @import("core/order.zig").Order;
const OrderBook = @import("core/order_book.zig").OrderBook;
const MatchingEngine = @import("core/matching_engine.zig").MatchingEngine;
const OutputBuffer = @import("core/output_buffer.zig").OutputBuffer;
const SpscQueue = @import("threading/spsc_queue.zig");
const InputEnvelopeQueue = SpscQueue.InputEnvelopeQueue;
const OutputEnvelopeQueue = SpscQueue.OutputEnvelopeQueue;
const Processor = @import("threading/processor.zig").Processor;
const ProcessorThread = @import("threading/processor.zig").ProcessorThread;
const SyncProcessor = @import("threading/processor.zig").SyncProcessor;
const framing = @import("transport/framing.zig");
const TcpConnection = @import("transport/tcp_connection.zig").TcpConnection;
const TcpServer = @import("transport/tcp_server.zig").TcpServer;

pub const VERSION = "0.1.0";
pub const BUILD_MODE = @tagName(builtin.mode);
const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

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
    threaded: bool,
    verbose: bool,

    pub fn fromEnv() Config {
        return Config{
            .tcp_port = getEnvU16("ENGINE_TCP_PORT", 1234),
            .tcp_addr = "0.0.0.0",
            .threaded = getEnvBool("ENGINE_THREADED", false),
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
const RunMode = enum {
    server,
    help,
    version,
};

const Options = struct {
    mode: RunMode,
    config: Config,
};

fn parseOptions() Options {
    var opts = Options{
        .mode = .server,
        .config = Config.fromEnv(),
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
            opts.config.threaded = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.config.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg[7..];
            opts.config.tcp_port = std.fmt.parseInt(u16, port_str, 10) catch 1234;
        }
    }
    return opts;
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
        \\  -t, --threaded   Run in threaded mode
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
    if (config.threaded) {
        std.debug.print("  Mode:      Threaded\n", .{});
    } else {
        std.debug.print("  Mode:      Single-Threaded\n", .{});
    }
    std.debug.print("============================================\n", .{});
    std.debug.print("Press Ctrl+C to shutdown gracefully\n", .{});
    std.debug.print("\n", .{});
}

fn printStats(stats: anytype) void {
    std.debug.print("\n", .{});
    std.debug.print("============ Session Statistics ============\n", .{});
    std.debug.print("  Messages processed: {d}\n", .{stats.messages_processed});
    std.debug.print("  Trades generated:   {d}\n", .{stats.trades_generated});
    std.debug.print("  Acks generated:     {d}\n", .{stats.acks_generated});
    std.debug.print("  Flushes:            {d}\n", .{stats.flush_count});
    std.debug.print("=============================================\n", .{});
}

// ============================================================================
// Server Runners
// ============================================================================
fn runSingleThreaded(allocator: std.mem.Allocator, config: *const Config) !void {
    if (config.verbose) std.debug.print("Initializing single-threaded mode...\n", .{});

    const server = try allocator.create(TcpServer);
    defer allocator.destroy(server);
    server.initInPlace();

    const input_queue = try allocator.create(InputEnvelopeQueue);
    defer allocator.destroy(input_queue);
    input_queue.* = InputEnvelopeQueue.init();

    const output_queue = try allocator.create(OutputEnvelopeQueue);
    defer allocator.destroy(output_queue);
    output_queue.* = OutputEnvelopeQueue.init();

    const processor = try allocator.create(Processor);
    defer allocator.destroy(processor);
    processor.initInPlace();

    server.setQueues(input_queue, output_queue);
    const address = try std.net.Address.parseIp4(config.tcp_addr, config.tcp_port);
    try server.start(address);

    if (config.verbose) std.debug.print("Server started on port {d}\n", .{config.tcp_port});
    printStartupBanner(config);

    processor.state = .running;

    // Simple round-robin: poll -> process -> poll -> process
    while (!shutdown_requested.load(.acquire)) {
        // 1. Handle network I/O (receive + send)
        _ = server.poll() catch |err| {
            std.debug.print("Server error: {any}\n", .{err});
        };

        // 2. Process a batch of messages  
        _ = processor.processBatch(input_queue, output_queue);

        // 3. Handle network I/O again to send responses quickly
        _ = server.poll() catch {};
        
        // 4. Process another batch
        _ = processor.processBatch(input_queue, output_queue);
    }

    std.debug.print("Shutting down...\n", .{});

    for (0..100) |_| {
        _ = server.poll() catch {};
        _ = processor.processBatch(input_queue, output_queue);
    }

    server.stop();
    printStats(processor.getStats());
}

fn runThreaded(allocator: std.mem.Allocator, config: *const Config) !void {
    if (config.verbose) std.debug.print("Initializing threaded mode...\n", .{});

    const input_queue = try allocator.create(InputEnvelopeQueue);
    defer allocator.destroy(input_queue);
    input_queue.* = InputEnvelopeQueue.init();

    const output_queue = try allocator.create(OutputEnvelopeQueue);
    defer allocator.destroy(output_queue);
    output_queue.* = OutputEnvelopeQueue.init();

    const server = try allocator.create(TcpServer);
    defer allocator.destroy(server);
    server.initInPlace();

    server.setQueues(input_queue, output_queue);

    const processor_thread = try allocator.create(ProcessorThread);
    defer allocator.destroy(processor_thread);
    // Use initInPlace to avoid stack overflow
    processor_thread.initInPlace(input_queue, output_queue);

    const address = try std.net.Address.parseIp4(config.tcp_addr, config.tcp_port);
    try server.start(address);
    try processor_thread.start();

    if (config.verbose) std.debug.print("Server and processor started\n", .{});
    printStartupBanner(config);

    while (!shutdown_requested.load(.acquire)) {
        _ = server.poll() catch |err| {
            std.debug.print("Server error: {any}\n", .{err});
        };
    }

    std.debug.print("Shutting down...\n", .{});

    processor_thread.stop();

    for (0..10) |_| {
        _ = server.poll() catch {};
    }

    server.stop();
    printStats(processor_thread.getStats());
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
    std.debug.print("  TcpServer:       {d} bytes\n", .{@sizeOf(TcpServer)});
    std.debug.print("  Processor:       {d} bytes\n", .{@sizeOf(Processor)});
    std.debug.print("  InputQueue:      {d} bytes\n", .{@sizeOf(InputEnvelopeQueue)});
    std.debug.print("  OutputQueue:     {d} bytes\n", .{@sizeOf(OutputEnvelopeQueue)});
    std.debug.print("\n", .{});

    const opts = parseOptions();

    switch (opts.mode) {
        .help => {
            printUsage();
            return;
        },
        .version => {
            printVersion();
            return;
        },
        .server => {},
    }

    setupSignalHandlers();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (opts.config.threaded) {
        try runThreaded(allocator, &opts.config);
    } else {
        try runSingleThreaded(allocator, &opts.config);
    }

    std.debug.print("Shutdown complete\n", .{});
}

// ============================================================================
// Tests
// ============================================================================
test "all module tests" {
    _ = @import("protocol/message_types.zig");
    _ = @import("protocol/binary_codec.zig");
    _ = @import("protocol/fix_codec.zig");
    _ = @import("core/order.zig");
    _ = @import("core/output_buffer.zig");
    _ = @import("core/order_book.zig");
    _ = @import("core/matching_engine.zig");
    _ = @import("threading/spsc_queue.zig");
    _ = @import("threading/processor.zig");
    _ = @import("transport/framing.zig");
    _ = @import("transport/tcp_connection.zig");
    _ = @import("transport/tcp_server.zig");
}

test "struct sizes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Order));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(msg.InputMsg));
    try std.testing.expectEqual(@as(usize, 52), @sizeOf(msg.OutputMsg));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SpscQueue.InputEnvelope));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SpscQueue.OutputEnvelope));
}

test "config from env" {
    const config = Config.fromEnv();
    try std.testing.expect(config.tcp_port > 0);
}
