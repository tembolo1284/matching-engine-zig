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
| Low Latency | Lock-free queues, heap-allocated buffers, no allocation in hot path |
| High Throughput | Parallel processors, batched I/O, epoll/kqueue |
| Reliability | Bounded resources, graceful degradation, P10 compliance |
| Cross-Platform | epoll (Linux), kqueue (macOS), abstracted socket options |

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
                    │  │ :1234   │ │ :1235   │ │ :1236     │  │
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
   │ │ ┌─────────────┐ │ │ │ │   Engine    │ │     │         │
   │ │ │ Order Books │ │ │ │ └─────────────┘ │     │         │
   │ │ │ Memory Pools│ │ │ │                 │     │         │
   │ │ │ Order Map   │ │ │ │                 │     │         │
   │ │ └─────────────┘ │ │ │                 │     │         │
   │ └─────────────────┘ │ │                 │     │         │
   │          │          │ │        │        │     │         │
   │    ┌─────▼─────┐    │ │  ┌─────▼─────┐  │     │         │
   │    │Output     │    │ │  │Output     │  │─────┘         │
   │    │Queue(SPSC)│    │ │  │Queue(SPSC)│  │               │
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

| Thread | Responsibility | Key Structures |
|--------|----------------|----------------|
| I/O Thread | Network I/O, routing, encoding | TcpServer, UdpServer, MulticastPublisher |
| Processor 0 | Match A-M symbols | MatchingEngine, MemoryPools, OrderMap |
| Processor 1 | Match N-Z symbols | MatchingEngine, MemoryPools, OrderMap |

### Communication

All inter-thread communication uses **lock-free SPSC queues**:

```
I/O Thread                    Processor Thread
     │                              │
     │  ProcessorInput              │
     │  ┌──────────────┐            │
     │  │ message      │            │
     │  │ client_id    │───push────►│
     │  │ enqueue_time │            │
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
pub fn routeSymbol(symbol: *const Symbol) ProcessorId {
    const first = symbol[0];
    if (first == 0) return .processor_0;

    const upper = first & 0xDF;  // ASCII to uppercase
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
    pools: *MemoryPools,
    order_symbol_map: [ORDER_SYMBOL_MAP_SIZE]OrderSymbolSlot,  // ~48MB
    next_internal_id: u64,
    
    // Statistics
    orders_processed: u64,
    trades_executed: u64,
    orders_rejected: u64,

    pub fn processMessage(
        self: *Self,
        msg: *const InputMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void;
    
    pub fn cancelClientOrders(
        self: *Self,
        client_id: u32,
        output: *OutputBuffer,
    ) u32;
};
```

**Responsibilities**:
- Route messages to appropriate order book
- Generate unique internal order IDs
- Track order ownership for client disconnect cleanup
- Collect output messages

### OrderBook

Price-time priority order book with O(1) operations.

```zig
pub const OrderBook = struct {
    // Price levels indexed by price (0 to MAX_PRICE_LEVELS-1)
    bid_levels: [MAX_PRICE_LEVELS]PriceLevel,
    ask_levels: [MAX_PRICE_LEVELS]PriceLevel,
    
    // Best price tracking
    best_bid: u32,
    best_ask: u32,
    
    symbol: Symbol,

    pub fn addOrder(self: *Self, order: *Order, output: *OutputBuffer) void;
    pub fn cancelOrder(self: *Self, order: *Order, output: *OutputBuffer) void;
    pub fn match(self: *Self, order: *Order, output: *OutputBuffer) void;
};
```

**Order Matching Algorithm**:

```
For a BUY order at price P with quantity Q:
1. Find best ASK price
2. While best_ask <= P and Q > 0:
   a. Match against orders at best_ask (FIFO within price level)
   b. Generate trade messages
   c. Update quantities
   d. Remove filled orders
   e. Update best ask if level depleted
3. If Q > 0, add remaining to BID book at price P
4. Emit top-of-book update if BBO changed
```

### Order

Order representation with cache-line alignment considerations.

