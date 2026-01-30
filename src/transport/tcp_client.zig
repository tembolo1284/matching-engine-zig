//! TCP Client Handler - Per-client thread for reading/writing
const std = @import("std");
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const framing = @import("framing.zig");
const msg = @import("../protocol/message_types.zig");
const SpscQueue = @import("../threading/spsc_queue.zig");
const InputEnvelope = SpscQueue.InputEnvelope;
const OutputEnvelope = SpscQueue.OutputEnvelope;
const InputEnvelopeQueue = SpscQueue.InputEnvelopeQueue;

/// Per-client output queue capacity
pub const CLIENT_OUTPUT_QUEUE_SIZE: u32 = 32768;

/// Per-client output queue type
pub const ClientOutputQueue = SpscQueue.SpscQueue(msg.OutputMsg, CLIENT_OUTPUT_QUEUE_SIZE);

pub const ClientState = enum(u8) {
    connecting,
    connected,
    disconnecting,
    disconnected,
};

pub const ClientStats = struct {
    messages_received: u64,
    messages_sent: u64,
    bytes_received: u64,
    bytes_sent: u64,

    pub fn init() ClientStats {
        return ClientStats{
            .messages_received = 0,
            .messages_sent = 0,
            .bytes_received = 0,
            .bytes_sent = 0,
        };
    }
};

pub const TcpClient = struct {
    client_id: u32,
    stream: net.Stream,
    address: net.Address,
    state: std.atomic.Value(ClientState),
    
    // Parser for incoming messages
    parser: framing.StreamParser,
    
    // Per-client output queue (router writes, handler reads and sends)
    output_queue: ClientOutputQueue,
    
    // Reference to global input queue (handler writes)
    input_queue: *InputEnvelopeQueue,
    
    // Thread handle
    thread: ?Thread,
    
    // Shutdown flag
    shutdown: std.atomic.Value(bool),
    
    // Stats
    stats: ClientStats,
    
    // Connection time
    connect_time_ms: i64,

    const Self = @This();

    pub fn init(
        client_id: u32,
        stream: net.Stream,
        address: net.Address,
        input_queue: *InputEnvelopeQueue,
    ) Self {
        return Self{
            .client_id = client_id,
            .stream = stream,
            .address = address,
            .state = std.atomic.Value(ClientState).init(.connected),
            .parser = framing.StreamParser.init(),
            .output_queue = ClientOutputQueue.init(),
            .input_queue = input_queue,
            .thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .stats = ClientStats.init(),
            .connect_time_ms = std.time.milliTimestamp(),
        };
    }

    pub fn start(self: *Self) !void {
        self.thread = try Thread.spawn(.{}, clientThreadFn, .{self});
    }

    pub fn stop(self: *Self) void {
        self.shutdown.store(true, .release);
        // Close socket to unblock any recv()
        self.stream.close();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn isActive(self: *const Self) bool {
        const state = self.state.load(.acquire);
        return state == .connected;
    }

    pub fn enqueueOutput(self: *Self, output: *const msg.OutputMsg) bool {
        return self.output_queue.push(output.*);
    }

    fn clientThreadFn(self: *Self) void {
        std.debug.print("[TCP] Client {d} handler thread started\n", .{self.client_id});
        
        // Set socket options
        self.setSocketOptions() catch {};
        
        // Main loop - read and write
        var recv_buf: [4096]u8 = undefined;
        var send_buf: [256]u8 = undefined;
        
        while (!self.shutdown.load(.acquire)) {
            // Try to receive data
            const bytes_read = self.stream.read(&recv_buf) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        // No data available, try sending instead
                        self.trySendPending(&send_buf);
                        Thread.sleep(100_000); // 100us
                        continue;
                    },
                    error.ConnectionResetByPeer, error.BrokenPipe => {
                        break; // Connection closed
                    },
                    else => {
                        break; // Other error
                    },
                }
            };
            
            if (bytes_read == 0) {
                // Connection closed by peer
                break;
            }
            
            self.stats.bytes_received += bytes_read;
            
            // Feed to parser
            _ = self.parser.feed(recv_buf[0..bytes_read]);
            
            // Process all complete messages
            while (self.parser.nextMessage()) |message| {
                self.stats.messages_received += 1;
                
                // Push to global input queue
                const envelope = InputEnvelope{
                    .message = message,
                    .client_id = self.client_id,
                    ._pad = undefined,
                };
                
                // Spin until we can push (don't drop messages)
                while (!self.input_queue.push(envelope)) {
                    self.trySendPending(&send_buf);
                    if (self.shutdown.load(.acquire)) break;
                }
            }
            
            // Try to send pending outputs
            self.trySendPending(&send_buf);
        }
        
        self.state.store(.disconnected, .release);
        
        const duration = std.time.milliTimestamp() - self.connect_time_ms;
        std.debug.print("[TCP] Client {d} handler thread stopped (duration={d}ms, recv={d}, sent={d})\n", .{
            self.client_id,
            duration,
            self.stats.messages_received,
            self.stats.messages_sent,
        });
    }

    fn trySendPending(self: *Self, send_buf: *[256]u8) void {
        // Send up to 100 messages per call to avoid blocking reads too long
        var sent: u32 = 0;
        while (sent < 100) : (sent += 1) {
            const output = self.output_queue.pop() orelse break;
            
            const protocol = self.parser.getProtocol();
            const proto = if (protocol == .unknown) framing.Protocol.binary else protocol;
            
            const encoded_len = framing.encodeOutput(&output, proto, send_buf) catch continue;
            if (encoded_len == 0) continue;
            
            // Send the message
            var total_sent: usize = 0;
            while (total_sent < encoded_len) {
                const n = self.stream.write(send_buf[total_sent..encoded_len]) catch |err| {
                    switch (err) {
                        error.WouldBlock => {
                            // Can't send more right now
                            Thread.sleep(10_000); // 10us
                            continue;
                        },
                        else => return, // Error, stop sending
                    }
                };
                total_sent += n;
                self.stats.bytes_sent += n;
            }
            self.stats.messages_sent += 1;
        }
    }

    fn setSocketOptions(self: *Self) !void {
        // Non-blocking
        const flags = try posix.fcntl(self.stream.handle, posix.F.GETFL, 0);
        _ = try posix.fcntl(
            self.stream.handle,
            posix.F.SETFL,
            flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
        );
        
        // TCP_NODELAY
        const nodelay: u32 = 1;
        try posix.setsockopt(
            self.stream.handle,
            posix.IPPROTO.TCP,
            posix.TCP.NODELAY,
            &std.mem.toBytes(nodelay),
        );
    }
};
