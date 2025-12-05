//! Protocol codecs for the matching engine.
//!
//! Supported protocols:
//! - **Binary**: Low-latency fixed-size messages
//! - **CSV**: Human-readable text format
//! - **FIX**: FIX 4.2/4.4 (partial implementation)
//!
//! Usage:
//! ```zig
//! const protocol = @import("protocol");
//!
//! // Auto-detect and decode
//! const result = try protocol.Codec.decodeInput(data);
//!
//! // Encode with specific protocol
//! var codec = protocol.Codec.init(.binary);
//! const len = try codec.encodeOutput(&msg, &buf);
//! ```

// Re-export message types
pub const msg = @import("message_types.zig");
pub const Symbol = msg.Symbol;
pub const Side = msg.Side;
pub const InputMsg = msg.InputMsg;
pub const OutputMsg = msg.OutputMsg;
pub const InputMsgType = msg.InputMsgType;
pub const OutputMsgType = msg.OutputMsgType;
pub const RejectReason = msg.RejectReason;
pub const makeSymbol = msg.makeSymbol;
pub const symbolSlice = msg.symbolSlice;
pub const symbolEqual = msg.symbolEqual;

// Re-export codec interface
pub const codec = @import("codec.zig");
pub const Codec = codec.Codec;
pub const Protocol = codec.Protocol;
pub const CodecError = codec.CodecError;
pub const DecodeResult = codec.DecodeResult;
pub const OutputDecodeResult = codec.OutputDecodeResult;
pub const detectProtocol = codec.detectProtocol;

// Re-export individual codecs for direct use
pub const binary = @import("binary_codec.zig");
pub const csv = @import("csv_codec.zig");
pub const fix = @import("fix_codec.zig");

// Convenience re-exports
pub const BINARY_MAGIC = codec.BINARY_MAGIC;
pub const parseU32 = codec.parseU32;
pub const writeU32 = codec.writeU32;
pub const trim = codec.trim;

test {
    // Run all protocol tests
    _ = @import("message_types.zig");
    _ = @import("codec.zig");
    _ = @import("binary_codec.zig");
    _ = @import("csv_codec.zig");
    _ = @import("fix_codec.zig");
}
