# Zig Matching Engine

A high-performance, multi-protocol, multi-transport order matching engine built in Zig, following HFT low-latency principles and NASA Power of Ten safety-critical coding rules.

Ported from the C matching engine with identical wire protocol compatibility.

## Features

- **Zero-allocation hot path** — Pre-allocated memory pools, no heap allocation during trading
- **Cache-optimized** — 64-byte aligned orders, sequential memory access, L1/L2 cache friendly
- **Multi-transport** — TCP (with framing), UDP (bidirectional), and Multicast
- **Multi-protocol** — CSV (human-readable), Binary (high-performance)
- **Protocol auto-detection** — Automatically detects CSV/Binary from first byte
- **Network byte order** — Big-endian integers for cross-platform compatibility
- **TCP framing** — 4-byte length-prefixed messages for reliable streaming

## Quick Start

### Build
```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

### Run Server
```bash
# Run with defaults (TCP:9000, UDP:9001, Multicast:239.255.0.1:9002)
zig build run

# Or run the binary directly
./zig-out/bin/matching_engine
```

### Test with netcat (CSV over TCP)
```bash
# Terminal 1: Start server
zig build run

# Terminal 2: Send orders via TCP (note: needs length framing for TCP)
# For simple testing, use UDP which doesn't require framing:
echo "N, 1, IBM, 10000, 50, B, 100" | nc -u localhost 9001

# Or use the provided test client
zig build run-client
```

### Test with Binary Protocol
```bash
# The binary protocol uses magic byte 0x4D ('M') and network byte order
# See protocol documentation for wire format details
```

## Protocol Formats

### CSV Input Messages
```
N, userId, symbol, price, qty, side, orderId    # New Order
C, userId, orderId                               # Cancel Order  
F                                                # Flush All
```

### CSV Output Messages
```
A, symbol, userId, orderId                       # Acknowledgement
T, symbol, buyUid, buyOid, sellUid, sellOid, price, qty  # Trade
B, symbol, side, price, qty                      # Top of Book
C, symbol, userId, orderId                       # Cancel Ack
R, symbol, userId, orderId, reason               # Reject
```

### Binary Protocol

- Magic byte: `0x4D` ('M')
- All integers: Big-endian (network byte order)
- Symbols: 8 bytes, null-padded

| Message | Type Byte | Wire Size |
|---------|-----------|-----------|
| New Order | 'N' (0x4E) | 27 bytes |
| Cancel | 'C' (0x43) | 10 bytes |
| Flush | 'F' (0x46) | 2 bytes |
| Ack | 'A' (0x41) | 18 bytes |
| Trade | 'T' (0x54) | 34 bytes |
| Top of Book | 'B' (0x42) | 20 bytes |

### TCP Framing

TCP uses 4-byte big-endian length prefix:
```
[4 bytes: message length (big-endian)][N bytes: payload]
```

UDP does not use framing (each packet = one message).

## Configuration

### Environment Variables
```bash
# TCP
export ENGINE_TCP_ENABLED=true
export ENGINE_TCP_PORT=9000

# UDP
export ENGINE_UDP_ENABLED=true
export ENGINE_UDP_PORT=9001

# Multicast
export ENGINE_MCAST_ENABLED=true
export ENGINE_MCAST_GROUP=239.255.0.1
export ENGINE_MCAST_PORT=9002
```

### Default Ports

| Transport | Port | Protocol |
|-----------|------|----------|
| TCP | 9000 | CSV or Binary (auto-detect) |
| UDP | 9001 | CSV or Binary (auto-detect) |
| Multicast | 9002 | Binary (market data broadcast) |

## Project Structure
```
zig_matching_engine/
├── build.zig                 # Build configuration
├── README.md
├── src/
│   ├── main.zig              # Entry point
│   ├── core/
│   │   ├── order.zig         # Order structure (64-byte aligned)
│   │   ├── order_book.zig    # Price-time priority matching
│   │   ├── matching_engine.zig # Multi-symbol orchestrator
│   │   └── memory_pool.zig   # Pre-allocated pools
│   ├── protocol/
│   │   ├── message_types.zig # Message definitions
│   │   ├── codec.zig         # Protocol detection
│   │   ├── binary_codec.zig  # Binary encoder/decoder
│   │   ├── csv_codec.zig     # CSV encoder/decoder
│   │   └── fix_codec.zig     # FIX protocol (placeholder)
│   └── transport/
│       ├── config.zig        # Configuration
│       ├── tcp_server.zig    # Multi-client TCP with framing
│       ├── udp_server.zig    # Bidirectional UDP
│       ├── multicast.zig     # Market data multicast
│       └── server.zig        # Unified server
└── tests/
```

## Architecture Highlights

### Memory Layout
```
Order (64 bytes = 1 cache line):
├── Hot fields (0-19): user_id, order_id, price, qty, remaining
├── Metadata (20-31): side, type, client_id
├── Timestamp (32-39): RDTSC on x86_64
├── Linked list (40-55): next, prev pointers
└── Padding (56-63): cache line alignment
```

### Message Routing

| Message Type | Routing |
|--------------|---------|
| Ack | Originating client only |
| Cancel Ack | Originating client only |
| Trade | Both buyer and seller + multicast |
| Top of Book | Multicast only |

### Performance Characteristics

| Metric | Value |
|--------|-------|
| Order struct size | 64 bytes (cache-line aligned) |
| Symbol size | 8 bytes (fixed) |
| Hot path allocations | 0 |
| Hash table | Open-addressing, power-of-2 |

## Examples

### Simple Buy/Sell Match
```bash
# Start server
zig build run &

# Send buy order (UDP, no framing needed)
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u localhost 9001

# Send sell order that matches
echo "N, 2, IBM, 10000, 50, S, 1" | nc -u localhost 9001

# Expected output:
# A, IBM, 1, 1       (buy ack)
# B, IBM, B, 10000, 100  (TOB update)
# A, IBM, 2, 1       (sell ack)  
# T, IBM, 1, 1, 2, 1, 10000, 50  (trade)
# B, IBM, B, 10000, 50  (TOB update - remaining qty)
```

### Cancel Order
```bash
echo "C, 1, 1" | nc -u localhost 9001
# Output: C, IBM, 1, 1  (cancel ack)
```

## Compatibility

This Zig implementation is wire-compatible with the C matching engine:

- Same magic byte (`0x4D`)
- Same message formats
- Same byte order (network/big-endian)
- Same TCP framing (4-byte length prefix)

## Building for Production
```bash
# Release build with all optimizations
zig build -Doptimize=ReleaseFast

# Strip debug symbols for smaller binary
zig build -Doptimize=ReleaseSmall

# Cross-compile for Linux (from any OS)
zig build -Dtarget=x86_64-linux
```

## License

MIT

## See Also

- [C Matching Engine](../matching-engine-c/) - Original C implementation
