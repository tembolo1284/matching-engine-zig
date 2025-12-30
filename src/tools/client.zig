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
const msg = @import("message_types");
const codec = @import("codec");
const csv_codec = @import("csv_codec");
const binary_codec = @import("binary_codec");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    std.debug.print("Matching Engine Test Client\n", .{});
    std.debug.print("Usage: engine_client <host> <port> <command>\n", .{});
    std.debug.print("\nNot yet implemented - use netcat or custom client.\n", .{});
    std.debug.print("\nExample with netcat:\n", .{});
    std.debug.print("  echo 'N, 1, IBM, 100, 50, B, 1' | nc localhost 1234\n", .{});
}
