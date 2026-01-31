# Architecture

This document provides a technical deep-dive into the Zig Matching Engine architecture, covering threading model, data structures, memory layout, and protocol specifications.

## Table of Contents

1. [System Overview](#system-overview)
2. [Threading Model](#threading-model)
3. [Data Flow](#data-flow)
4. [Core Components](#core-components)
5. [Memory Layout](#memory-layout)
6. [Protocol Specification](#protocol-specification)
7. [Performance Optimizations](#performance-optimizations)
8. [Design Decisions](#design-decisions)

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Zig Matching Engine                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐     ┌─────────────────┐     ┌──────────────────────────┐ │
│  │    Client    │────▶│  Accept Thread  │────▶│  Client Handler Thread   │ │
│  │  (TCP Conn)  │     └─────────────────┘     │  (one per connection)    │ │
│  └──────────────┘                              └────────────┬─────────────┘ │
│                                                             │               │
│                                                             ▼               │
│                                              ┌──────────────────────────┐   │
│                                              │   Global Input Queue     │   │
│                                              │   (SPSC, 32K slots)      │   │
│                                              └────────────┬─────────────┘   │
│                                                           │                 │
│                                                           ▼                 │
│                                              ┌──────────────────────────┐   │
│                                              │   Processor Thread       │   │
│                                              │   ┌──────────────────┐   │   │
│                                              │   │ Matching Engine  │   │   │
│                                              │   │  ┌────────────┐  │   │   │
│                                              │   │  │ OrderBook  │  │   │   │
│                                              │   │  │ (per sym)  │  │   │   │
│                                              │   │  └────────────┘  │   │   │
│                                              │   └──────────────────┘   │   │
│                                              └────────────┬─────────────┘   │
│                                                           │                 │
│                                                           ▼                 │
│                                              ┌──────────────────────────┐   │
│                                              │   Global Output Queue    │   │
│                                              │   (SPSC, 32K slots)      │   │
│                                              └────────────┬─────────────┘   │
│                                                           │                 │
│                                                           ▼                 │
│  ┌──────────────┐     ┌──────────────────┐  ┌──────────────────────────┐   │
│  │    Client    │◀────│ Per-Client Queue │◀─│    Router Thread         │   │
│  │  (TCP Conn)  │     │   (32K slots)    │  │  (broadcasts/routes)     │   │
│  └──────────────┘     └──────────────────┘  └──────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Threading Model

### The TCP Backpressure Problem

In a naive single-threaded TCP server, one thread handles everything: accepting connections, reading from sockets, processing orders, and writing responses. This creates a deadlock scenario:

```
Client sends orders very fast
         ↓
Server reads orders → input queue fills
         ↓
Server processes orders → output queue fills
         ↓
Server tries to send responses → TCP send buffer fills
         ↓
Client's receive buffer fills (client busy sending, not reading)
         ↓
TCP flow control kicks in → server's send() returns WouldBlock
         ↓
Server stuck trying to send → STOPS reading new orders
         ↓
DEADLOCK: Server won't read until it can send
          Client won't read until it can send
```

### The Solution: Thread-Per-Client Architecture

The engine uses dedicated threads to decouple all I/O operations:

| Thread | Count | Responsibility |
|--------|-------|----------------|
| **Accept Thread** | 1 | Accepts new TCP connections, spawns client handlers |
| **Client Handler** | N (per client) | Reads from socket, writes to socket, manages per-client state |
| **Processor Thread** | 1 | Processes input queue through matching engine, generates output |
| **Router Thread** | 1 | Routes output messages to per-client output queues |

### Thread Communication

```
Client Handler ──push──▶ Global Input Queue ──pop──▶ Processor
                         (InputEnvelopeQueue)
                         
Processor ──push──▶ Global Output Queue ──pop──▶ Router
                    (OutputEnvelopeQueue)
                    
Router ──push──▶ Per-Client Output Queue ──pop──▶ Client Handler
                 (ClientOutputQueue)
```

All queues are **lock-free SPSC** (Single-Producer Single-Consumer), eliminating mutex contention.

### Per-Client Output Queues

Each client has its own 32,768-slot output queue. This is critical:

- A slow client (backpressure on send) doesn't block other clients
- The router can keep routing even when one client is congested
- Reading and writing happen concurrently within each client handler

---

## Data Flow

### Order Submission Flow

```
1. TCP bytes arrive at client socket
2. Client Handler reads bytes into StreamParser
3. StreamParser decodes complete message (binary protocol)
4. Handler wraps message in InputEnvelope with client_id
5. Handler pushes to Global Input Queue (spins if full)
6. Processor pops InputEnvelope
7. Processor calls MatchingEngine.processMessage()
8. MatchingEngine routes to appropriate OrderBook
9. OrderBook generates output messages (Ack, Trade, etc.)
10. Processor wraps outputs in OutputEnvelope
11. Processor pushes to Global Output Queue
12. Router pops OutputEnvelope
13. Router routes to target client(s):
    - client_id=0 → broadcast to all
    - client_id=N → specific client only
14. Router pushes to Per-Client Output Queue
15. Client Handler pops from its output queue
16. Handler encodes and sends over TCP
```

### Backpressure Handling

The processor implements careful backpressure handling to prevent message loss:

```zig
// Processor tracks output drain index to resume if queue was full
output_drain_index: u32

fn drainOutputToQueue(self: *Self, output_queue: *OutputEnvelopeQueue) u32 {
    // Resume draining where we left off
    var i: u32 = self.output_drain_index;
    while (i < total) : (i += 1) {
        if (output_queue.push(envelope)) {
            self.output_drain_index = i + 1;
        } else {
            // Queue full - remember position for later
            return drained;
        }
    }
}
```

---

## Core Components

### Order (64 bytes)

Cache-line aligned order structure prevents false sharing between adjacent orders:

```
┌─────────────────────────────────────────────────────────────────┐
│ Bytes 0-19: Hot Fields (accessed during matching)               │
│ ┌─────────┬─────────────┬───────┬──────────┬───────────────┐   │
│ │ user_id │ user_order  │ price │ quantity │ remaining_qty │   │
│ │ (4B)    │ _id (4B)    │ (4B)  │ (4B)     │ (4B)          │   │
│ └─────────┴─────────────┴───────┴──────────┴───────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│ Bytes 20-31: Metadata                                           │
│ ┌──────┬────────────┬────────┬───────────┬─────────┐           │
│ │ side │ order_type │ pad[2] │ client_id │ pad[4]  │           │
│ │ (1B) │ (1B)       │        │ (4B)      │         │           │
│ └──────┴────────────┴────────┴───────────┴─────────┘           │
├─────────────────────────────────────────────────────────────────┤
│ Bytes 32-39: Timestamp (u64)                                    │
├─────────────────────────────────────────────────────────────────┤
│ Bytes 40-55: Linked List Pointers                               │
│ ┌──────────────────────┬──────────────────────┐                 │
│ │ next: ?*Order (8B)   │ prev: ?*Order (8B)   │                 │
│ └──────────────────────┴──────────────────────┘                 │
├─────────────────────────────────────────────────────────────────┤
│ Bytes 56-63: Padding to cache line                              │
└─────────────────────────────────────────────────────────────────┘
                        Total: 64 bytes (one cache line)
```

### OrderBook

Single-symbol order book with price-time priority:

```
┌─────────────────────────────────────────────────────────────────┐
│                         OrderBook                                │
├─────────────────────────────────────────────────────────────────┤
│ symbol: [16]u8                                                   │
├─────────────────────────────────────────────────────────────────┤
│ Bids (sorted by price descending)                               │
│ ┌───────────────────────────────────────────────────────────┐   │
│ │ PriceLevel[0]: price=105, qty=1000, orders→[O1]→[O2]→... │   │
│ │ PriceLevel[1]: price=104, qty=500,  orders→[O3]→...      │   │
│ │ PriceLevel[2]: price=103, qty=200,  orders→[O4]          │   │
│ │ ... (up to 512 levels)                                    │   │
│ └───────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│ Asks (sorted by price ascending)                                │
│ ┌───────────────────────────────────────────────────────────┐   │
│ │ PriceLevel[0]: price=106, qty=800,  orders→[O5]→[O6]→... │   │
│ │ PriceLevel[1]: price=107, qty=300,  orders→[O7]          │   │
│ │ ... (up to 512 levels)                                    │   │
│ └───────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│ order_map: Open-addressing hash table (16K slots)               │
│   Key: (user_id << 32) | user_order_id                          │
│   Value: OrderLocation { side, price, order_ptr }               │
├─────────────────────────────────────────────────────────────────┤
│ pool: OrderPool (8K pre-allocated orders)                       │
└─────────────────────────────────────────────────────────────────┘
```

### MatchingEngine

Multi-symbol orchestrator:

```
┌─────────────────────────────────────────────────────────────────┐
│                      MatchingEngine                              │
├─────────────────────────────────────────────────────────────────┤
│ symbol_map: Hash table (512 slots)                              │
│   "IBM"  → book_index=0                                         │
│   "AAPL" → book_index=1                                         │
│   ...                                                            │
├─────────────────────────────────────────────────────────────────┤
│ order_to_symbol: Hash table (8K slots)                          │
│   (user_id, order_id) → symbol                                  │
│   Used for cancel lookups                                        │
├─────────────────────────────────────────────────────────────────┤
│ books: [64]OrderBook                                            │
│   books[0]: IBM                                                  │
│   books[1]: AAPL                                                 │
│   ...                                                            │
└─────────────────────────────────────────────────────────────────┘
```

### SPSC Queue

Lock-free single-producer single-consumer queue with cache-line separation:

```
┌─────────────────────────────────────────────────────────────────┐
│                        SpscQueue<T>                              │
├─────────────────────────────────────────────────────────────────┤
│ Cache Line 0: Producer-owned                                     │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ head: AtomicU64 (producer writes, consumer reads)           │ │
│ │ _pad: [56]u8                                                 │ │
│ └─────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│ Cache Line 1: Consumer-owned                                     │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ tail: AtomicU64 (consumer writes, producer reads)           │ │
│ │ _pad: [56]u8                                                 │ │
│ └─────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│ Cache Line 2+: Local caches (reduce atomic reads)               │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ cached_head: u64 (consumer's local copy of head)            │ │
│ │ cached_tail: u64 (producer's local copy of tail)            │ │
│ └─────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│ Data: [capacity]T (power-of-2 for fast masking)                 │
└─────────────────────────────────────────────────────────────────┘
```

Key optimizations:
- **Cache-line separation**: head and tail on different cache lines prevents false sharing
- **Cached values**: Producer caches tail, consumer caches head to reduce atomic operations
- **Power-of-2 capacity**: `index & (capacity - 1)` instead of modulo

---

## Memory Layout

### Envelope Structures (64 bytes each)

```
InputEnvelope (64 bytes):
┌────────────────────────────────────────┐
│ message: InputMsg (40 bytes)           │
│ client_id: u32 (4 bytes)               │
│ _pad: [20]u8                           │
└────────────────────────────────────────┘

OutputEnvelope (64 bytes):
┌────────────────────────────────────────┐
│ message: OutputMsg (52 bytes)          │
│ client_id: u32 (4 bytes)               │
│ sequence: u64 (8 bytes)                │
└────────────────────────────────────────┘
```

### Queue Capacities

| Queue | Capacity | Element Size | Total Memory |
|-------|----------|--------------|--------------|
| Global Input Queue | 32,768 | 64 bytes | 2 MB |
| Global Output Queue | 32,768 | 64 bytes | 2 MB |
| Per-Client Output Queue | 32,768 | 52 bytes | ~1.7 MB |

### Pre-allocated Pools

| Pool | Capacity | Element Size | Total Memory |
|------|----------|--------------|--------------|
| Order Pool (per book) | 8,192 | 64 bytes | 512 KB |
| Price Levels (per book) | 512 × 2 | 64 bytes | 64 KB |

---

## Protocol Specification

### Binary Protocol

All messages use big-endian byte order. Magic byte: `0x4D` ('M').

#### New Order (27 bytes)

```
Offset  Size  Field
──────  ────  ─────────────────
0       1     Magic (0x4D)
1       1     Type ('N')
2       4     user_id (u32 BE)
6       8     symbol (8 chars, null-padded)
14      4     price (u32 BE, 0=market)
18      4     quantity (u32 BE)
22      1     side ('B'=buy, 'S'=sell)
23      4     user_order_id (u32 BE)
```

#### Cancel (10 bytes)

```
Offset  Size  Field
──────  ────  ─────────────────
0       1     Magic (0x4D)
1       1     Type ('C')
2       4     user_id (u32 BE)
6       4     user_order_id (u32 BE)
```

#### Flush (2 bytes)

```
Offset  Size  Field
──────  ────  ─────────────────
0       1     Magic (0x4D)
1       1     Type ('F')
```

#### Ack (18 bytes)

```
Offset  Size  Field
──────  ────  ─────────────────
0       1     Magic (0x4D)
1       1     Type ('A')
2       8     symbol (8 chars)
10      4     user_id (u32 BE)
14      4     user_order_id (u32 BE)
```

#### Cancel Ack (18 bytes)

```
Offset  Size  Field
──────  ────  ─────────────────
0       1     Magic (0x4D)
1       1     Type ('X')
2       8     symbol (8 chars)
10      4     user_id (u32 BE)
14      4     user_order_id (u32 BE)
```

#### Trade (34 bytes)

```
Offset  Size  Field
──────  ────  ─────────────────
0       1     Magic (0x4D)
1       1     Type ('T')
2       8     symbol (8 chars)
10      4     user_id_buy (u32 BE)
14      4     user_order_id_buy (u32 BE)
18      4     user_id_sell (u32 BE)
22      4     user_order_id_sell (u32 BE)
26      4     price (u32 BE)
30      4     quantity (u32 BE)
```

#### Top of Book (19 bytes)

```
Offset  Size  Field
──────  ────  ─────────────────
0       1     Magic (0x4D)
1       1     Type ('B')
2       8     symbol (8 chars)
10      1     side ('B'=buy, 'S'=sell)
11      4     price (u32 BE, 0=eliminated)
15      4     quantity (u32 BE, 0=eliminated)
```

### FIX Protocol

*FIX 4.2 protocol support is planned for a future release. The architecture supports multiple protocols through the `StreamParser` abstraction in `framing.zig`.*

---

## Performance Optimizations

### 1. Cache-Line Alignment

All frequently-accessed structures are 64-byte aligned:

```zig
pub const Order = extern struct {
    // ... fields ...
    comptime {
        std.debug.assert(@sizeOf(Order) == 64);
    }
};
```

This prevents false sharing when multiple threads access adjacent memory.

### 2. RDTSCP Timestamps

On x86-64, orders use the hardware timestamp counter for minimal-latency time priority:

```zig
inline fn rdtscp() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtscp"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .ecx = true }
    );
    return (@as(u64, hi) << 32) | lo;
}
```

~5-10 CPU cycles vs ~20-50ns for `clock_gettime()`.

### 3. Open-Addressing Hash Tables

All hash tables use open-addressing with linear probing:

- No pointer chasing (cache-friendly)
- Power-of-2 sizes for fast masking
- Tombstone-based deletion
- Bounded probe lengths (Power of Ten Rule 2)

```zig
const hash = hashOrderKey(key);
var i: u32 = 0;
while (i < MAX_PROBE_LENGTH) : (i += 1) {
    const idx = (hash + i) & ORDER_MAP_MASK;
    // ...
}
```

### 4. Batch Processing

The processor handles messages in batches to amortize overhead:

```zig
pub const BATCH_SIZE: u32 = 8;

while (processed < BATCH_SIZE) {
    const envelope = input_queue.pop() orelse break;
    self.processMessage(&envelope.message, envelope.client_id);
    processed += 1;
}
```

### 5. Spin-Then-Sleep

Threads use adaptive waiting to balance latency and CPU usage:

```zig
// Spin briefly for low-latency
var spin: u32 = 0;
while (spin < SPIN_COUNT and input_queue.isEmpty()) : (spin += 1) {
    std.atomic.spinLoopHint();
}

// Then sleep to save CPU
if (input_queue.isEmpty()) {
    std.Thread.sleep(100_000); // 100us
}
```

### 6. TCP_NODELAY

All client sockets disable Nagle's algorithm for immediate transmission:

```zig
const nodelay: u32 = 1;
try posix.setsockopt(
    self.stream.handle,
    posix.IPPROTO.TCP,
    posix.TCP.NODELAY,
    &std.mem.toBytes(nodelay),
);
```

---

## Design Decisions

### Why Zig?

1. **Zero-cost abstractions**: Comptime evaluation, no hidden allocations
2. **Explicit memory management**: No GC pauses
3. **C interop**: Easy integration with existing trading infrastructure
4. **Safety with escape hatches**: Bounds checking with ability to disable
5. **Cross-compilation**: Single toolchain for all targets

### Why Thread-Per-Client?

Alternatives considered:

| Approach | Pros | Cons |
|----------|------|------|
| Single-threaded epoll | Simple, no locks | Backpressure deadlock |
| Thread pool | Bounded resources | Complex scheduling |
| **Thread-per-client** | No deadlock, simple | More threads |
| io_uring | Best performance | Complex, Linux-only |

Thread-per-client was chosen for simplicity and correctness. The C implementation proved this approach achieves excellent throughput.

### Why Pre-allocated Memory?

Following Power of Ten Rule 3:

- Predictable latency (no malloc during trading)
- No memory fragmentation
- Bounded memory usage
- Easier reasoning about capacity

### Why Separate Order-to-Symbol Map?

Cancel messages only contain `user_id` and `user_order_id`, not the symbol. The `order_to_symbol` map provides O(1) lookup to find which order book contains the order.

### Why 64-Byte Structures?

Modern x86-64 cache lines are 64 bytes. Aligning structures to cache lines:

- Prevents false sharing between threads
- Ensures atomic access to entire structure
- Maximizes cache utilization

---

## Future Considerations

### Potential Optimizations

1. **io_uring**: Replace epoll with io_uring for batched syscalls
2. **Kernel bypass**: DPDK or XDP for zero-copy networking
3. **NUMA awareness**: Pin threads to specific cores
4. **Huge pages**: Reduce TLB misses for large allocations

### Planned Features

1. **FIX 4.2 protocol**: Industry-standard messaging
2. **Multicast market data**: UDP broadcast for price updates
3. **Persistence**: Order book snapshots and replay
4. **Monitoring**: Prometheus metrics endpoint

---

## References

- [Power of Ten - Rules for Developing Safety Critical Code](https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code)
- [Lock-Free Data Structures](https://www.cs.rochester.edu/~scott/papers/1996_PODC_queues.pdf)
- [What Every Programmer Should Know About Memory](https://people.freebsd.org/~lstewart/articles/cpumemory.pdf)
