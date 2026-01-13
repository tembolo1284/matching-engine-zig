i//! Threading module - processor threads and output sender
//!
//! Architecture Overview:
//! ```
//!   I/O Thread
//!       │
//!       ├──► Processor 0 (A-M symbols)
//!       │        └──► OutputQueue ───┐
//!       │                            │
//!       └──► Processor 1 (N-Z symbols)│
//!                └──► OutputQueue ───┤
//!                                    │
//!                                    ▼
//!                          Output Sender Thread
//!                                    │
//!                                    ▼
//!                          TCP/UDP/Multicast
//! ```
//!
//! Components:
//! - processor.zig: Matching engine processors (one per symbol partition)
//! - output_sender.zig: Dedicated output sender thread
//! - threaded_server.zig: Original integrated server (v5)
//! - threaded_server_v6.zig: Server with dedicated output sender

pub const processor = @import("processor.zig");
pub const output_sender = @import("output_sender.zig");

// Re-export commonly used types
pub const Processor = processor.Processor;
pub const ProcessorId = processor.ProcessorId;
pub const ProcessorStats = processor.ProcessorStats;
pub const ProcessorInput = processor.ProcessorInput;
pub const ProcessorOutput = processor.ProcessorOutput;
pub const InputQueue = processor.InputQueue;
pub const OutputQueue = processor.OutputQueue;

pub const OutputSender = output_sender.OutputSender;
pub const OutputSenderStats = output_sender.OutputSenderStats;
pub const ClientOutputState = output_sender.ClientOutputState;
pub const Protocol = output_sender.Protocol;

// Configuration re-exports
pub const CHANNEL_CAPACITY = processor.CHANNEL_CAPACITY;
pub const MAX_OUTPUT_CLIENTS = output_sender.MAX_OUTPUT_CLIENTS;

// Helper re-exports
pub const routeSymbol = processor.routeSymbol;
pub const makeDirectSendCallback = output_sender.makeDirectSendCallback;

// Tests
test {
    _ = processor;
    _ = output_sender;
}
