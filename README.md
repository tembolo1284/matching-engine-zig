# Zig Matching Engine

A high-performance order matching engine written in Zig, designed for low-latency trading systems. Features a dual-processor architecture with lock-free communication, supporting both TCP and UDP protocols with CSV and binary message formats.

## Features

- **High Performance**: Lock-free SPSC queues, zero-copy message passing, O(1) order operations
- **Dual-Processor Architecture**: Symbol-based partitioning (A-M / N-Z) for parallel matching
- **Multiple Protocols**: TCP (framed), UDP (stateless), Multicast (market data)
- **Multiple Codecs**: CSV (human-readable), Binary (low-latency), FIX (industry standard)
- **NASA Power of Ten Compliant**: Bounded loops, extensive assertions, no dynamic allocation in hot path
- **Production Ready**: Graceful shutdown, health monitoring, comprehensive statistics

## Quick Start

```bash
# Build
make build

# Run tests
make test

# Run threaded server (production mode)
make run-threaded

# Run single-threaded server (debugging)
make run
```

See [QUICK_START.md](QUICK_START.md) for detailed setup instructions.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      I/O Thread                              │
│  ┌───────────┐  ┌───────────┐  ┌─────────────────────────┐  │
│  │TCP Server │  │UDP Server │  │ Multicast Publisher     │  │
│  │(framed)   │  │(stateless)│  │ (market data feed)      │  │
│  └─────┬─────┘  └─────┬─────┘  └───────────┬─────────────┘  │
│        │              │                    │                 │
│        └──────────────┼────────────────────┘                 │
│                       │                                      │
│              ┌────────▼────────┐                             │
│              │  Message Router │                             │
│              │  (A-M / N-Z)    │                             │
│              └────────┬────────┘                             │
└───────────────────────┼─────────────────────────────────────┘
                        │
          ┌─────────────┴─────────────┐
          │                           │
    ┌─────▼─────┐               ┌─────▼─────┐
    │ SPSC Queue│               │ SPSC Queue│
    │  (64K)    │               │  (64K)    │
    └─────┬─────┘               └─────┬─────┘
          │                           │
┌─────────▼─────────┐       ┌─────────▼─────────┐
│   Processor 0     │       │   Processor 1     │
│   Symbols A-M     │       │   Symbols N-Z     │
│  ┌─────────────┐  │       │  ┌─────────────┐  │
│  │ OrderBooks  │  │       │  │ OrderBooks  │  │
│  │ (hash map)  │  │       │  │ (hash map)  │  │
│  └─────────────┘  │       │  └─────────────┘  │
└───────────────────┘       └───────────────────┘
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design documentation.

## Project Structure

```
src/
├── core/                   # Matching engine core
│   ├── matching_engine.zig # Main engine orchestration
│   ├── order_book.zig      # Price-time priority order book
│   ├── memory_pool.zig     # Fixed-size memory allocators
│   └── order.zig           # Order data structures
│
├── protocol/               # Message encoding/decoding
│   ├── message_types.zig   # Input/Output message definitions
│   ├── codec.zig           # Protocol detection & routing
│   ├── csv_codec.zig       # Human-readable CSV format
│   ├── binary_codec.zig    # Low-latency binary format
│   └── fix_codec.zig       # FIX protocol support
│
├── transport/              # Network I/O layer
│   ├── tcp_server.zig      # TCP with length-prefixed framing
│   ├── tcp_client.zig      # Client connection management
│   ├── udp_server.zig      # Stateless UDP with client tracking
│   ├── multicast.zig       # Market data multicast publisher
│   ├── config.zig          # Configuration management
│   └── net_utils.zig       # Network utilities
│
├── threading/              # Multi-threaded architecture
│   ├── threaded_server.zig # I/O thread + message routing
│   ├── processor.zig       # Matching processor threads
│   └── mod.zig             # Module exports
│
├── collections/            # Data structures
│   ├── spsc_queue.zig      # Lock-free single-producer/single-consumer
│   └── object_pool.zig     # Fixed-capacity object pool
│
└── main.zig                # Entry point
```

