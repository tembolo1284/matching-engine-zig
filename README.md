# Zig Matching Engine

A high-performance, multi-protocol, multi-transport order matching engine written in Zig, featuring dual-processor architecture with lock-free message passing. Designed following HFT low-latency principles and NASA Power of Ten safety-critical coding rules.

Wire-compatible with the C matching engine implementation.

## Features

### Performance
- **Zero-allocation hot path** — Pre-allocated memory pools, no heap allocation during trading
- **Cache-optimized** — 64-byte aligned structures, sequential memory access
- **Lock-free queues** — SPSC queues for inter-thread communication
- **Dual-processor mode** — Parallel matching with symbol-based routing

### Networking
- **TCP** — Multi-client with epoll, 4-byte length-prefix framing
- **UDP** — Bidirectional request/response, no framing needed
- **Multicast** — Market data broadcast for unlimited subscribers

### Protocols
- **CSV** — Human-readable, newline-delimited
- **Binary** — High-performance, network byte order, magic byte `0x4D`
- **Auto-detection** — Protocol detected from first byte

### Architecture
- **Single-threaded mode** — Simple, low-latency for moderate load
- **Threaded mode** — Dual processors (A-M / N-Z), I/O thread separation

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
# Single-threaded mode (default)
zig build run

# Dual-processor threaded mode
ENGINE_THREADED=true zig build run

# Or use make
make run            # Single-threaded
make run-threaded   # Dual-processor
```

### Test with Orders
```bash
# Terminal 1: Start server
make run

# Terminal 2: Send orders via UDP (no framing needed)
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 1235
echo "N, 2, IBM, 10000, 50, S, 1" | nc -u -w1 localhost 1235

# Expected output:
# A, IBM, 1, 1           <- Buy order acknowledged
# B, IBM, B, 10000, 100  <- Top of book update
# A, IBM, 2, 1           <- Sell order acknowledged  
# T, IBM, 1, 1, 2, 1, 10000, 50  <- Trade executed!
# B, IBM, B, 10000, 50   <- Remaining quantity
```

## Protocol Formats

### CSV Input
```
N, userId, symbol, price, qty, side, orderId    # New Order
C, userId, orderId                               # Cancel Order
F                                                # Flush All Orders
```

### CSV Output
```
A, symbol, userId, orderId                       # Acknowledgement
T, symbol, buyUid, buyOid, sellUid, sellOid, price, qty  # Trade
B, symbol, side, price, qty                      # Top of Book
C, symbol, userId, orderId                       # Cancel Ack
R, symbol, userId, orderId, reason               # Reject
```

### Binary Protocol

| Field | Description |
|-------|-------------|
| Magic | `0x4D` ('M') |
| Byte order | Big-endian (network) |
| Symbols | 8 bytes, null-padded |

| Message | Type Byte | Size |
|---------|-----------|------|
| New Order | 'N' (0x4E) | 27 bytes |
| Cancel | 'C' (0x43) | 10 bytes |
| Flush | 'F' (0x46) | 2 bytes |
| Ack | 'A' (0x41) | 18 bytes |
| Trade | 'T' (0x54) | 34 bytes |
| Top of Book | 'B' (0x42) | 20 bytes |

### TCP Framing

TCP uses 4-byte big-endian length prefix:
```
[4 bytes: length][N bytes: payload]
```

UDP packets contain raw messages (no framing).

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ENGINE_THREADED` | `false` | Enable dual-processor mode |
| `ENGINE_TCP_ENABLED` | `true` | Enable TCP transport |
| `ENGINE_TCP_PORT` | `1234` | TCP port |
| `ENGINE_UDP_ENABLED` | `true` | Enable UDP transport |
| `ENGINE_UDP_PORT` | `1235` | UDP port |
| `ENGINE_MCAST_ENABLED` | `true` | Enable multicast |
| `ENGINE_MCAST_GROUP` | `239.255.0.1` | Multicast group |
| `ENGINE_MCAST_PORT` | `1236` | Multicast port |

### Example
```bash
ENGINE_THREADED=true \
ENGINE_TCP_PORT=8000 \
ENGINE_UDP_PORT=8001 \
zig build run
```

## Project Structure
```
zig_matching_engine/
├── build.zig
├── Makefile
├── Dockerfile
├── README.md
├── ARCHITECTURE.md
├── QUICK_START.md
├── DOCKER.md
└── src/
    ├── main.zig                 # Entry point
    ├── core/
    │   ├── order.zig            # Order struct (64-byte aligned)
    │   ├── order_book.zig       # Price-time priority matching
    │   ├── matching_engine.zig  # Multi-symbol orchestrator
    │   └── memory_pool.zig      # Pre-allocated pools
    ├── protocol/
    │   ├── message_types.zig    # Message definitions
    │   ├── codec.zig            # Protocol detection
    │   ├── binary_codec.zig     # Binary encoder/decoder
    │   ├── csv_codec.zig        # CSV encoder/decoder
    │   └── fix_codec.zig        # FIX protocol (placeholder)
    ├── transport/
    │   ├── config.zig           # Configuration
    │   ├── tcp_server.zig       # Multi-client TCP with epoll
    │   ├── udp_server.zig       # Bidirectional UDP
    │   ├── multicast.zig        # Market data multicast
    │   └── server.zig           # Single-threaded unified server
    ├── collections/
    │   ├── mod.zig
    │   ├── spsc_queue.zig       # Lock-free SPSC queue
    │   └── bounded_channel.zig  # Typed message channel
    └── threading/
        ├── mod.zig
        ├── processor.zig        # Matching processor thread
        └── threaded_server.zig  # Dual-processor server
```

