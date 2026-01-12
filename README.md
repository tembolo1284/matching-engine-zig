# Zig Matching Engine

A high-performance order matching engine written in Zig, designed for low-latency trading systems. Features a dual-processor architecture with lock-free communication, per-client output queues for decoupled I/O, and support for TCP, UDP, and multicast protocols with CSV, binary, and FIX message formats.

## Features

- **High Performance**: Lock-free SPSC queues, per-client output queues, zero-copy message passing, O(1) order operations
- **Dual-Processor Architecture**: Symbol-based partitioning (A-M / N-Z) for parallel matching
- **Decoupled I/O**: Per-client output queues separate message routing from TCP sending (inspired by high-performance C implementations)
- **Multiple Transports**: TCP (length-prefixed framing), UDP (stateless), Multicast (market data)
- **Multiple Codecs**: CSV (human-readable), Binary (low-latency), FIX 4.2 (industry standard)
- **NASA Power of Ten Compliant**: Bounded loops, extensive assertions, no dynamic allocation in hot path
- **Cross-Platform**: Linux (epoll) and macOS (kqueue) with optimized I/O
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

### Send a Test Order

```bash
# UDP (no framing needed)
echo "N, 1, AAPL, 15000, 100, B, 1" | nc -u -w1 localhost 1235

# TCP requires length-prefix framing - use the Python example below
```

See [docs/QUICK_START.md](docs/QUICK_START.md) for detailed setup instructions.

## Architecture Overview

The engine uses a **three-stage pipeline** with per-client output queues for maximum throughput:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              I/O Thread                                      │
│                                                                              │
│  ┌───────────┐  ┌───────────┐  ┌─────────────────────────┐                  │
│  │TCP Server │  │UDP Server │  │ Multicast Publisher     │                  │
│  │ :1234     │  │ :1235     │  │ 239.255.0.1:1236        │                  │
│  └─────┬─────┘  └─────┬─────┘  └───────────┬─────────────┘                  │
│        │              │                    │                                 │
│        └──────────────┼────────────────────┘                                 │
│                       │                                                      │
│              ┌────────▼────────┐                                             │
│              │  Symbol Router  │                                             │
│              │  (A-M → P0)     │                                             │
│              │  (N-Z → P1)     │                                             │
│              └────────┬────────┘                                             │
└───────────────────────┼─────────────────────────────────────────────────────┘
                        │
          ┌─────────────┴─────────────┐
          │                           │
    ┌─────▼─────┐               ┌─────▼─────┐
    │ SPSC Queue│               │ SPSC Queue│
    │  (256K)   │               │  (256K)   │
    └─────┬─────┘               └─────┬─────┘
          │                           │
┌─────────▼─────────┐       ┌─────────▼─────────┐
│   Processor 0     │       │   Processor 1     │
│   Symbols A-M     │       │   Symbols N-Z     │
│  ┌─────────────┐  │       │  ┌─────────────┐  │
│  │ OrderBooks  │  │       │  │ OrderBooks  │  │
│  │ MemoryPools │  │       │  │ MemoryPools │  │
│  └─────────────┘  │       └─────────────┘  │  │
└─────────┬─────────┘       └─────────┬─────────┘
          │                           │
    ┌─────▼─────┐               ┌─────▼─────┐
    │Output SPSC│               │Output SPSC│
    └─────┬─────┘               └─────┬─────┘
          │                           │
          └─────────────┬─────────────┘
                        │
┌───────────────────────▼─────────────────────────────────────────────────────┐
│                         Output Routing (I/O Thread)                          │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    Per-Client Output Queues                          │   │
│   │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐            │   │
│   │  │Client 1  │  │Client 2  │  │Client 3  │  │Client N  │            │   │
│   │  │Queue 32K │  │Queue 32K │  │Queue 32K │  │Queue 32K │            │   │
│   │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘            │   │
│   └───────┼─────────────┼─────────────┼─────────────┼───────────────────┘   │
│           │             │             │             │                        │
│           │         EPOLLOUT fires    │             │                        │
│           │             │             │             │                        │
│           ▼             ▼             ▼             ▼                        │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │              Batched TCP Send (drainToSocket)                        │   │
│   │         Multiple messages per send() syscall                         │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Design: Per-Client Output Queues

The v3 architecture introduces **per-client lock-free output queues** that decouple message routing from TCP sending:

1. **Fast Routing**: `queueOutput()` just pushes to a lock-free queue - no syscalls
2. **Batched Sending**: `drainToSocket()` batches multiple messages per `send()` syscall
3. **EPOLLOUT-Driven**: Actual TCP writes happen when the kernel signals socket readiness
4. **No Backpressure on Hot Path**: Routing never blocks on slow clients

This pattern is inspired by high-performance C matching engine implementations.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed design documentation.

## Project Structure

