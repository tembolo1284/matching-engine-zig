# Quick Start Guide

Get the Zig Matching Engine running in under 5 minutes.

## Prerequisites

- **Zig 0.15.0+**: Download from [ziglang.org](https://ziglang.org/download/)
- **Linux**: Tested on Ubuntu 24.04 (other distributions should work)
- **Make**: For convenient build commands

## Installation

```bash
# Clone the repository
git clone https://github.com/yourname/matching-engine-zig.git
cd matching-engine-zig

# Build the engine
make build
```

## Running the Server

```bash
# Start with defaults (port 1234)
make run

# Or with custom port
make run TCP_PORT=9000

# Or with verbose logging
make run-verbose
```

You should see output like:

```
Struct sizes:
  Order:           64 bytes
  InputMsg:        40 bytes
  OutputMsg:       52 bytes
  InputEnvelope:   64 bytes
  OutputEnvelope:  64 bytes

============================================
     Zig Matching Engine v0.1.0
============================================
  TCP:       0.0.0.0:1234
  Protocol:  Binary (0x4D) / FIX 4.2
  Mode:      Multi-Threaded (per-client)
============================================
Press Ctrl+C to shutdown gracefully
```

## Sending Test Orders

### Using the Binary Protocol

The engine uses a compact binary protocol. Here's a simple Python client:

```python
import socket
import struct

def send_new_order(sock, user_id, order_id, symbol, price, qty, side):
    """Send a new order using the binary protocol."""
    msg = bytearray(27)
    msg[0] = 0x4D  # Magic byte
    msg[1] = ord('N')  # New order
    struct.pack_into('>I', msg, 2, user_id)
    msg[6:14] = symbol.ljust(8, '\x00').encode()[:8]
    struct.pack_into('>I', msg, 14, price)
    struct.pack_into('>I', msg, 18, qty)
    msg[22] = ord('B') if side == 'buy' else ord('S')
    struct.pack_into('>I', msg, 23, order_id)
    sock.send(msg)

def recv_ack(sock):
    """Receive and parse an ack message."""
    data = sock.recv(18)
    if len(data) == 18 and data[0] == 0x4D and data[1] == ord('A'):
        symbol = data[2:10].rstrip(b'\x00').decode()
        user_id = struct.unpack('>I', data[10:14])[0]
        order_id = struct.unpack('>I', data[14:18])[0]
        return {'symbol': symbol, 'user_id': user_id, 'order_id': order_id}
    return None

# Connect and send an order
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 1234))

send_new_order(sock, user_id=1, order_id=100, symbol='IBM', 
               price=150, qty=1000, side='buy')

ack = recv_ack(sock)
print(f"Order acknowledged: {ack}")

sock.close()
```

### Creating a Trade

To see a trade execute, send matching orders:

```python
# Client 1: Post a sell order
send_new_order(sock1, user_id=1, order_id=1, symbol='IBM', 
               price=100, qty=500, side='sell')

# Client 2: Send a crossing buy order
send_new_order(sock2, user_id=2, order_id=1, symbol='IBM',
               price=100, qty=300, side='buy')

# Both clients receive:
# - Ack for their order
# - Trade execution (300 shares @ 100)
```

## Running Tests

```bash
# All tests
make test

# Specific module tests
make test-core       # Matching logic
make test-protocol   # Encode/decode
make test-threading  # Queues and processor
```

## Benchmarking

```bash
# Build optimized and run benchmarks
make bench
```

## Graceful Shutdown

Press `Ctrl+C` to shutdown. The engine will:

1. Stop accepting new connections
2. Drain pending messages
3. Close all client connections
4. Print session statistics

```
^C
Shutting down...
[TCP] Stopping threaded server...

============ Session Statistics ============
  Messages processed: 10000
  Trades generated:   5000
  Acks generated:     10000
  Connections:        2 accepted, 2 closed
  Messages routed:    15000
  Route failures:     0
=============================================

Shutdown complete
```

## Next Steps

- Read [ARCHITECTURE.md](ARCHITECTURE.md) for technical details
- Check the [README](../README.md) for full documentation
- Review the source code in `src/`