## Operating Modes

### Single-Threaded Mode (Default)
```
┌─────────────────────────────────────────┐
│              Event Loop                  │
│  ┌─────┐  ┌─────┐  ┌───────────────┐   │
│  │ TCP │  │ UDP │  │   Multicast   │   │
│  └──┬──┘  └──┬──┘  └───────┬───────┘   │
│     └────────┼─────────────┘           │
│              ▼                          │
│     ┌────────────────┐                  │
│     │MatchingEngine  │                  │
│     └────────────────┘                  │
└─────────────────────────────────────────┘
```

- Simple, single event loop
- All processing in one thread
- Lowest latency for light loads
- Best for < 100K messages/sec

### Dual-Processor Threaded Mode
```
┌─────────────────────────────────────────────────────────────┐
│                       I/O Thread                             │
│  ┌─────┐  ┌─────┐  ┌───────────┐                           │
│  │ TCP │  │ UDP │  │ Multicast │                           │
│  └──┬──┘  └──┬──┘  └─────┬─────┘                           │
│     └────────┼───────────┘                                  │
│              ▼                                               │
│     ┌─────────────────┐                                     │
│     │  Symbol Router  │  (A-M → P0, N-Z → P1)               │
│     └────────┬────────┘                                     │
└──────────────┼──────────────────────────────────────────────┘
               │
      ┌────────┴────────┐
      ▼                 ▼
┌──────────┐      ┌──────────┐
│ SPSC In  │      │ SPSC In  │   Lock-free queues
└────┬─────┘      └────┬─────┘
     ▼                 ▼
┌──────────┐      ┌──────────┐
│Processor0│      │Processor1│   Matching threads
│  (A-M)   │      │  (N-Z)   │
└────┬─────┘      └────┬─────┘
     ▼                 ▼
┌──────────┐      ┌──────────┐
│ SPSC Out │      │ SPSC Out │   Lock-free queues
└────┬─────┘      └────┬─────┘
     └────────┬────────┘
              ▼
┌─────────────────────────────────────────────────────────────┐
│                 I/O Thread (dispatch)                        │
└─────────────────────────────────────────────────────────────┘
```

- I/O isolated from matching
- Parallel matching by symbol range
- Lock-free SPSC queues (65,536 capacity)
- Best for > 100K messages/sec

### Symbol Routing

| Symbol Range | Processor | Examples |
|--------------|-----------|----------|
| A-M | Processor 0 | AAPL, IBM, META, GOOG |
| N-Z | Processor 1 | NVDA, TSLA, UBER, ZM |

Cancel and Flush messages are sent to **both** processors.

## Performance

### Memory Footprint

| Component | Size | Notes |
|-----------|------|-------|
| Order Pool | 8 MB | 131,072 × 64 bytes |
| Order Map | 8 MB | 262,144 slots |
| SPSC Queues | 16 MB | 4 × 65,536 × 64 bytes |
| **Total** | ~35 MB | Per engine instance |

### Estimated Latency

| Operation | Single-threaded | Threaded |
|-----------|-----------------|----------|
| Message decode | ~20 ns | ~20 ns |
| Queue transit | N/A | ~50 ns |
| Match + insert | ~50 ns | ~50 ns |
| Message encode | ~15 ns | ~15 ns |
| **Total** | **~100 ns** | **~150 ns** |

### Throughput

| Mode | Messages/sec |
|------|--------------|
| Single-threaded | 5-10 M |
| Dual-processor | 8-15 M |

## Make Targets
```bash
make                  # Build debug
make release          # Build optimized
make run              # Run single-threaded
make run-threaded     # Run dual-processor
make test             # Run all tests
make clean            # Clean build artifacts
make docker           # Build Docker image
make docker-run       # Run in Docker
make help             # Show all targets
```

## Docker
```bash
# Build
docker build -t zig-matching-engine .

# Run (single-threaded)
docker run -p 1234:1234 -p 1235:1235/udp zig-matching-engine

# Run (threaded)
docker run -e ENGINE_THREADED=true -p 1234:1234 -p 1235:1235/udp zig-matching-engine
```

## C Protocol Compatibility

This implementation is wire-compatible with the C matching engine:

| Aspect | Specification |
|--------|---------------|
| Magic byte | `0x4D` ('M') |
| Byte order | Big-endian (network) |
| TCP framing | 4-byte length prefix |
| CSV format | Identical field order |
| Symbol routing | A-M → P0, N-Z → P1 |

## Documentation

- [QUICK_START.md](QUICK_START.md) — Get running in 5 minutes
- [ARCHITECTURE.md](ARCHITECTURE.md) — Deep dive into system design
- [DOCKER.md](DOCKER.md) — Container deployment guide

