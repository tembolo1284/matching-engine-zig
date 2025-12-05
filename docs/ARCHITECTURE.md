# Architecture Documentation

Detailed technical documentation of the Zig Matching Engine's architecture, focusing on cache optimization, memory layout, and low-latency design decisions.

## Table of Contents

1. [Design Philosophy](#design-philosophy)
2. [Memory Layout & Cache Optimization](#memory-layout--cache-optimization)
3. [Data Structures](#data-structures)
4. [Protocol Layer](#protocol-layer)
5. [Transport Layer](#transport-layer)
6. [Matching Algorithm](#matching-algorithm)
7. [Threading Model](#threading-model)
8. [Performance Analysis](#performance-analysis)

---

## Design Philosophy

### Core Principles

1. **Cache is King** — Every data structure designed around 64-byte cache lines
2. **Zero Allocation** — No heap allocation in the hot path
3. **Predictable Latency** — Bounded loops, no unbounded operations (NASA Rule 2)
4. **Compile-Time Verification** — `comptime` assertions validate all assumptions
5. **Wire Compatibility** — Identical protocol to C implementation

### Why Zig?

| Feature | Benefit |
|---------|---------|
| No hidden allocations | Every allocation explicit via allocator |
| `comptime` | Compile-time verification of sizes/offsets |
| No GC | Deterministic latency |
| C ABI compatible | Easy integration with existing systems |
| Cross-compilation | Single binary for any target |

### Memory Hierarchy Awareness
```
┌─────────────────────────────────────────────────────────────┐
│                    Memory Hierarchy                          │
├─────────────────────────────────────────────────────────────┤
│  L1 Cache    │  32 KB   │  ~1 ns    │  ~4 cycles           │
│  L2 Cache    │  256 KB  │  ~3 ns    │  ~12 cycles          │
│  L3 Cache    │  8+ MB   │  ~10 ns   │  ~40 cycles          │
│  Main Memory │  GBs     │  ~100 ns  │  ~400 cycles         │
└─────────────────────────────────────────────────────────────┘

A single cache miss costs 100x a cache hit!
```

---

## Memory Layout & Cache Optimization

### Order Structure (64 bytes = 1 cache line)
```zig
pub const Order = extern struct {
    // === HOT PATH FIELDS === (bytes 0-19)
    user_id: u32,           // 0-3   — Accessed every match
    user_order_id: u32,     // 4-7   — Accessed every match
    price: u32,             // 8-11  — Compared during matching
    quantity: u32,          // 12-15 — Original quantity
    remaining_qty: u32,     // 16-19 — Updated on fills

    // === METADATA === (bytes 20-31)
    side: Side,             // 20    — Buy/Sell
    order_type: OrderType,  // 21    — Market/Limit
    _pad1: [2]u8,           // 22-23 — Explicit padding
    client_id: u32,         // 24-27 — For response routing
    _pad2: u32,             // 28-31 — Align timestamp

    // === TIMESTAMP === (bytes 32-39)
    timestamp: u64,         // 32-39 — RDTSC for time priority

    // === LINKED LIST === (bytes 40-55)
    next: ?*Order,          // 40-47 — Next in price level
    prev: ?*Order,          // 48-55 — Previous in price level

    // === PADDING === (bytes 56-63)
    _padding: [8]u8,        // Ensure exactly 64 bytes

    comptime {
        std.debug.assert(@sizeOf(@This()) == 64);
    }
};
```

**Design Decisions:**
- Hot fields (price, qty) in first 20 bytes for cache efficiency
- Linked list pointers at end (only used during traversal)
- Explicit padding prevents compiler surprises
- `comptime` assertion catches size changes at compile time

### Price Level Structure (64 bytes)
```zig
pub const PriceLevel = extern struct {
    price: u32,             // 0-3
    total_quantity: u32,    // 4-7
    orders_head: ?*Order,   // 8-15
    orders_tail: ?*Order,   // 16-23
    active: bool,           // 24
    _padding: [39]u8,       // 25-63

    comptime {
        std.debug.assert(@sizeOf(@This()) == 64);
    }
};
```

### SPSC Queue with Cache Line Isolation
```zig
pub fn SpscQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        // Producer and consumer on separate cache lines
        // to prevent false sharing
        head: CacheLineAtomic,      // Producer writes
        _pad1: [56]u8,              // Padding to 64 bytes
        tail: CacheLineAtomic,      // Consumer writes
        _pad2: [56]u8,              // Padding to 64 bytes
        buffer: [capacity]T,

        const CacheLineAtomic = struct {
            value: std.atomic.Value(usize) align(64),
            _padding: [64 - @sizeOf(std.atomic.Value(usize))]u8,

            comptime {
                std.debug.assert(@sizeOf(@This()) == 64);
            }
        };
    };
}
```

### Memory Pool (Zero-Allocation Hot Path)
```zig
pub const OrderPool = struct {
    orders: []align(64) Order,  // Cache-aligned array
    free_list: []u32,           // Indices of free slots
    free_count: i32,            // Stack pointer

    pub fn acquire(self: *Self) ?*Order {
        if (self.free_count <= 0) return null;
        self.free_count -= 1;
        const idx = self.free_list[@intCast(self.free_count)];
        return &self.orders[idx];
    }

    pub fn release(self: *Self, order: *Order) void {
        const idx = (@intFromPtr(order) - @intFromPtr(self.orders.ptr)) / @sizeOf(Order);
        self.free_list[@intCast(self.free_count)] = @intCast(idx);
        self.free_count += 1;
    }
};
```

**Key Properties:**
- O(1) acquire and release
- No system calls in hot path
- Pre-allocated at startup
- 131,072 orders default (8MB)

---

## Data Structures

### Open-Addressing Hash Table

Used for O(1) order lookup by (user_id, order_id):
```zig
pub const OrderMap = struct {
    slots: [ORDER_MAP_SIZE]OrderMapSlot,  // 262,144 slots
    count: u32,
    tombstone_count: u32,

    // Power-of-2 size for fast modulo via bitmask
    const ORDER_MAP_SIZE = 262144;
    const ORDER_MAP_MASK = ORDER_MAP_SIZE - 1;

    inline fn hash(key: u64) u32 {
        const GOLDEN_RATIO: u64 = 0x9E3779B97F4A7C15;
        var k = key;
        k ^= k >> 33;
        k *%= GOLDEN_RATIO;
        k ^= k >> 29;
        return @intCast(k & ORDER_MAP_MASK);
    }
};
```

**Why Open-Addressing?**

| Metric | Chained Hash | Open-Addressing |
|--------|--------------|-----------------|
| Cache lines per lookup | 3-5 (random) | 1-2 (sequential) |
| Memory overhead | 24+ bytes/entry | 0 (inline) |
| Allocation | malloc per insert | None |

### Price Level Organization
```
Order Book (single symbol)
├── Bids (sorted descending by price)
│   ├── Level @ 10050: [Order1] → [Order2] → [Order3]
│   ├── Level @ 10025: [Order4]
│   └── Level @ 10000: [Order5] → [Order6]
└── Asks (sorted ascending by price)
    ├── Level @ 10075: [Order7]
    ├── Level @ 10100: [Order8] → [Order9]
    └── Level @ 10150: [Order10]
```

---

## Protocol Layer

### Protocol Detection
```zig
pub fn detectProtocol(data: []const u8) Protocol {
    if (data.len == 0) return .unknown;

    const first = data[0];

    if (first == 0x4D) return .binary;  // 'M' magic byte
    if (first == '8') {
        if (std.mem.startsWith(u8, data, "8=FIX")) return .fix;
    }
    if (first == 'N' or first == 'C' or first == 'F') return .csv;

    return .unknown;
}
```

### Binary Wire Format

All integers in **network byte order** (big-endian):
```
New Order (27 bytes):
┌──────┬──────┬──────────┬──────────┬───────┬─────┬──────┬──────────┐
│Magic │ Type │ user_id  │  symbol  │ price │ qty │ side │ order_id │
│ 0x4D │ 'N'  │ 4 bytes  │ 8 bytes  │  4B   │ 4B  │  1B  │  4 bytes │
└──────┴──────┴──────────┴──────────┴───────┴─────┴──────┴──────────┘

Trade (34 bytes):
┌──────┬──────┬──────────┬─────────┬─────────┬──────────┬──────────┬───────┬─────┐
│Magic │ Type │  symbol  │ buy_uid │ buy_oid │ sell_uid │ sell_oid │ price │ qty │
│ 0x4D │ 'T'  │ 8 bytes  │   4B    │   4B    │    4B    │    4B    │  4B   │ 4B  │
└──────┴──────┴──────────┴─────────┴─────────┴──────────┴──────────┴───────┴─────┘
```

### TCP Framing
```
┌─────────────────────────────────────────────────────┐
│ Length (4 bytes, big-endian) │ Payload (N bytes)   │
└─────────────────────────────────────────────────────┘
```

**Why framing?**
- TCP is a stream, not message-oriented
- Receiver needs to know where messages end
- 4 bytes supports messages up to 4GB (we limit to 16KB)

---

## Transport Layer

### Architecture Overview
```
                    ┌─────────────────────────┐
                    │    Matching Engine      │
                    │  (Symbol → OrderBook)   │
                    └───────────┬─────────────┘
                                │
                    ┌───────────┴───────────┐
                    │    Unified Server     │
                    │  (Message Routing)    │
                    └───────────┬───────────┘
           ┌────────────────────┼────────────────────┐
           │                    │                    │
    ┌──────┴──────┐     ┌───────┴───────┐    ┌──────┴──────┐
    │ TCP Server  │     │  UDP Server   │    │  Multicast  │
    │ (Framed)    │     │ (Bidirectional)│   │ (Broadcast) │
    │ Port 1234   │     │  Port 1235    │    │ 239.255.0.1 │
    └─────────────┘     └───────────────┘    └─────────────┘
```

### TCP Server Components

The TCP server is split into two components for testability:

**TcpClient** (per-connection state):
- Receive/send buffers (64KB each)
- Frame extraction with length-prefix parsing
- Connection state (disconnected, connected, draining)
- Per-client statistics

**TcpServer** (orchestration):
- Epoll-based event loop (edge-triggered)
- Client pool management
- Message routing to engine
- Response dispatching

### Client ID Scheme
```zig
// High bit distinguishes UDP from TCP clients
pub const CLIENT_ID_UDP_BASE: u32 = 0x80000000;

pub fn isUdpClient(client_id: u32) bool {
    return (client_id & CLIENT_ID_UDP_BASE) != 0;
}
```

### Message Routing

| Message Type | Destination |
|--------------|-------------|
| Ack | Originating client only |
| Cancel Ack | Originating client only |
| Reject | Originating client only |
| Trade | Both parties + Multicast |
| Top of Book | Multicast only |

---

## Threading Model

### Bounded Channel with Backoff
```zig
pub const RecvResult(T) = union(enum) {
    message: T,
    empty,
    closed,
};

pub fn recvTimeout(self: *Self, timeout_ns: u64) RecvResult(T) {
    var elapsed: u64 = 0;
    var sleep_ns: u64 = MIN_SLEEP_NS;

    while (elapsed < timeout_ns) {
        if (self.queue.pop()) |msg| {
            return .{ .message = msg };
        }

        if (self.closed.load(.acquire)) {
            return .closed;
        }

        // Exponential backoff
        std.time.sleep(sleep_ns);
        elapsed += sleep_ns;
        sleep_ns = @min(sleep_ns * 2, MAX_SLEEP_NS);
    }

    return .empty;
}
```

### Graceful Shutdown
```zig
// Signal shutdown
channel.close();

// Drain remaining messages
while (true) {
    switch (channel.recv()) {
        .message => |msg| processMessage(msg),
        .closed => break,
        .empty => break,
    }
}
```

---

## Matching Algorithm

### Price-Time Priority (FIFO)
```
Incoming BUY @ 100:
1. Find best ASK (lowest price)
2. If ASK price ≤ 100, match:
   - Fill at resting order's price
   - Oldest orders matched first
3. Repeat until:
   - Incoming order filled, OR
   - No more crossing prices
4. If quantity remains, add to BID book
```

### Matching Loop (Bounded)
```zig
fn matchOrder(self: *Self, incoming: *Order, output: *OutputBuffer) void {
    const opposite_side = incoming.side.opposite();
    var iterations: usize = 0;

    while (!incoming.isFilled() and iterations < MAX_MATCH_ITERATIONS) {
        const best_level = self.getBestLevel(opposite_side) orelse break;

        // Check price crossing
        if (!incoming.side.wouldCross(incoming.price, best_level.price)) break;

        // Match against orders at this level (FIFO)
        var resting = best_level.orders_head;
        while (resting) |order| : (iterations += 1) {
            if (iterations >= MAX_MATCH_ITERATIONS) break;

            const fill_qty = @min(incoming.remaining_qty, order.remaining_qty);

            // Execute fill
            _ = incoming.fill(fill_qty);
            _ = order.fill(fill_qty);

            // Emit trade
            output.add(makeTrade(...));

            // Remove filled orders
            if (order.isFilled()) {
                best_level.removeOrder(order);
                self.pools.release(order);
            }

            resting = order.next;
        }
    }
}
```

---

## Performance Analysis

### Memory Footprint

| Component | Size | Notes |
|-----------|------|-------|
| Order Pool | 8 MB | 131,072 × 64 bytes |
| Price Levels | 1.25 MB | 10,000 × 2 × 64 bytes |
| Order Map | 8 MB | 262,144 × 32 bytes |
| **Total** | **~18 MB** | Per engine instance |

### Latency Breakdown (Estimated)

| Operation | Time | Cache Lines |
|-----------|------|-------------|
| Protocol detect | ~5 ns | 1 |
| Message decode | ~20 ns | 1-2 |
| Hash lookup | ~15 ns | 1-2 |
| Price match | ~30 ns | 2-3 |
| Order insert | ~20 ns | 2 |
| Message encode | ~15 ns | 1 |
| **Total** | **~100 ns** | 8-11 |

### Throughput Capacity

| Mode | Messages/sec | Bottleneck |
|------|--------------|------------|
| Single-threaded | 5-10 M | CPU |
| Network (10 Gbps) | 1-2 M | NIC |
| UDP (local) | 10+ M | Kernel |

### Compile-Time Verification
```zig
// All critical sizes verified at compile time
comptime {
    std.debug.assert(@sizeOf(Order) == 64);
    std.debug.assert(@sizeOf(PriceLevel) == 64);
    std.debug.assert(@offsetOf(Order, "timestamp") == 32);
    std.debug.assert(ORDER_MAP_SIZE & (ORDER_MAP_SIZE - 1) == 0);
}
```

---

## Comparison with C Implementation

| Aspect | C | Zig |
|--------|---|-----|
| Memory layout | Identical | Identical |
| Wire protocol | Identical | Identical |
| Allocation model | malloc pools | Allocator interface |
| Safety | Assertions | Assertions + optionals |
| Build system | CMake | build.zig |
| Cross-compile | Complex | Built-in |

---

## Future Optimizations

1. **SIMD Matching** — AVX-512 for parallel price comparison
2. **io_uring** — Kernel bypass for lower syscall overhead
3. **Huge Pages** — Reduce TLB misses for large pools
4. **NUMA Awareness** — Pin to specific memory nodes
5. **DPDK** — Full kernel bypass for networking

---

## References

1. Ulrich Drepper, "What Every Programmer Should Know About Memory" (2007)
2. Gerard Holzmann, "Power of Ten: Rules for Developing Safety Critical Code" (2006)
3. Zig Language Reference: https://ziglang.org/documentation/
4. Intel Optimization Manual