```zig
pub const Order = struct {
    // Identity
    internal_id: u64,           // Engine-assigned unique ID
    user_id: u32,
    user_order_id: u32,
    client_id: u32,
    
    // Order details
    price: u32,
    quantity: u32,
    remaining_qty: u32,
    side: Side,
    symbol: Symbol,
    
    // Intrusive list pointers (for price level FIFO queue)
    prev: ?*Order,
    next: ?*Order,
    
    // Metadata
    timestamp_ns: i128,
};
```

### OrderMap

O(1) order lookup by composite key (user_id, user_order_id).

```zig
pub const OrderMap = struct {
    slots: [ORDER_MAP_SIZE]OrderMapSlot,  // ~16MB
    
    pub fn insert(self: *Self, user_id: u32, order_id: u32, order: *Order) bool;
    pub fn find(self: *Self, user_id: u32, order_id: u32) ?*Order;
    pub fn remove(self: *Self, user_id: u32, order_id: u32) ?*Order;
};
```

Uses open addressing with linear probing. Key is FNV-1a hash of (user_id, user_order_id).

---

## Protocol Layer

### Message Types

**Input Messages** (defined in `message_types.zig`):

| Type | Wire Code | Description |
|------|-----------|-------------|
| `new_order` | 'N' | Submit new order |
| `cancel` | 'C' | Cancel existing order |
| `flush` | 'F' | Cancel all orders (testing) |

**Output Messages**:

| Type | Wire Code | Description |
|------|-----------|-------------|
| `ack` | 'A' | Order accepted |
| `reject` | 'R' | Order rejected |
| `trade` | 'T' | Execution report |
| `cancel_ack` | 'X' / 'C' | Cancel confirmed |
| `top_of_book` | 'B' | BBO update |

### Protocol Detection

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
      0x4D ('M')      'N','C','F'       '8' + "=FIX"
      (Binary)          (CSV)             (FIX)
         │                 │                 │
         ▼                 ▼                 ▼
  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
  │binary_codec  │ │ csv_codec    │ │ fix_codec    │
  │.decode()     │ │.decode()     │ │.decode()     │
  └──────────────┘ └──────────────┘ └──────────────┘
```

### Binary Wire Format

All integers are **big-endian** (network byte order). Magic byte 0x4D ('M') identifies binary protocol.

**New Order (27 bytes)**:
```
Offset  Size  Field         Description
──────  ────  ───────────   ─────────────────
0       1     magic         0x4D ('M')
1       1     msg_type      0x4E ('N')
2       4     user_id       User identifier
6       8     symbol        Null-padded ASCII
14      4     price         Price (integer)
18      4     quantity      Order quantity
22      1     side          'B' (0x42) or 'S' (0x53)
23      4     user_order_id User's order ID
──────  ────  ───────────
Total   27    bytes
```

**Cancel (18 bytes)**:
```
Offset  Size  Field
──────  ────  ───────────
0       1     magic (0x4D)
1       1     msg_type (0x43 = 'C')
2       4     user_id
6       8     symbol
14      4     user_order_id
```

**Trade (34 bytes)**:
```
Offset  Size  Field
──────  ────  ───────────
0       1     magic (0x4D)
1       1     msg_type (0x54 = 'T')
2       8     symbol
10      4     buy_user_id
14      4     buy_order_id
18      4     sell_user_id
22      4     sell_order_id
26      4     price
30      4     quantity
```

**Ack (18 bytes)**:
```
Offset  Size  Field
──────  ────  ───────────
0       1     magic (0x4D)
1       1     msg_type (0x41 = 'A')
2       8     symbol
10      4     user_id
14      4     user_order_id
```

**Reject (19 bytes)**:
```
Offset  Size  Field
──────  ────  ───────────
0       1     magic (0x4D)
1       1     msg_type (0x52 = 'R')
2       8     symbol
10      4     user_id
14      4     user_order_id
18      1     reason
```

### CSV Format

Human-readable, newline-terminated:

```
# Input
N, <user_id>, <symbol>, <price>, <qty>, <side>, <order_id>
C, <user_id>, <order_id>, [symbol]
F

