const std = @import("std");
const msg = @import("protocol/message_types.zig");
const MemoryPools = @import("core/memory_pool.zig").MemoryPools;
const MatchingEngine = @import("core/matching_engine.zig").MatchingEngine;
const Server = @import("transport/server.zig").Server;
const cfg = @import("transport/config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    const config = cfg.Config.fromEnv();

    // Initialize memory pools
    var pools = try MemoryPools.init(allocator);
    defer pools.deinit();

    // Initialize matching engine
    var engine = MatchingEngine.init(&pools);

    // Initialize and start server
    var server = Server.init(allocator, &engine, config);
    defer server.deinit();

    try server.start();

    std.log.info("Zig Matching Engine Ready", .{});
    std.log.info("  TCP: {s}:{} (4-byte length framing)", .{ config.tcp_addr, config.tcp_port });
    std.log.info("  UDP: {s}:{} (bidirectional)", .{ config.udp_addr, config.udp_port });
    std.log.info("  Multicast: {s}:{}", .{ config.mcast_group, config.mcast_port });
    std.log.info("  Binary magic: 0x4D ('M'), Network byte order", .{});

    // Run event loop
    try server.run();
}