## Message Formats

### CSV Format (Human-Readable)

```
# New Order: N,<symbol>,<user_id>,<user_order_id>,<side>,<price>,<quantity>
N,AAPL,1001,1,B,150.00,100

# Cancel: C,<symbol>,<user_id>,<user_order_id>
C,AAPL,1001,1

# Acknowledgment: A,<symbol>,<user_order_id>,<status>
A,AAPL,1,0

# Trade: T,<symbol>,<price>,<quantity>,<buy_order_id>,<sell_order_id>
T,AAPL,150.00,100,1,2

# Reject: R,<symbol>,<user_order_id>,<reason>
R,AAPL,1,1
```

### Binary Format (Low-Latency)

Fixed 64-byte messages with native byte order for minimal parsing overhead.

| Field | Offset | Size | Description |
|-------|--------|------|-------------|
| msg_type | 0 | 1 | Message type enum |
| side | 1 | 1 | Buy (1) / Sell (2) |
| symbol | 2 | 8 | Null-padded symbol |
| user_id | 10 | 4 | User identifier |
| user_order_id | 14 | 4 | User's order ID |
| price | 18 | 8 | Price (scaled integer) |
| quantity | 26 | 4 | Order quantity |
| _padding | 30 | 34 | Reserved (zero-filled) |

## Performance Characteristics

| Metric | Target | Notes |
|--------|--------|-------|
| Latency (p50) | < 10 μs | Order entry to ack |
| Latency (p99) | < 50 μs | Including queue wait |
| Throughput | > 200K orders/sec | Per processor |
| Memory | ~50 MB | Fixed allocation |

## Configuration

Environment variables:

```bash
# Network
ME_TCP_PORT=8080          # TCP server port
ME_UDP_PORT=8081          # UDP server port
ME_MCAST_GROUP=239.0.0.1  # Multicast group
ME_MCAST_PORT=8082        # Multicast port

# Performance
ME_CHANNEL_CAPACITY=65536 # SPSC queue size (power of 2)
ME_TRACK_LATENCY=true     # Enable latency tracking
```

## Testing

```bash
# Run all tests
make test

# Run specific module tests
zig build test --summary all

# Run with verbose output
zig build test -Dtest-filter="order_book"
```

## Safety & Reliability

This codebase follows the **NASA Power of Ten** rules for safety-critical software:

1. **Simple Control Flow**: No goto, setjmp, or recursion
2. **Bounded Loops**: All loops have explicit iteration limits
3. **No Dynamic Allocation**: Fixed-size buffers, pool allocators
4. **Short Functions**: All functions ≤60 lines
5. **High Assertion Density**: ≥2 assertions per function average
6. **Minimal Scope**: Variables declared at narrowest scope
7. **Check All Returns**: All error codes checked
8. **Limited Preprocessor**: Minimal comptime complexity
9. **Pointer Discipline**: Restricted pointer usage, no pointer arithmetic
10. **Compiler Warnings**: Treat all warnings as errors

## Building from Source

### Requirements

- Zig 0.13.0 or later
- Linux (primary), macOS (supported), Windows (experimental)
- Make (optional, for convenience targets)

### Build Commands

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run directly
zig build run -- --mode threaded

# Generate documentation
zig build docs
```

## Client Examples

### Python (CSV over TCP)

```python
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 8080))

# Send order (length-prefixed)
msg = b"N,AAPL,1001,1,B,15000,100\n"
sock.send(len(msg).to_bytes(4, 'little') + msg)

# Receive response
length = int.from_bytes(sock.recv(4), 'little')
response = sock.recv(length)
print(response.decode())
```

### netcat (CSV over UDP)

```bash
# Send order
echo "N,AAPL,1001,1,B,15000,100" | nc -u localhost 8081
```
