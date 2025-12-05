//! Threading layer for dual-processor matching engine.
//!
//! Architecture overview:
//! - I/O thread handles all network communication (TCP, UDP, Multicast)
//! - Two processor threads handle order matching (partitioned by symbol)
//! - SPSC queues connect I/O thread to processors (zero-copy, lock-free)
//!
//! Symbol partitioning:
//! - Processor 0: Symbols starting with A-M (or non-alphabetic)
//! - Processor 1: Symbols starting with N-Z
//!
//! Thread safety:
//! - Each processor owns its MatchingEngine exclusively
//! - Communication via lock-free SPSC queues only
//! - No shared mutable state between threads

pub const Processor = @import("processor.zig").Processor;
pub const ProcessorId = @import("processor.zig").ProcessorId;
pub const ProcessorInput = @import("processor.zig").ProcessorInput;
pub const ProcessorOutput = @import("processor.zig").ProcessorOutput;
pub const ProcessorStats = @import("processor.zig").ProcessorStats;
pub const routeSymbol = @import("processor.zig").routeSymbol;

pub const ThreadedServer = @import("threaded_server.zig").ThreadedServer;
pub const ServerStats = @import("threaded_server.zig").ServerStats;

/// Channel capacity for I/O ↔ Processor communication.
/// Must be power of 2. 64K provides ~1ms buffer at 60M msg/sec.
pub const CHANNEL_CAPACITY = @import("processor.zig").CHANNEL_CAPACITY;

/// Number of processor threads.
pub const NUM_PROCESSORS = 2;