```
src/
├── core/                   # Matching engine core
│   ├── matching_engine.zig # Main engine orchestration
│   ├── order_book.zig      # Price-time priority order book
│   ├── order_map.zig       # O(1) order lookup by ID
│   ├── memory_pool.zig     # Fixed-size memory allocators
│   ├── order.zig           # Order data structures
│   └── output_buffer.zig   # Output message collection
│
├── protocol/               # Message encoding/decoding
│   ├── message_types.zig   # Input/Output message definitions
│   ├── codec.zig           # Protocol detection & routing
│   ├── csv_codec.zig       # Human-readable CSV format
│   ├── binary_codec.zig    # Low-latency binary format
│   └── fix_codec.zig       # FIX 4.2 protocol support
│
├── transport/              # Network I/O layer
│   ├── tcp_server.zig      # TCP with epoll/kqueue
│   ├── tcp_client.zig      # Per-connection state, buffers & output queue
│   ├── udp_server.zig      # Stateless UDP with client tracking
│   ├── multicast.zig       # Market data publisher/subscriber
│   ├── config.zig          # Configuration management
│   └── net_utils.zig       # Cross-platform network utilities
│
├── threading/              # Multi-threaded architecture
│   ├── threaded_server.zig # I/O thread + message routing + output dispatch
│   ├── processor.zig       # Matching processor threads
│   └── mod.zig             # Module exports
│
├── collections/            # Data structures
│   ├── spsc_queue.zig      # Lock-free single-producer/single-consumer
│   └── bounded_channel.zig # Higher-level channel abstraction
│
└── main.zig                # Entry point & signal handling
```

## Message Formats

### CSV Format (Human-Readable)

**Input Messages:**
```
# New Order: N, <user_id>, <symbol>, <price>, <qty>, <side>, <user_order_id>
N, 1001, AAPL, 15000, 100, B, 1

# Cancel: C, <user_id>, <user_order_id>, [symbol]
C, 1001, 1, AAPL

# Flush (testing only)
F
```

**Output Messages:**
```
# Acknowledgment: A, <symbol>, <user_id>, <user_order_id>
A, AAPL, 1001, 1

# Trade: T, <symbol>, <buy_uid>, <buy_oid>, <sell_uid>, <sell_oid>, <price>, <qty>
T, AAPL, 1001, 1, 1002, 1, 15000, 100

# Top of Book: B, <symbol>, <side>, <price>, <qty>
B, AAPL, B, 15000, 500

# Cancel Ack: C, <symbol>, <user_id>, <user_order_id>
C, AAPL, 1001, 1

# Reject: R, <symbol>, <user_id>, <user_order_id>, <reason>
R, AAPL, 1001, 1, 3
```

**Notes:**
- Price is in integer units (e.g., cents): 15000 = $150.00
- Side: `B` for buy, `S` for sell
- Whitespace around commas is optional

### Binary Format (Low-Latency)

All integers are **big-endian** (network byte order). Messages are variable-length with a magic byte prefix.

**New Order (27 bytes):**

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 1 | magic | 0x4D ('M') |
| 1 | 1 | msg_type | 0x4E ('N') |
| 2 | 4 | user_id | User identifier |
| 6 | 8 | symbol | Null-padded symbol |
| 14 | 4 | price | Price (integer) |
| 18 | 4 | quantity | Order quantity |
| 22 | 1 | side | 'B' (0x42) or 'S' (0x53) |
| 23 | 4 | user_order_id | User's order ID |

**Cancel (18 bytes):**

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | magic (0x4D) |
| 1 | 1 | msg_type (0x43 = 'C') |
| 2 | 4 | user_id |
| 6 | 8 | symbol |
| 14 | 4 | user_order_id |

**Trade (34 bytes):**

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | magic (0x4D) |
| 1 | 1 | msg_type (0x54 = 'T') |
| 2 | 8 | symbol |
| 10 | 4 | buy_user_id |
| 14 | 4 | buy_order_id |
| 18 | 4 | sell_user_id |
| 22 | 4 | sell_order_id |
| 26 | 4 | price |
| 30 | 4 | quantity |

### FIX 4.2 Format

Standard FIX protocol with SOH (0x01) or pipe ('|') delimiters:

```
8=FIX.4.2|9=73|35=D|1=1001|11=1|55=AAPL|54=1|38=100|40=2|44=15000|10=178|
```

Supported message types:
- `D` (NewOrderSingle)
- `F` (OrderCancelRequest)
- `8` (ExecutionReport)

## TCP Framing

TCP uses 4-byte **big-endian** length-prefix framing:

```
┌────────────────┬─────────────────────────────────┐
│  4 bytes (BE)  │         N bytes                 │
│  message len   │         payload                 │
└────────────────┴─────────────────────────────────┘
```

## Configuration

### Default Ports

| Transport | Port | Protocol |
|-----------|------|----------|
| TCP | 1234 | Length-prefixed messages |
| UDP | 1235 | Raw messages (no framing) |
| Multicast | 1236 | Market data (239.255.0.1) |

### Environment Variables

