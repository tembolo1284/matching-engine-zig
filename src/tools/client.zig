//! Test client for the matching engine.
//!
//! Usage:
//!   engine_client [options] <command> [args]
//!
//! Commands:
//!   order <symbol> <side> <price> <qty>  - Submit order
//!   cancel <order_id>                     - Cancel order
//!   status                                - Get server status
//!
//! Options:
//!   --tcp <host:port>    - Connect via TCP (default)
//!   --udp <host:port>    - Connect via UDP
//!   --binary             - Use binary protocol
//!   --csv                - Use CSV protocol (default)

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const codec = @import("../protocol/codec.zig");
const csv_codec = @import("../protocol/csv_codec.zig");
const binary_codec = @import("../protocol/binary_codec.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.debug.print("Matching Engine Test Client\n", .{});
    std.debug.print("Usage: engine_client <host> <port> <command>\n", .{});
    std.debug.print("\nNot yet implemented - use netcat or custom client.\n", .{});
    std.debug.print("\nExample with netcat:\n", .{});
    std.debug.print("  echo 'N, 1, IBM, 100, 50, B, 1' | nc localhost 1234\n", .{});
}
