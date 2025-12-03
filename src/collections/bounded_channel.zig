//! Bounded channel for typed message passing between threads.
//!
//! Built on top of SPSC queue, provides a higher-level interface
//! for sending messages between an I/O thread and processor threads.

const std = @import("std");
const SpscQueue = @import("spsc_queue.zig").SpscQueue;

/// A bounded channel for passing messages of type T.
/// Uses SPSC queue internally - one sender, one receiver.
pub fn BoundedChannel(comptime T: type, comptime capacity: usize) type {
    return struct {
        queue: SpscQueue(T, capacity),

        const Self = @This();

        pub fn init() Self {
            return .{
                .queue = SpscQueue(T, capacity).init(),
            };
        }

        /// Send a message. Returns false if channel is full.
        pub fn send(self: *Self, msg: T) bool {
            return self.queue.push(msg);
        }

        /// Try to receive a message. Returns null if channel is empty.
        pub fn tryRecv(self: *Self) ?T {
            return self.queue.pop();
        }

        /// Receive with spinning (busy wait) - use sparingly
        pub fn recvSpin(self: *Self) T {
            while (true) {
                if (self.queue.pop()) |msg| {
                    return msg;
                }
                std.atomic.spinLoopHint();
            }
        }

        /// Check if channel is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.queue.isEmpty();
        }

        /// Check if channel is full
        pub fn isFull(self: *const Self) bool {
            return self.queue.isFull();
        }

        /// Get approximate number of pending messages
        pub fn pending(self: *const Self) usize {
            return self.queue.size();
        }
    };
}

// Type alias for convenience
pub const InputChannel = BoundedChannel;
pub const OutputChannel = BoundedChannel;
