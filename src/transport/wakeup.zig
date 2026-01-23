const std = @import("std");
const posix = std.posix;

/// Linux eventfd-based wakeup primitive for epoll.
/// - OutputRouter (or any producer thread) calls `notify()`
/// - TcpServer epoll loop watches `fd` for readability and calls `drain()`
pub const Wakeup = struct {
    fd: posix.fd_t,

    pub fn init() !Wakeup {
        // eventfd counter starts at 0; readable when counter > 0
        // NONBLOCK so drain doesn't hang; CLOEXEC for hygiene
        const fd = try posix.eventfd(0, posix.EFD.NONBLOCK | posix.EFD.CLOEXEC);
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Wakeup) void {
        _ = posix.close(self.fd);
    }

    /// Signal the consumer (epoll thread). Safe to call from any thread.
    /// We intentionally ignore EAGAIN here: eventfd counter overflow is
    /// astronomically unlikely in this usage; worst case the epoll thread
    /// will still wake on subsequent signals.
    pub fn notify(self: *Wakeup) void {
        var one: u64 = 1;
        _ = posix.write(self.fd, std.mem.asBytes(&one));
    }

    /// Drain the counter so epoll doesn't keep firing.
    /// Safe to call from the epoll thread when fd is readable.
    pub fn drain(self: *Wakeup) void {
        var value: u64 = 0;
        _ = posix.read(self.fd, std.mem.asBytes(&value));
    }
};

