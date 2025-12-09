# Architecture Documentation

This document describes the technical architecture of the Zig Matching Engine, covering design decisions, data flows, and implementation details.

## Table of Contents

1. [System Overview](#system-overview)
2. [Threading Model](#threading-model)
3. [Core Components](#core-components)
4. [Protocol Layer](#protocol-layer)
5. [Transport Layer](#transport-layer)
6. [Memory Management](#memory-management)
7. [Data Structures](#data-structures)
8. [Message Flow](#message-flow)
9. [Error Handling](#error-handling)
10. [Performance Optimizations](#performance-optimizations)

---

## System Overview

The matching engine uses a **dual-processor architecture** where network I/O is separated from order matching to minimize latency jitter.

### Design Goals

| Goal | Approach |
|------|----------|
| Low Latency | Lock-free queues, zero-copy, no allocation in hot path |
| High Throughput | Parallel processors, batched I/O |
| Reliability | Bounded resources, graceful degradation |
| Observability | Comprehensive statistics, health checks |

### High-Level Architecture

```
                    ┌─────────────────────────────────────────┐
                    │              Client Layer               │
                    │  (TCP Clients, UDP Clients, Multicast)  │
                    └─────────────────┬───────────────────────┘
                                      │
                    ┌─────────────────▼───────────────────────┐
                    │             I/O Thread                   │
                    │                                          │
                    │  ┌─────────┐ ┌─────────┐ ┌───────────┐  │
                    │  │   TCP   │ │   UDP   │ │ Multicast │  │
                    │  │ Server  │ │ Server  │ │ Publisher │  │
                    │  └────┬────┘ └────┬────┘ └─────┬─────┘  │
                    │       │           │            │         │
                    │  ┌────▼───────────▼────┐       │         │
                    │  │   Protocol Codec    │       │         │
                    │  │ (CSV/Binary/FIX)    │       │         │
                    │  └─────────┬───────────┘       │         │
                    │            │                   │         │
                    │  ┌─────────▼───────────┐       │         │
                    │  │   Symbol Router     │       │         │
                    │  │   (A-M → P0)        │       │         │
                    │  │   (N-Z → P1)        │       │         │
                    │  └─────────┬───────────┘       │         │
                    └────────────┼───────────────────┼─────────┘
                                 │                   │
              ┌──────────────────┼───────────────────┼─────────┐
              │                  │                   │         │
        ┌─────▼─────┐      ┌─────▼─────┐      ┌─────▼─────┐   │
        │Input Queue│      │Input Queue│      │Output Drain│   │
        │  (SPSC)   │      │  (SPSC)   │      │   Loop     │   │
        └─────┬─────┘      └─────┬─────┘      └─────┬─────┘   │
              │                  │                   │         │
   ┌──────────▼──────────┐ ┌────▼────────────┐     │         │
   │    Processor 0      │ │   Processor 1   │     │         │
   │    (Symbols A-M)    │ │   (Symbols N-Z) │     │         │
   │                     │ │                 │     │         │
   │ ┌─────────────────┐ │ │ ┌─────────────┐ │     │         │
   │ │ Matching Engine │ │ │ │  Matching   │ │     │         │
   │ │                 │ │ │ │   Engine    │ │     │         │
   │ │ ┌─────────────┐ │ │ │ │             │ │     │         │
   │ │ │ Order Books │ │ │ │ │             │ │     │         │
   │ │ │  (HashMap)  │ │ │ │ │             │ │     │         │
   │ │ └─────────────┘ │ │ │ │             │ │     │         │
   │ └─────────────────┘ │ │ └─────────────┘ │     │         │
   │          │          │ │        │        │     │         │
   │    ┌─────▼─────┐    │ │  ┌─────▼─────┐  │     │         │
   │    │Output     │    │ │  │Output     │  │     │         │
   │    │Queue(SPSC)│    │ │  │Queue(SPSC)│  │─────┘         │
   │    └───────────┘    │ │  └───────────┘  │               │
   └─────────────────────┘ └─────────────────┘               │
                                                              │
                              ┌────────────────────────────────┘
                              │
                    ┌─────────▼───────────────────────────────┐
                    │           Response Encoding             │
                    │         & Client Dispatch               │
                    └─────────────────────────────────────────┘
```

---

## Threading Model

### Thread Roles

| Thread | Responsibility | CPU Affinity |
|--------|----------------|--------------|
| I/O Thread | Network I/O, routing, encoding | Core 0 |
| Processor 0 | Match A-M symbols | Core 1 |
| Processor 1 | Match N-Z symbols | Core 2 |

### Communication

All inter-thread communication uses **lock-free SPSC queues**:

```
I/O Thread                    Processor Thread
     │                              │
     │  ProcessorInput              │
     │  ┌──────────────┐            │
     │  │ message      │            │
     │  │ client_id    │───push────►│
     │  │ timestamp    │            │
     │  └──────────────┘            │
     │                              │
     │  ProcessorOutput             │
     │  ┌──────────────┐            │
     │◄─│ message      │────pop─────│
     │  │ latency_ns   │            │
     │  └──────────────┘            │
```

### Symbol Routing

```zig
pub fn routeSymbol(symbol: Symbol) ProcessorId {
    const first = symbol[0];
    if (first == 0) return .processor_0;
    
    const upper = first & 0xDF;  // ASCII uppercase
    if (upper >= 'A' and upper <= 'M') {
        return .processor_0;
    }
    return .processor_1;
}
```

This provides:
- **Deterministic routing**: Same symbol always goes to same processor
- **Even distribution**: Roughly 50/50 split for typical symbol sets
- **No locking**: Routing is a pure function

---

## Core Components

### MatchingEngine

The central coordinator that owns order books and dispatches messages.

```zig
pub const MatchingEngine = struct {
    books: HashMap(Symbol, *OrderBook),
    pools: *MemoryPools,
    next_order_id: u64,
    
    pub fn processMessage(
        self: *Self,
        msg: *const InputMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void;
};
```

**Responsibilities**:
- Route messages to appropriate order book
- Generate unique order IDs
- Collect output messages

### OrderBook

Price-time priority order book with O(1) operations.

```zig
pub const OrderBook = struct {
    bids: PriceLevelMap,      // Price → Level (descending)
    asks: PriceLevelMap,      // Price → Level (ascending)
    orders: OrderMap,         // OrderId → Order
    symbol: Symbol,
    
    pub fn addOrder(self: *Self, order: *Order, output: *OutputBuffer) void;
    pub fn cancelOrder(self: *Self, order_id: u64, output: *OutputBuffer) void;
};
```

**Order Matching Algorithm**:

```
For a BUY order at price P with quantity Q:
1. Find best ASK price
2. While best_ask <= P and Q > 0:
   a. Match against orders at best_ask (FIFO)
   b. Generate trade messages
   c. Update quantities
   d. Remove filled orders
3. If Q > 0, add remaining to BID book
```

### Order

Order representation with 64-byte cache alignment.

```zig
pub const Order = struct {
    order_id: u64,
    user_id: u32,
    user_order_id: u32,
    price: u64,
    quantity: u32,
    remaining: u32,
    side: Side,
    symbol: Symbol,
    client_id: u32,
    timestamp: i64,
    
    // Intrusive list pointers for price level
    prev: ?*Order,
    next: ?*Order,
};
```

---

## Protocol Layer

### Message Types

**Input Messages**:

| Type | Description |
|------|-------------|
| `new_order` | Submit new order |
| `cancel` | Cancel existing order |
| `flush` | Cancel all orders (disconnect) |

**Output Messages**:

| Type | Description |
|------|-------------|
| `ack` | Order accepted |
| `reject` | Order rejected |
| `trade` | Execution report |
| `cancel_ack` | Cancel confirmed |
| `top_of_book` | BBO update |

### Codec Selection

```
┌──────────────────────────────────────────────────────────┐
│                    Incoming Bytes                        │
└──────────────────────────┬───────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │   First Byte Analysis  │
              └────────────┬───────────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
    0x01-0x03         'N','C'           '8','9'
    (Binary)          (CSV)             (FIX)
         │                 │                 │
         ▼                 ▼                 ▼
  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
  │binary_codec  │ │ csv_codec    │ │ fix_codec    │
  │.decode()     │ │.decode()     │ │.decode()     │
  └──────────────┘ └──────────────┘ └──────────────┘
```

### Binary Format

64-byte fixed-size messages for minimal parsing:

```
Offset  Size  Field
──────  ────  ─────────────────
0       1     msg_type
1       1     side
2       8     symbol (null-padded)
10      4     user_id
14      4     user_order_id
18      8     price (scaled integer, e.g., cents)
26      4     quantity
30      34    _padding (zero-filled)
──────  ────  ─────────────────
Total   64    bytes
```

### CSV Format

Human-readable with newline termination:

```
N,AAPL,1001,1,B,15000,100\n     # New order
C,AAPL,1001,1\n                  # Cancel
A,AAPL,1,0\n                     # Ack (status=0)
T,AAPL,15000,50,1,2\n            # Trade
R,AAPL,1,3\n                     # Reject (reason=3)
```

---

## Transport Layer

### TCP Server

Length-prefixed framing for message boundaries:

```
┌────────────┬─────────────────────────────────┐
│  4 bytes   │         N bytes                 │
│  (length)  │        (payload)                │
│  little    │                                 │
│  endian    │                                 │
└────────────┴─────────────────────────────────┘
```

**Features**:
- epoll (Linux) / kqueue (macOS) for scalable I/O
- Edge-triggered events with drain loops
- Per-client send buffers (64KB)
- Idle timeout enforcement

### UDP Server

Stateless protocol with client tracking:

```zig
pub const UdpServer = struct {
    fd: ?posix.fd_t,
    clients: ClientTable,           // Hash table of known clients
    on_message: MessageCallback,
    
    pub fn poll(self: *Self) !usize;
    pub fn send(self: *Self, client_id: ClientId, data: []const u8) bool;
};
```

**Client Tracking**:
- FNV-1a inspired hash of (IP, port)
- LRU eviction when table full
- Protocol auto-detection per client

### Multicast Publisher

Market data distribution:

```zig
pub const MulticastPublisher = struct {
    fd: ?posix.fd_t,
    sequence: u64,
    
    pub fn publish(self: *Self, msg: *const OutputMsg) bool;
};
```

**Sequence Number Header**:
```
┌──────────────┬─────────────────────────────────┐
│   8 bytes    │         Payload                 │
│  (sequence)  │    (encoded message)            │
│  big-endian  │                                 │
└──────────────┴─────────────────────────────────┘
```

---

## Memory Management

### Strategy

No dynamic allocation in the hot path. All memory is pre-allocated at startup.

```
┌─────────────────────────────────────────────────────────────┐
│                     Memory Layout                            │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │   Order Pool    │  │  OrderBook Pool │                   │
│  │   (1M orders)   │  │   (10K books)   │                   │
│  │   64 bytes each │  │  ~2KB each      │                   │
│  └─────────────────┘  └─────────────────┘                   │
│                                                              │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │  Input Queues   │  │  Output Queues  │                   │
│  │  2 × 64K slots  │  │  2 × 64K slots  │                   │
│  │  ~80 bytes/slot │  │  ~80 bytes/slot │                   │
│  └─────────────────┘  └─────────────────┘                   │
│                                                              │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │  Recv Buffers   │  │  Send Buffers   │                   │
│  │  Per-client     │  │  Per-client     │                   │
│  │  64KB each      │  │  64KB each      │                   │
│  └─────────────────┘  └─────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

### MemoryPools

```zig
pub const MemoryPools = struct {
    order_pool: ObjectPool(Order),
    book_pool: ObjectPool(OrderBook),
    allocator: std.mem.Allocator,
    
    pub fn allocOrder(self: *Self) ?*Order;
    pub fn freeOrder(self: *Self, order: *Order) void;
};
```

### ObjectPool

Fixed-capacity freelist allocator:

```zig
pub fn ObjectPool(comptime T: type) type {
    return struct {
        items: []T,
        free_list: []usize,
        free_count: usize,
        
        pub fn alloc(self: *Self) ?*T;
        pub fn free(self: *Self, item: *T) void;
    };
}
```

---

## Data Structures

### SPSC Queue

Lock-free single-producer/single-consumer queue:

```zig
pub fn SpscQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T,
        head: std.atomic.Value(usize),  // Consumer reads, producer writes
        tail: std.atomic.Value(usize),  // Producer reads, consumer writes
        
        pub fn push(self: *Self, item: T) bool;
        pub fn pop(self: *Self) ?T;
        pub fn size(self: *Self) usize;
    };
}
```

**Memory Ordering**:
- `push`: Release semantics on tail update
- `pop`: Acquire semantics on tail read
- Ensures data visibility across threads

### PriceLevel (Intrusive List)

```zig
pub const PriceLevel = struct {
    price: u64,
    total_quantity: u32,
    order_count: u16,
    head: ?*Order,
    tail: ?*Order,
    
    pub fn addOrder(self: *Self, order: *Order) void;
    pub fn removeOrder(self: *Self, order: *Order) void;
};
```

---

## Message Flow

### New Order Flow

```
1. Client sends:     N,AAPL,1001,1,B,15000,100
                           │
2. TCP/UDP receives        │
                           ▼
3. Codec decodes:    InputMsg{.new_order, symbol="AAPL", ...}
                           │
4. Router hashes:    hash("AAPL") → Processor 0
                           │
5. Enqueue:          input_queue[0].push(ProcessorInput{...})
                           │
                    ───────┼──────── Thread Boundary ────────
                           │
6. Processor pops:   input_queue[0].pop() → ProcessorInput
                           │
7. Engine processes: matching_engine.processMessage(...)
                           │
8. Book matches:     order_book.addOrder(order, output)
                           │
9. Outputs:          [Ack, Trade?, TopOfBook?]
                           │
10. Enqueue:         output_queue[0].push(ProcessorOutput{...})
                           │
                    ───────┼──────── Thread Boundary ────────
                           │
11. I/O drains:      output_queue[0].pop() → ProcessorOutput
                           │
12. Encode:          csv_codec.encodeOutput(...)
                           │
13. Send:            tcp_server.send(client_id, data)
```

### Backpressure Handling

```
Output Queue Full:
1. Spin wait (100 iterations)
2. Yield wait (50 iterations)
3. If still full:
   - Critical messages (trade, reject): Log error, panic in debug
   - Non-critical (ack, top_of_book): Log warning, drop
```

---

## Error Handling

### Error Categories

| Category | Examples | Handling |
|----------|----------|----------|
| Network | Connection reset, timeout | Log, cleanup, continue |
| Protocol | Invalid message, parse error | Reject, log |
| Capacity | Queue full, pool exhausted | Backpressure, drop |
| System | OOM, syscall failure | Propagate up, shutdown |

### Health Monitoring

```zig
pub fn isHealthy(self: *const Self) bool {
    const stats = self.getStats();
    return stats.totalCriticalDrops() == 0;
}
```

Critical drops (trades, rejects) indicate system overload and should trigger alerts.

---

## Performance Optimizations

### Hot Path Optimizations

1. **Zero-Copy Message Passing**: Messages copied only at network boundary
2. **Cache-Aligned Structures**: 64-byte alignment for Order, reduces false sharing
3. **Branch Prediction**: Hot paths arranged for fall-through
4. **Lock-Free Queues**: No mutex contention between threads

### Batching

**UDP Output Batching**:
```
┌────────────────────────────────────────────────────────┐
│  Multiple CSV messages batched into single UDP packet  │
│                                                        │
│  A,AAPL,1,0\n                                          │
│  T,AAPL,15000,50,1,2\n                                 │
│  B,AAPL,15000,14900,100,200\n                          │
│                                                        │
│  = 1 syscall instead of 3                              │
└────────────────────────────────────────────────────────┘
```

### Latency vs Throughput Trade-offs

| Setting | Latency | Throughput | Use Case |
|---------|---------|------------|----------|
| `TRACK_LATENCY=true` | +100-200ns | - | Development, monitoring |
| `TRACK_LATENCY=false` | Baseline | Maximum | Production |
| Small poll timeout | Lower | Lower | Latency-sensitive |
| Large poll timeout | Higher | Higher | Throughput-focused |

---

## Appendix: Constants

```zig
// Queue Configuration
CHANNEL_CAPACITY = 65536        // 64K entries per queue
MAX_POLL_ITERATIONS = 1000      // Messages per poll cycle
OUTPUT_DRAIN_LIMIT = 131072     // 128K outputs per drain

// Network Configuration
MAX_UDP_PAYLOAD = 1400          // Safe UDP payload size
MAX_TCP_CLIENTS = 1024          // Concurrent TCP connections
MAX_UDP_CLIENTS = 4096          // Tracked UDP clients
RECV_BUFFER_SIZE = 65536        // Per-client receive buffer
SEND_BUFFER_SIZE = 65536        // Per-client send buffer

// Memory Pools
MAX_ORDERS = 1048576            // 1M orders
MAX_ORDER_BOOKS = 10000         // 10K symbols

// Backpressure
OUTPUT_SPIN_COUNT = 100         // Spins before yield
OUTPUT_YIELD_COUNT = 50         // Yields before drop
```

---

## References

- [NASA Power of Ten Rules](https://spinroot.com/gerard/pdf/P10.pdf)
- [The Art of Writing Efficient Programs](https://www.packtpub.com/product/the-art-of-writing-efficient-programs)
- [Trading and Exchanges: Market Microstructure](https://global.oup.com/academic/product/trading-and-exchanges-9780195144703)
