# Quick Start Guide

Get the Zig Matching Engine up and running in 5 minutes.

## Prerequisites

- **Zig 0.13.0+**: Download from [ziglang.org](https://ziglang.org/download/)
- **Linux or macOS** (Windows not currently supported)
- **netcat** (nc) for testing (usually pre-installed)

Verify Zig installation:
```bash
zig version
# Should output: 0.13.0 or later
```

## Step 1: Build

```bash
# Clone (or extract) the project
cd matching-engine-zig

# Build in debug mode
make build
# Or: zig build

# Run tests to verify everything works
make test
```

## Step 2: Start the Server

### Option A: Threaded Mode (Recommended for Production)

```bash
make run-threaded
# Or: ENGINE_THREADED=true zig build run
```

Expected output:
```
info: System: Linux x86_64
info: Starting threaded server...
info: Processor-0 (A-M) started (latency_tracking=true, panic_on_critical_drop=true)
info: Processor-1 (N-Z) started (latency_tracking=true, panic_on_critical_drop=true)
info: TCP server listening on 0.0.0.0:1234
info: UDP server listening on 0.0.0.0:1235
info: Multicast publishing to 239.255.0.1:1236
info: Threaded server started (2 processors)

╔════════════════════════════════════════════╗
║     Zig Matching Engine v0.1.0             ║
╠════════════════════════════════════════════╣
║  TCP:       0.0.0.0:1234                   ║
║  UDP:       0.0.0.0:1235                   ║
║  Multicast: 239.255.0.1:1236               ║
║  Protocol:  CSV                            ║
║  I/O:       epoll                          ║
║  Mode:      Dual-Processor                 ║
║  Proc 0:    Symbols A-M                    ║
║  Proc 1:    Symbols N-Z                    ║
╚════════════════════════════════════════════╝

Press Ctrl+C to shutdown gracefully
```

### Option B: Single-Threaded Mode (Debugging)

```bash
make run
# Or: zig build run
```

## Step 3: Send Orders

### Using UDP (Simplest)

UDP requires no framing - just send the CSV message directly.

**Terminal 2 - Send a buy order:**
```bash
echo "N, 1, AAPL, 15000, 100, B, 1" | nc -u -w1 localhost 1235
```

This creates: Buy 100 shares of AAPL @ $150.00 (price in cents)

### Using TCP (Reliable)

TCP requires 4-byte big-endian length prefix. Use Python:

```python
import socket
import struct

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 1234))

# Send order with length prefix
msg = b"N, 1, AAPL, 15000, 100, B, 1\n"
sock.send(struct.pack('>I', len(msg)) + msg)

# Receive response
length = struct.unpack('>I', sock.recv(4))[0]
response = sock.recv(length)
print("Response:", response.decode())

sock.close()
```

Expected response: `A, AAPL, 1, 1` (Ack for user_id=1, order_id=1)

## Step 4: Execute a Trade

Open two terminals to simulate two traders:

**Terminal 2 - Trader 1 sends a buy:**
```bash
echo "N, 1, AAPL, 15000, 100, B, 1" | nc -u -w1 localhost 1235
```

**Terminal 3 - Trader 2 sends a matching sell:**
```bash
echo "N, 2, AAPL, 15000, 50, S, 1" | nc -u -w1 localhost 1235
```

The sell at $150 matches the buy at $150. A trade executes for 50 shares.

**Server logs will show:**
```
Trade: AAPL 50 @ 15000 (buy_uid=1, sell_uid=2)
```

## Message Format Reference

### Input Messages

| Type | Format | Example |
|------|--------|---------|
| New Order | `N, <user_id>, <symbol>, <price>, <qty>, <side>, <order_id>` | `N, 1, AAPL, 15000, 100, B, 1` |
| Cancel | `C, <user_id>, <order_id>, [symbol]` | `C, 1, 1, AAPL` |
| Flush | `F` | `F` |

**Field Details:**
- `user_id`: Your client identifier (any u32, non-zero)
- `symbol`: 1-8 character stock symbol (e.g., `AAPL`, `IBM`)
- `price`: Price in cents (e.g., 15000 = $150.00)
- `qty`: Number of shares (must be > 0)
- `side`: `B` for buy, `S` for sell
- `order_id`: Your order identifier (unique per user)

### Output Messages

| Type | Format | Meaning |
|------|--------|---------|
| Ack | `A, <symbol>, <user_id>, <order_id>` | Order accepted |
| Trade | `T, <symbol>, <buy_uid>, <buy_oid>, <sell_uid>, <sell_oid>, <price>, <qty>` | Execution |
| Top of Book | `B, <symbol>, <side>, <price>, <qty>` | BBO update |
| Cancel Ack | `C, <symbol>, <user_id>, <order_id>` | Cancel confirmed |
| Reject | `R, <symbol>, <user_id>, <order_id>, <reason>` | Order rejected |

**Reject Reasons:**
| Code | Meaning |
|------|---------|
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

## Example Trading Session

```bash
# Terminal 1: Start server
make run-threaded

# Terminal 2: Send orders via UDP
# Buy 100 AAPL @ $150
echo "N, 1, AAPL, 15000, 100, B, 1" | nc -u -w1 localhost 1235

# Buy 50 AAPL @ $149 (won't match yet)
echo "N, 1, AAPL, 14900, 50, B, 2" | nc -u -w1 localhost 1235

# Sell 75 AAPL @ $150 (matches the $150 bid!)
echo "N, 2, AAPL, 15000, 75, S, 1" | nc -u -w1 localhost 1235

# Cancel the $149 bid
echo "C, 1, 2, AAPL" | nc -u -w1 localhost 1235
```

## Using Binary Protocol

For lower latency, use the binary protocol over UDP:

```python
import struct
import socket

def make_binary_order(user_id, symbol, price, qty, side, order_id):
    """
    Binary new order format (27 bytes, big-endian):
    - magic (1B): 0x4D
    - msg_type (1B): 'N' (0x4E)
    - user_id (4B)
    - symbol (8B, null-padded)
    - price (4B)
    - quantity (4B)
    - side (1B): 'B' or 'S'
    - user_order_id (4B)
    """
    return struct.pack(
        '>BB I 8s I I B I',
        0x4D,                              # magic
        ord('N'),                          # msg_type
        user_id,
        symbol.encode().ljust(8, b'\x00'), # null-padded symbol
        price,
        qty,
        ord(side),
        order_id
    )

# Send binary order
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
msg = make_binary_order(1, "AAPL", 15000, 100, 'B', 1)
sock.sendto(msg, ('localhost', 1235))
print(f"Sent {len(msg)} bytes: {msg.hex()}")
```

## Configuration

### Environment Variables

```bash
# Network ports
export ENGINE_TCP_PORT=1234
export ENGINE_UDP_PORT=1235
export ENGINE_MCAST_GROUP=239.255.0.1
export ENGINE_MCAST_PORT=1236

# Enable/disable transports
export ENGINE_TCP_ENABLED=true
export ENGINE_UDP_ENABLED=true
export ENGINE_MCAST_ENABLED=true

# Threading
export ENGINE_THREADED=true

# Performance
export ENGINE_CHANNEL_CAPACITY=65536
```

### Build Options

```bash
# Debug build (default)
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Release with safety checks
zig build -Doptimize=ReleaseSafe
```

## Monitoring

### Server Statistics

Press Ctrl+C for graceful shutdown. The server logs statistics:

```
═══════════════ Session Statistics ═══════════════
  Messages routed:    Proc0=1250, Proc1=1250
  Total processed:    2500
  Outputs dispatched: 4800
  Messages dropped:   0
  Disconnect cancels: 0
  Processor 0:
    Messages:    1250
    Outputs:     2400
    Backpressure:0
    Avg latency: 850ns
  Processor 1:
    Messages:    1250
    Outputs:     2400
    Backpressure:0
    Avg latency: 920ns
═══════════════════════════════════════════════════
```

### Health Indicators

A healthy system has:
- `Messages dropped: 0` (input queues not overflowing)
- `Backpressure: 0` or low (output queues keeping up)
- Avg latency in microseconds or low nanoseconds

## Troubleshooting

### "Connection refused"

Server isn't running or wrong port:
```bash
# Check if server is listening
ss -tlnp | grep 1234  # TCP
ss -ulnp | grep 1235  # UDP
```

### No response on UDP

UDP is stateless. To see responses, listen first:
```bash
# Terminal A: Listen for responses
nc -ul 1235 &

# Terminal B: Send order (responses go back to sender)
echo "N, 1, AAPL, 15000, 100, B, 1" | nc -u localhost 1235
```

### Orders not matching

1. **Check price format**: Price is in integer cents, not dollars
   - Correct: `15000` (= $150.00)
   - Wrong: `150.00`

2. **Check symbol routing**: A-M symbols go to Processor 0, N-Z to Processor 1
   - AAPL → Processor 0
   - TSLA → Processor 1

3. **Check side**: Buy at X matches Sell at X or lower

### "Queue full" warnings

System is overloaded:
- Reduce order rate
- Increase `ENGINE_CHANNEL_CAPACITY` (must be power of 2)
- Use Release build: `zig build -Doptimize=ReleaseFast`

## Next Steps

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) for design details
2. Review the [README.md](../README.md) for full API documentation
3. Look at `src/protocol/message_types.zig` for message definitions
4. Run `make test` to see test examples
