const std = @import("std");
const msg = @import("protocol/message_types.zig");
const MemoryPools = @import("core/memory_pool.zig").MemoryPools;
const MatchingEngine = @import("core/matching_engine.zig").MatchingEngine;
const Server = @import("transport/server.zig").Server;
const ThreadedServer = @import("threading/threaded_server.zig").ThreadedServer;
const cfg = @import("transport/config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    const config = cfg.Config.fromEnv();

    // Check for threaded mode
    const threaded = std.process.getEnvVarOwned(allocator, "ENGINE_THREADED") catch null;
    defer if (threaded) |t| allocator.free(t);

    const use_threaded = if (threaded) |t| std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1") else false;

    if (use_threaded) {
        // Dual-processor threaded mode
        std.log.info("Starting in THREADED mode (dual-processor)", .{});

        var server = ThreadedServer.init(allocator, config);
        defer server.deinit();

        try server.start();

        std.log.info("Zig Matching Engine Ready (Threaded)", .{});
        std.log.info("  TCP: {s}:{}", .{ config.tcp_addr, config.tcp_port });
        std.log.info("  UDP: {s}:{}", .{ config.udp_addr, config.udp_port });
        std.log.info("  Multicast: {s}:{}", .{ config.mcast_group, config.mcast_port });
        std.log.info("  Processor 0: Symbols A-M", .{});
        std.log.info("  Processor 1: Symbols N-Z", .{});

        try server.run();
    } else {
        // Single-threaded mode
        std.log.info("Starting in SINGLE-THREADED mode", .{});

        var pools = try MemoryPools.init(allocator);
        defer pools.deinit();

        var engine = MatchingEngine.init(&pools);

        var server = Server.init(allocator, &engine, config);
        defer server.deinit();

        try server.start();

        std.log.info("Zig Matching Engine Ready (Single-threaded)", .{});
        std.log.info("  TCP: {s}:{}", .{ config.tcp_addr, config.tcp_port });
        std.log.info("  UDP: {s}:{}", .{ config.udp_addr, config.udp_port });
        std.log.info("  Multicast: {s}:{}", .{ config.mcast_group, config.mcast_port });

        try server.run();
    }
}
