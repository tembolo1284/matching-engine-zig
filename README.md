# Zig Matching Engine

A high-performance, multi-protocol, multi-transport order matching engine written in Zig, featuring dual-processor architecture with lock-free message passing. Designed following HFT low-latency principles and NASA Power of Ten safety-critical coding rules.

Wire-compatible with the C matching engine implementation.

## Features

### Performance
- **Zero-allocation hot path** — Pre-allocated memory pools, no heap allocation during trading
- **Cache-optimized** — 64-byte aligned structures, sequential memory access
- **Lock-free queues** — SPSC queues for inter-thread communication
- **Dual-processor mode** — Parallel matching with symbol-based routing (A-M / N-Z)
- **UDP batching** — Multiple messages per packet for high throughput (~77 msgs/packet)

### Networking
- **TCP** — Multi-client with epoll, 4-byte length-prefix framing
- **UDP** — Bidirectional request/response with message batching
- **Multicast** — Market data broadcast for unlimited subscribers
- **Large buffers** — 8MB kernel buffers for burst handling

### Protocols
- **Binary** — High-performance, network byte order, magic byte `0x4D`
- **CSV** — Human-readable, newline-delimited
- **Auto-detection** — Protocol detected from first byte
- **Protocol-aware responses** — Server responds in client's detected protocol

### Architecture
- **Single-threaded mode** — Simple, low-latency for moderate load
- **Threaded mode** — Dual processors with I/O thread separation

## Quick Start

### Prerequisites
- Zig 0.13.0 or later (`zig version` to check)
- netcat (`nc`) for testing
- Optional: Docker for containerized deployment

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
make run-threaded-csv  # Dual-processor with CSV banner
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

## Linux Kernel Tuning (Important!)

For high-throughput UDP scenarios (10K+ orders), increase kernel buffer limits:

```bash
# Check current limits
cat /proc/sys/net/core/rmem_max
cat /proc/sys/net/core/wmem_max

# Increase to 8MB (required for stress tests)
sudo sysctl -w net.core.rmem_max=8388608
sudo sysctl -w net.core.wmem_max=8388608

# Make permanent (add to /etc/sysctl.conf)
echo "net.core.rmem_max=8388608" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=8388608" | sudo tee -a /etc/sysctl.conf
```

Without this tuning, the server will only get ~208KB buffers instead of the requested 8MB, causing packet loss under load.

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
| Reject | 'R' (0x52) | 19 bytes |

### TCP Framing

TCP uses 4-byte big-endian length prefix:
```
[4 bytes: length][N bytes: payload]
```

UDP packets contain raw messages (no framing).

### Protocol-Aware Encoding

The server automatically detects each client's protocol from their first message and responds in the same format:

| Client Sends | Server Responds |
|--------------|-----------------|
| Binary (0x4D magic) | Binary |
| CSV (text) | CSV |