# Output
A, <symbol>, <user_id>, <order_id>
T, <symbol>, <buy_uid>, <buy_oid>, <sell_uid>, <sell_oid>, <price>, <qty>
B, <symbol>, <side>, <price>, <qty>
C, <symbol>, <user_id>, <order_id>
R, <symbol>, <user_id>, <order_id>, <reason>
```

---

## Transport Layer

### TCP Server

**Framing**: 4-byte big-endian length prefix:

```
┌────────────────┬─────────────────────────────────┐
│  4 bytes (BE)  │         N bytes                 │
│  message len   │         payload                 │
└────────────────┴─────────────────────────────────┘
```

**Features**:
- epoll (Linux) / kqueue (macOS) via `Poller` abstraction
- Edge-triggered events with drain loops
- Per-client heap-allocated buffers (256KB recv, 256KB send)
- Idle timeout enforcement (default 300s)
- Consecutive error tracking with auto-disconnect

**Key Constants** (from `tcp_client.zig`):
```zig
RECV_BUFFER_SIZE = 262144      // 256KB per client
SEND_BUFFER_SIZE = 262144      // 256KB per client
FRAME_HEADER_SIZE = 4          // Length prefix
MAX_MESSAGE_SIZE = 65536       // Max payload
MAX_CONSECUTIVE_ERRORS = 10    // Before disconnect
MAX_CLIENTS = 64               // Concurrent connections
```

### UDP Server

Stateless protocol with O(1) client tracking via hash table:

```zig
pub const UdpServer = struct {
    fd: ?posix.fd_t,
    clients: UdpClientMap,        // Hash table: (IP,port) → client_id
    on_message: MessageCallback,

    pub fn poll(self: *Self) !usize;
    pub fn send(self: *Self, client_id: ClientId, data: []const u8) bool;
};
```

**Client Tracking**:
- FNV-1a inspired hash of (IP, port)
- Open addressing with linear probing
- LRU eviction when table full (4096 clients max)
- Protocol auto-detection stored per client

**Key Constants** (from `udp_server.zig`):
```zig
MAX_UDP_CLIENTS = 4096
HASH_TABLE_SIZE = 8192         // 2x for load factor
SOCKET_RECV_BUF_SIZE = 8MB     // Kernel buffer request
MAX_PACKETS_PER_POLL = 1000    // Prevent starvation
```

### Multicast Publisher

Market data distribution with sequence numbers:

```zig
pub const MulticastPublisher = struct {
    fd: ?posix.fd_t,
    sequence: u64,
    dest_addr: sockaddr.in,

    pub fn publish(self: *Self, msg: *const OutputMsg) bool;
};
```

**Wire Format**:
```
┌──────────────────┬─────────────────────────────────┐
│   8 bytes (BE)   │         Payload                 │
│   sequence num   │    (encoded message)            │
└──────────────────┴─────────────────────────────────┘
```

Subscribers use sequence numbers for gap detection.

---

## Memory Management

### Strategy

**No dynamic allocation in the hot path.** All memory is pre-allocated at startup:

```
┌─────────────────────────────────────────────────────────────┐
│                     Memory Layout                            │
├─────────────────────────────────────────────────────────────┤
│  Per-Processor:                                              │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │   Order Pool    │  │  OrderBook Pool │                   │
│  │   (64K orders)  │  │   (1K books)    │                   │
│  └─────────────────┘  └─────────────────┘                   │
│                                                              │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │   Order Map     │  │ Order-Symbol Map│                   │
│  │   (~16 MB)      │  │   (~48 MB)      │                   │
│  └─────────────────┘  └─────────────────┘                   │
│                                                              │
│  Shared (I/O Thread):                                        │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │  Input Queues   │  │  Output Queues  │                   │
│  │  2 × 64K slots  │  │  2 × 64K slots  │                   │
│  └─────────────────┘  └─────────────────┘                   │
│                                                              │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │  TCP Client     │  │  UDP Hash Table │                   │
│  │  Buffers (heap) │  │  (~64 KB)       │                   │
│  │  256KB × clients│  │                 │                   │
│  └─────────────────┘  └─────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

### MemoryPools

