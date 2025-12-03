//! Threading layer for dual-processor matching engine.

pub const Processor = @import("processor.zig").Processor;
pub const ProcessorId = @import("processor.zig").ProcessorId;
pub const ProcessorInput = @import("processor.zig").ProcessorInput;
pub const ProcessorOutput = @import("processor.zig").ProcessorOutput;
pub const routeSymbol = @import("processor.zig").routeSymbol;
pub const CHANNEL_CAPACITY = @import("processor.zig").CHANNEL_CAPACITY;

pub const ThreadedServer = @import("threaded_server.zig").ThreadedServer;