```bash
# Threading
ENGINE_THREADED=true          # Enable dual-processor mode

# TCP
ENGINE_TCP_ENABLED=true       # Enable TCP transport
ENGINE_TCP_PORT=1234          # TCP listen port
ENGINE_TCP_IDLE_TIMEOUT=300   # Idle disconnect (seconds)

# UDP
ENGINE_UDP_ENABLED=true       # Enable UDP transport
ENGINE_UDP_PORT=1235          # UDP listen port

# Multicast
ENGINE_MCAST_ENABLED=true     # Enable multicast publisher
ENGINE_MCAST_GROUP=239.255.0.1  # Multicast group address
ENGINE_MCAST_PORT=1236        # Multicast port
ENGINE_MCAST_TTL=1            # TTL (1 = local subnet)

# Performance
ENGINE_CHANNEL_CAPACITY=262144  # SPSC queue size (power of 2)
ENGINE_CLIENT_QUEUE_CAPACITY=32768  # Per-client output queue
ENGINE_BINARY_PROTOCOL=false  # Use binary instead of CSV
```

### Command Line Options

```bash
matching_engine [OPTIONS]

Options:
  -h, --help       Show help message
  -v, --version    Show version information
  -t, --threaded   Run in dual-processor mode
  --verbose        Enable verbose logging
```

## Performance Characteristics

| Metric | Target | Notes |
|--------|--------|-------|
| Latency (p50) | < 10 μs | Order entry to ack |
| Latency (p99) | < 50 μs | Including queue wait |
| Throughput | > 200K orders/sec | Per processor |
| Memory | ~100 MB | Fixed allocation at startup |

### v3 Architecture Benefits

The per-client output queue architecture provides:

- **No routing bottleneck**: `queueOutput()` is just a lock-free push (~10-50ns)
- **Batched syscalls**: Multiple messages per `send()` reduces kernel overhead
- **Client isolation**: Slow clients don't block fast clients
- **Graceful degradation**: Per-client queue overflow is isolated

## Client Examples

### Python (CSV over TCP)

```python
import socket
import struct

def send_order(sock, msg: bytes):
    """Send with 4-byte big-endian length prefix."""
    sock.send(struct.pack('>I', len(msg)) + msg)

def recv_response(sock) -> bytes:
    """Receive length-prefixed response."""
    length = struct.unpack('>I', sock.recv(4))[0]
    return sock.recv(length)

# Connect
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 1234))

# Send new order
msg = b"N, 1001, AAPL, 15000, 100, B, 1\n"
send_order(sock, msg)

# Receive ack
response = recv_response(sock)
print(response.decode())  # A, AAPL, 1001, 1

sock.close()
```

### Python (Binary over UDP)

```python
import socket
import struct

def make_new_order(user_id, symbol, price, qty, side, order_id):
    """Create binary new order message (27 bytes)."""
    return struct.pack(
        '>BB I 8s I I B I',
        0x4D,                           # magic
        ord('N'),                       # msg_type
        user_id,
        symbol.encode().ljust(8, b'\x00'),
        price,
        qty,
        ord(side),
        order_id
    )

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
msg = make_new_order(1001, "AAPL", 15000, 100, 'B', 1)
sock.sendto(msg, ('localhost', 1235))
```

### netcat (CSV over UDP)

```bash
# Send order
echo "N, 1001, AAPL, 15000, 100, B, 1" | nc -u -w1 localhost 1235
```

## Building from Source

### Requirements

- Zig 0.13.0 or later
- Linux or macOS (Windows not currently supported)
- Make (optional, for convenience targets)

### Build Commands

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run with arguments
zig build run -- --threaded

# Run all tests
zig build test

# Generate documentation
zig build docs
```

## Testing

```bash
# Run all tests
make test

# Run with verbose output
zig build test --summary all

# Type-check without codegen (fast)
make check
```

## Safety & Reliability

This codebase follows the **NASA Power of Ten** rules for safety-critical software:

1. **Simple Control Flow**: No goto, setjmp, or recursion
2. **Bounded Loops**: All loops have explicit iteration limits
3. **No Dynamic Allocation in Hot Path**: Fixed-size buffers, pool allocators
4. **Short Functions**: Most functions ≤60 lines
5. **High Assertion Density**: Debug assertions validate invariants
6. **Minimal Scope**: Variables declared at narrowest scope
7. **Check All Returns**: All errors propagated or handled explicitly
8. **Limited Preprocessor**: Minimal comptime complexity
9. **Pointer Discipline**: No raw pointer arithmetic on untrusted data
10. **Compiler Warnings**: ReleaseSafe mode for production

## Reject Reason Codes

| Code | Reason |
|------|--------|
| 1 | Unknown symbol |
| 2 | Invalid quantity |
| 3 | Invalid price |
| 4 | Order not found |
| 5 | Duplicate order ID |
| 6 | Pool exhausted |
| 7 | Unauthorized |
| 8 | Throttled |
| 9 | Book full |
| 10 | Invalid order ID |

## Version History

### v3.0 (Current)
- **Per-client output queues**: Decoupled routing from TCP sending
- **EPOLLOUT-driven writes**: Batched sends when socket is ready
- **Improved throughput**: 5-10x improvement in sustained message rates
- **Client isolation**: Slow clients don't impact fast clients

### v2.0
- Dual-processor architecture
- Symbol-based partitioning
- Lock-free SPSC queues

### v1.0
- Single-threaded matching engine
- Basic TCP/UDP support