```zig
pub const MemoryPools = struct {
    allocator: std.mem.Allocator,
    order_pool: OrderPool,
    book_pool: BookPool,
    
    pub fn init(allocator: Allocator) !*MemoryPools;
    pub fn allocOrder(self: *Self) ?*Order;
    pub fn freeOrder(self: *Self, order: *Order) void;
};
```

### ObjectPool

Fixed-capacity freelist allocator:

```zig
pub fn ObjectPool(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: []T,
        free_indices: []u32,
        free_count: u32,

        pub fn alloc(self: *Self) ?*T;
        pub fn free(self: *Self, item: *T) void;
    };
}
```

---

## Data Structures

### SPSC Queue

Lock-free single-producer/single-consumer queue with cache-line aligned atomics:

```zig
pub fn SpscQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T align(CACHE_LINE_SIZE),
        head: CacheLineAtomic,  // Consumer reads here
        tail: CacheLineAtomic,  // Producer writes here

        pub fn push(self: *Self, item: T) bool;
        pub fn pop(self: *Self) ?T;
        pub fn pushBatch(self: *Self, items: []const T) usize;
        pub fn popBatch(self: *Self, out: []T) usize;
    };
}
```

**Memory Ordering**:
- `push`: Release semantics on tail update (ensures data visible)
- `pop`: Acquire semantics on tail read (sees producer's writes)
- No memory barriers needed within single thread

**Key Constants** (from `processor.zig`):
```zig
CHANNEL_CAPACITY = 65536       // Must be power of 2
```

### PriceLevel (Intrusive Doubly-Linked List)

```zig
pub const PriceLevel = struct {
    head: ?*Order,
    tail: ?*Order,
    total_quantity: u32,
    order_count: u16,

    pub fn pushBack(self: *Self, order: *Order) void;
    pub fn remove(self: *Self, order: *Order) void;
    pub fn popFront(self: *Self) ?*Order;
};
```

Orders maintain `prev`/`next` pointers for O(1) insertion and removal.

---

## Message Flow

### New Order Flow

```
1. Client sends:     N, 1, AAPL, 15000, 100, B, 1
                           │
2. TCP/UDP receives        │
                           ▼
3. Codec decodes:    InputMsg{.new_order, user_id=1, symbol="AAPL", ...}
                           │
4. Router hashes:    "AAPL"[0] = 'A' → Processor 0
                           │
5. Enqueue:          input_queue[0].push(ProcessorInput{...})
                           │
                    ───────┼──────── Thread Boundary ────────
                           │
6. Processor pops:   input_queue[0].pop() → ProcessorInput
                           │
7. Engine validates: Check qty>0, price>0, no duplicate
                           │
8. Engine processes: matching_engine.processMessage(...)
                           │
9. Book matches:     order_book.addOrder(order, output)
                           │
10. Outputs:         [Ack, Trade?, TopOfBook?]
                           │
11. Enqueue:         output_queue[0].push(ProcessorOutput{...})
                           │
                    ───────┼──────── Thread Boundary ────────
                           │
12. I/O drains:      output_queue[0].pop() → ProcessorOutput
                           │
13. Encode:          csv_codec.encodeOutput(...)
                           │
14. Send:            tcp_server.send(client_id, data)
                     multicast.publish(&trade) // if trade
```

### Backpressure Handling

```
Output Queue Full:
1. Spin wait (OUTPUT_SPIN_COUNT iterations)
2. Log warning
3. For critical messages (trade, reject):
   - In debug: panic
   - In release: increment critical_drop counter
4. For non-critical (ack, top_of_book):
   - Increment drop counter, continue
```

---

## Error Handling

### Error Categories

| Category | Examples | Handling |
|----------|----------|----------|
| Network | Connection reset, timeout | Log, cleanup client, continue |
| Protocol | Invalid message, bad checksum | Reject, increment error counter |
| Validation | Invalid price, duplicate ID | Reject with reason code |
| Capacity | Queue full, pool exhausted | Backpressure, reject |
| System | OOM, syscall failure | Propagate up, shutdown |

### Reject Reason Codes

| Code | Enum | Description |
|------|------|-------------|
| 1 | `unknown_symbol` | Symbol not recognized |
| 2 | `invalid_quantity` | Quantity is zero |
| 3 | `invalid_price` | Price is zero (for limit) |
| 4 | `order_not_found` | Cancel: order doesn't exist |
| 5 | `duplicate_order_id` | (user_id, order_id) already exists |
| 6 | `pool_exhausted` | No free order slots |
| 7 | `unauthorized` | User not permitted |
| 8 | `throttled` | Rate limit exceeded |
| 9 | `book_full` | Too many price levels |
| 10 | `invalid_order_id` | Reserved key (0,0) used |

### Health Monitoring

```zig
pub fn isHealthy(self: *const ThreadedServer) bool {
    const stats = self.getStats();
    // Critical drops indicate system overload
    return stats.totalCriticalDrops() == 0;
}
```

---

## Performance Optimizations

### Hot Path Optimizations

1. **Zero-Copy Message Passing**: Messages decoded once, pointer passed through queues
2. **Heap-Allocated Client Buffers**: Avoids stack overflow, allows large buffers
3. **Lock-Free Queues**: No mutex contention between I/O and processor threads
4. **O(1) Order Lookup**: Hash-based OrderMap for cancel operations
5. **Intrusive Lists**: No allocation for queue operations within price levels

### Cache Optimizations

```zig
const CACHE_LINE_SIZE = 64;

// SPSC queue head/tail on separate cache lines
const CacheLineAtomic = struct {
    value: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
    _padding: [CACHE_LINE_SIZE - @sizeOf(std.atomic.Value(usize))]u8,
};
```

### Batching

**Output Drain Batching**:
```zig
OUTPUT_BATCH_SIZE = 1400       // Bytes per UDP packet
MAX_OUTPUT_BATCHES = 64        // Per drain cycle
OUTPUT_DRAIN_LIMIT = 131072    // Messages per drain
```

### Platform-Specific

- **Linux**: epoll with edge-triggered mode, TCP_QUICKACK
- **macOS**: kqueue with EV_CLEAR (edge-like behavior)
- **Both**: TCP_NODELAY, large socket buffers, SIGPIPE ignored

---

## Appendix: Configuration Constants

```zig
// Threading (processor.zig)
CHANNEL_CAPACITY = 65536        // SPSC queue size (power of 2)
OUTPUT_DRAIN_LIMIT = 131072     // Max outputs per drain cycle
OUTPUT_BATCH_SIZE = 1400        // UDP batch payload size
MAX_OUTPUT_BATCHES = 64         // Batches per drain

// Network (config.zig, tcp_client.zig, udp_server.zig)
DEFAULT_TCP_PORT = 1234
DEFAULT_UDP_PORT = 1235
DEFAULT_MCAST_PORT = 1236
DEFAULT_MCAST_GROUP = "239.255.0.1"
MAX_TCP_CLIENTS = 64
MAX_UDP_CLIENTS = 4096
RECV_BUFFER_SIZE = 262144       // 256KB per TCP client
SEND_BUFFER_SIZE = 262144       // 256KB per TCP client
MAX_MESSAGE_SIZE = 65536        // Max framed message
SOCKET_RECV_BUF_SIZE = 8MB      // UDP kernel buffer

// Memory (memory_pool.zig, matching_engine.zig)
ORDER_POOL_CAPACITY = 65536     // Orders per processor
BOOK_POOL_CAPACITY = 1024       // Order books per processor
ORDER_MAP_SIZE = 2097152        // ~2M slots for O(1) lookup
ORDER_SYMBOL_MAP_SIZE = 2097152 // ~2M for client disconnect cleanup

// Matching (order_book.zig)
MAX_PRICE_LEVELS = 1000000      // Price range 0-999999

// Backpressure (processor.zig)
OUTPUT_SPIN_COUNT = 100         // Spins before yield
PANIC_ON_CRITICAL_DROP = true   // In debug mode
```

---

## References

- [NASA Power of Ten Rules](https://spinroot.com/gerard/pdf/P10.pdf)
- [Lock-Free Programming](https://www.cs.cmu.edu/~410-s05/lectures/L31_LockFree.pdf)
- [Trading and Exchanges: Market Microstructure](https://global.oup.com/academic/product/trading-and-exchanges-9780195144703)
