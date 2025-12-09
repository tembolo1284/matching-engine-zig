# Quick Start Guide

Get the Zig Matching Engine up and running in 5 minutes.

## Prerequisites

- **Zig 0.13.0+**: Download from [ziglang.org](https://ziglang.org/download/)
- **Linux or macOS** (Windows support is experimental)
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

### Option A: Threaded Mode (Production)

```bash
make run-threaded
```

Expected output:
```
info: Starting threaded server...
info: Config: channel_capacity=65536, drain_limit=131072, batch_size=1400, max_batches=64
info: Processor-0 (A-M) started (latency_tracking=true, panic_on_critical_drop=true)
info: Processor-1 (N-Z) started (latency_tracking=true, panic_on_critical_drop=true)
info: TCP server listening on 0.0.0.0:8080
info: UDP server listening on 0.0.0.0:8081
info: Threaded server started (2 processors)
```

### Option B: Single-Threaded Mode (Debugging)

```bash
make run
```

## Step 3: Send Orders

### Using TCP (Recommended)

TCP provides reliable, ordered delivery with acknowledgments.

**Terminal 2 - Connect to server:**
```bash
# Using netcat (length-prefixed framing not needed for simple test)
nc localhost 8080
```

**Send a new order:**
```
N,AAPL,1001,1,B,15000,100
```

**Expected response:**
```
A,AAPL,1,0
```

This means: Order acknowledged for AAPL, user_order_id=1, status=0 (success)

### Using UDP (Low-Latency)

UDP provides lower latency but no delivery guarantee.

**Terminal 2:**
```bash
# Send order via UDP
echo "N,AAPL,1001,1,B,15000,100" | nc -u localhost 8081

# Listen for responses (in a separate terminal)
nc -ul 8081
```

## Step 4: Execute a Trade

**Terminal 2 - Send a buy order:**
```bash
echo "N,AAPL,1001,1,B,15000,100" | nc -u localhost 8081
```

**Terminal 3 - Send a matching sell order:**
```bash
echo "N,AAPL,1002,1,S,15000,50" | nc -u localhost 8081
```

**Expected output (on server):**
```
# Trade executed: 50 shares @ $150.00
T,AAPL,15000,50,<buy_order_id>,<sell_order_id>
```

## Message Format Reference

### Input Messages

| Type | Format | Example |
|------|--------|---------|
| New Order | `N,<symbol>,<user_id>,<user_order_id>,<side>,<price>,<qty>` | `N,AAPL,1001,1,B,15000,100` |
| Cancel | `C,<symbol>,<user_id>,<user_order_id>` | `C,AAPL,1001,1` |

**Field Details:**
- `symbol`: 1-8 character stock symbol (e.g., `AAPL`, `MSFT`)
- `user_id`: Your client identifier (any u32)
- `user_order_id`: Your order identifier (unique per user)
- `side`: `B` for buy, `S` for sell
- `price`: Price in cents (e.g., 15000 = $150.00)
- `qty`: Number of shares

### Output Messages

| Type | Format | Meaning |
|------|--------|---------|
| Ack | `A,<symbol>,<user_order_id>,<status>` | Order accepted (status=0) |
| Reject | `R,<symbol>,<user_order_id>,<reason>` | Order rejected |
| Trade | `T,<symbol>,<price>,<qty>,<buy_id>,<sell_id>` | Execution report |
| Cancel Ack | `X,<symbol>,<user_order_id>,<qty>` | Cancel confirmed |
| Top of Book | `B,<symbol>,<bid>,<ask>,<bid_qty>,<ask_qty>` | BBO update |

**Reject Reasons:**
- 0: Unknown
- 1: Invalid symbol
- 2: Invalid price
- 3: Invalid quantity
- 4: Invalid side
- 5: Order not found
- 6: Duplicate order ID

## Example Trading Session

```bash
# Terminal 1: Start server
make run-threaded

# Terminal 2: Send orders
nc localhost 8080

# Enter these commands one by one:
N,AAPL,1001,1,B,15000,100    # Buy 100 AAPL @ $150
N,AAPL,1001,2,B,14900,50     # Buy 50 AAPL @ $149
N,AAPL,1002,1,S,15000,75     # Sell 75 AAPL @ $150 (matches!)
C,AAPL,1001,2                 # Cancel the $149 bid
```

**Expected responses:**
```
A,AAPL,1,0                    # Ack for order 1
A,AAPL,2,0                    # Ack for order 2
A,AAPL,1,0                    # Ack for sell order
T,AAPL,15000,75,1,1           # Trade: 75 @ $150
X,AAPL,2,50                   # Cancel ack for order 2
```

## Using Binary Protocol

For lower latency, use the binary protocol (64-byte fixed messages):

```python
import struct
import socket

# Message types
NEW_ORDER = 1
CANCEL = 2

# Sides
BUY = 1
SELL = 2

def make_new_order(symbol, user_id, user_order_id, side, price, qty):
    msg = struct.pack(
        '<BB8sIIQI34s',  # Little-endian format
        NEW_ORDER,       # msg_type (1 byte)
        side,            # side (1 byte)
        symbol.encode().ljust(8, b'\x00'),  # symbol (8 bytes)
        user_id,         # user_id (4 bytes)
        user_order_id,   # user_order_id (4 bytes)
        price,           # price (8 bytes)
        qty,             # quantity (4 bytes)
        b'\x00' * 34     # padding (34 bytes)
    )
    return msg

# Connect and send
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
msg = make_new_order("AAPL", 1001, 1, BUY, 15000, 100)
sock.sendto(msg, ('localhost', 8081))
```

## Configuration

### Environment Variables

```bash
# Network ports
export ME_TCP_PORT=8080
export ME_UDP_PORT=8081
export ME_MCAST_GROUP=239.0.0.1
export ME_MCAST_PORT=8082

# Enable/disable transports
export ME_TCP_ENABLED=true
export ME_UDP_ENABLED=true
export ME_MCAST_ENABLED=false

# Performance tuning
export ME_CHANNEL_CAPACITY=65536
export ME_TRACK_LATENCY=true
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

The server logs statistics on shutdown:

```
info: Stopping threaded server...
info: Stats: batches_sent=1234, outputs_dispatched=5678, messages_dropped=0
info: Processor-0 (A-M) stopped (processed=2500, outputs=4800, backpressure=0, critical_drops=0)
info: Processor-1 (N-Z) stopped (processed=2500, outputs=4800, backpressure=0, critical_drops=0)
```

### Health Check

A healthy system has:
- `critical_drops=0` (trades and rejects delivered)
- `messages_dropped=0` (input queues not overflowing)
- `backpressure=0` or low (output queues keeping up)

## Troubleshooting

### "Connection refused"

Server isn't running or wrong port:
```bash
# Check if server is listening
ss -tlnp | grep 8080
```

### "Queue full, dropping message"

System is overloaded:
- Reduce order rate
- Increase `ME_CHANNEL_CAPACITY`
- Use Release build for better performance

### Orders not matching

Check price format (price is in cents, not dollars):
- `15000` = $150.00
- `14999` = $149.99

### No response on UDP

UDP is stateless; responses go to sender's address:
```bash
# Use nc in listen mode to see responses
nc -ul 8081 &
echo "N,AAPL,1001,1,B,15000,100" | nc -u localhost 8081
```

## Next Steps

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) for design details
2. Review the [README.md](README.md) for full API documentation
3. Examine `src/main.zig` for configuration options
4. Run `make test` to see test examples

## Getting Help

- Check test files in `src/*/` for usage examples
- Run with debug logging: `zig build run 2>&1 | less`
- File issues on the project repository
