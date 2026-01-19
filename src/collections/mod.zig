//! Collections module - data structures for the matching engine

pub const spsc_queue = @import("spsc_queue.zig");
pub const bounded_channel = @import("bounded_channel.zig");
pub const client_output_queue = @import("client_output_queue.zig");

// Re-exports for convenience
pub const SpscQueue = spsc_queue.SpscQueue;
pub const BoundedChannel = bounded_channel.BoundedChannel;
pub const ClientOutputQueue = client_output_queue.ClientOutputQueue;
pub const ClientOutput = client_output_queue.ClientOutput;