**UDP Batching**: CSV responses are batched into ~1400-byte packets (multiple messages per packet, newline-delimited). Binary responses are sent one message per packet (fixed-size, no delimiter).

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
matching-engine-zig/
├── build.zig               # Build configuration
├── build.zig.zon           # Package metadata
├── Makefile                # Development shortcuts
├── Dockerfile              # Container build
├── docker-compose.yml      # Container orchestration
├── README.md
└── src/
    ├── main.zig                    # Entry point
    │
    ├── core/                       # Matching engine core
    │   ├── order.zig               # Order struct (64-byte aligned)
    │   ├── order_book.zig          # Price-time priority matching
    │   ├── matching_engine.zig     # Multi-symbol orchestrator
    │   └── memory_pool.zig         # Pre-allocated pools
    │
    ├── protocol/                   # Wire protocols
    │   ├── mod.zig                 # Module exports
    │   ├── message_types.zig       # Message definitions
    │   ├── codec.zig               # Protocol detection
    │   ├── binary_codec.zig        # Binary encoder/decoder
    │   ├── csv_codec.zig           # CSV encoder/decoder
    │   └── fix_codec.zig           # FIX protocol (stub)
    │
    ├── transport/                  # Network layer
    │   ├── config.zig              # Configuration
    │   ├── net_utils.zig           # Shared network utilities
    │   ├── tcp_client.zig          # Per-connection state
    │   ├── tcp_server.zig          # Multi-client TCP with epoll
    │   ├── udp_server.zig          # Bidirectional UDP with batching
    │   ├── multicast.zig           # Market data multicast
    │   └── server.zig              # Single-threaded server
    │
    ├── collections/                # Data structures
    │   ├── mod.zig                 # Module exports
    │   ├── spsc_queue.zig          # Lock-free SPSC queue
    │   └── bounded_channel.zig     # Typed message channel
    │
    ├── threading/                  # Multi-threaded mode
    │   ├── mod.zig                 # Module exports
    │   ├── processor.zig           # Matching processor thread
    │   └── threaded_server.zig     # Dual-processor server
    │
    ├── bench/                      # Benchmarks
    │   └── main.zig
    │
    └── tools/                      # Utilities
        └── client.zig              # Test client
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
│  ┌─────────────────────────────────────────────────────┐   │
│  │              UDP Batch Manager                       │   │
│  │  Accumulates messages per client, flushes at 1400B  │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

- I/O isolated from matching
- Parallel matching by symbol range
- Lock-free SPSC queues (65,536 capacity)
- UDP batching reduces packet count by ~98%
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

Measured in threaded mode: **~932ns average** (includes I/O overhead)

### Throughput Results

| Scenario | Orders | ACK Rate | Notes |
|----------|--------|----------|-------|
| Stress 1K | 1,000 | 100% | Baseline |
| Stress 10K | 10,000 | 100% | With client throttling |
| Stress 100K | 100,000 | 100% | 1,304 UDP batches, 16MB kernel buffer |
| Stress 1M | 1,000,000 | 34% | Needs architectural changes |

**100K Test Details:**
- Client send rate: 62K orders/sec
- Server processed: 100,002 messages
- Server outputs: 109,700 (ACKs + Top of Book)
- UDP batches: 1,304 packets (~77 msgs/packet)
- Client received: 100% ACKs

### Client Requirements for Stress Tests

For reliable high-throughput testing, clients should:

1. **Throttle sends** — Small batches (200-500 orders) with delays (10-45ms)
2. **Large recv buffers** — 8MB kernel buffer to handle bursts
3. **Parse batched responses** — Loop through newline-delimited messages
4. **Settle time** — Wait 500-2000ms after sending before draining responses

## Make Targets
```bash
make                  # Build debug
make release          # Build optimized
make run              # Run single-threaded
make run-threaded     # Run dual-processor
make run-threaded-csv # Run dual-processor (CSV banner)
make test             # Run all tests
make bench            # Run benchmarks
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

# Test
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 1235
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

## Troubleshooting

### UDP Packet Loss at High Volume

**Symptoms:** Client receives fewer ACKs than orders sent (e.g., 55% instead of 100%)

**Solutions:**
1. Increase kernel buffer limits (see Linux Kernel Tuning section)
2. Ensure client throttles sends appropriately
3. Check server logs for "Messages dropped" or "Backpressure" counts

### Binary Client Gets CSV Responses

**Cause:** Protocol detection happens on first packet. Ensure first message uses binary format.

**Solution:** Server now tracks protocol per client and responds accordingly.

### TCP Client Disconnects Early

**Symptoms:** Missing responses, client shows fewer ACKs than server sent

**Cause:** Client drain timeout too short

**Solution:** Increase client's drain timeout (5-10 seconds for 100K+ orders)

## Documentation

- [QUICK_START.md](docs/QUICK_START.md) — Get running in 5 minutes
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — Deep dive into system design
- [DOCKER.md](docs/DOCKER.md) — Container deployment guide
