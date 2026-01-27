const std = @import("std");

pub fn main() !void {
    std.debug.print("Step 1: Starting\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("Step 2: Allocator ready\n", .{});
    
    // Test allocating a large chunk
    const big_mem = try allocator.alloc(u8, 70_000_000);
    defer allocator.free(big_mem);
    
    std.debug.print("Step 3: Allocated 70MB, success!\n", .{});
}
