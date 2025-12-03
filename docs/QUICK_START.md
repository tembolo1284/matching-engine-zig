# Quick Start Guide

Get the Zig Matching Engine running in under 5 minutes.

## Prerequisites

- Zig 0.11.0 or later (`zig version` to check)
- netcat (`nc`) for testing
- Optional: Docker for containerized deployment

## 1. Build
```bash
# Clone and enter directory
cd zig_matching_engine

# Build (debug)
zig build

# Or build optimized
zig build -Doptimize=ReleaseFast
```

## 2. Run Server
```bash
# Start with all transports enabled
zig build run

# Or run binary directly
./zig-out/bin/matching_engine
```

You should see:
```
info: TCP server listening on 0.0.0.0:9000 (framing=true)
info: UDP server listening on 0.0.0.0:9001
info: Multicast publisher started: 239.255.0.1:9002 (TTL=1)
info: Zig Matching Engine Ready
info:   TCP: 0.0.0.0:9000 (4-byte length framing)
info:   UDP: 0.0.0.0:9001 (bidirectional)
info:   Multicast: 239.255.0.1:9002
info:   Binary magic: 0x4D ('M'), Network byte order
```

## 3. Send Test Orders (UDP - Easiest)

UDP requires no framing, perfect for quick testing:
```bash
# Terminal 2: Send a buy order
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 9001
```

**Message breakdown:**
- `N` - New order
- `1` - User ID
- `IBM` - Symbol
- `10000` - Price ($100.00 in cents)
- `100` - Quantity (shares)
- `B` - Side (Buy)
- `1` - Order ID

## 4. Create a Trade
```bash
# Send buy order
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 9001

# Send matching sell order
echo "N, 2, IBM, 10000, 50, S, 1" | nc -u -w1 localhost 9001
```

**Expected server output:**
```
A, IBM, 1, 1           # Buy order acknowledged
B, IBM, B, 10000, 100  # Top of book: 100 shares at $100
A, IBM, 2, 1           # Sell order acknowledged
T, IBM, 1, 1, 2, 1, 10000, 50  # Trade executed!
B, IBM, B, 10000, 50   # Top of book: 50 shares remaining
```

## 5. Cancel an Order
```bash
echo "C, 1, 1" | nc -u -w1 localhost 9001
```

**Output:**
```
C, IBM, 1, 1           # Cancel acknowledged
B, IBM, B, -, -        # Book now empty on bid side
```

## 6. Flush All Orders
```bash
echo "F" | nc -u -w1 localhost 9001
```

---

## TCP Testing (With Framing)

TCP requires 4-byte length prefix. Here's a Python helper:
```python
#!/usr/bin/env python3
# tcp_client.py
import socket
import struct

def send_order(sock, message):
    data = message.encode('utf-8')
    # 4-byte big-endian length prefix
    frame = struct.pack('>I', len(data)) + data
    sock.sendall(frame)
    
    # Read response
    header = sock.recv(4)
    if len(header) == 4:
        length = struct.unpack('>I', header)[0]
        response = sock.recv(length)
        print(f"Response: {response.decode('utf-8')}")

# Connect
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 9000))

# Send orders
send_order(sock, "N, 1, IBM, 10000, 100, B, 1\n")
send_order(sock, "N, 2, IBM, 10000, 50, S, 1\n")

sock.close()
```

Run it:
```bash
python3 tcp_client.py
```

---

## Binary Protocol Testing

For binary protocol, use the magic byte `0x4D`:
```python
#!/usr/bin/env python3
# binary_client.py
import socket
import struct

def create_new_order(user_id, symbol, price, qty, side, order_id):
    """Create binary new order message."""
    magic = 0x4D
    msg_type = ord('N')
    symbol_bytes = symbol.encode('ascii').ljust(8, b'\0')
    
    # Pack in network byte order (big-endian)
    return struct.pack(
        '>BB I 8s I I B I',
        magic, msg_type,
        user_id,
        symbol_bytes,
        price,
        qty,
        ord(side),
        order_id
    )

# UDP - no framing
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
msg = create_new_order(1, "IBM", 10000, 100, 'B', 1)
sock.sendto(msg, ('localhost', 9001))

# Receive response
data, addr = sock.recvfrom(1024)
print(f"Response ({len(data)} bytes): {data.hex()}")
```

---

## Multicast Subscriber

To receive market data broadcasts:
```python
#!/usr/bin/env python3
# mcast_subscriber.py
import socket
import struct

MCAST_GROUP = '239.255.0.1'
MCAST_PORT = 9002

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('', MCAST_PORT))

# Join multicast group
mreq = struct.pack('4sl', socket.inet_aton(MCAST_GROUP), socket.INADDR_ANY)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

print(f"Listening on {MCAST_GROUP}:{MCAST_PORT}...")

while True:
    data, addr = sock.recvfrom(1024)
    if data[0] == 0x4D:
        print(f"Binary: {data.hex()}")
    else:
        print(f"CSV: {data.decode('utf-8').strip()}")
```

---

## Environment Configuration

Override defaults with environment variables:
```bash
# Custom ports
export ENGINE_TCP_PORT=8000
export ENGINE_UDP_PORT=8001
export ENGINE_MCAST_PORT=8002
export ENGINE_MCAST_GROUP=239.255.1.1

# Disable transports
export ENGINE_TCP_ENABLED=false
export ENGINE_MCAST_ENABLED=false

zig build run
```

---

## Docker Quick Start
```bash
# Build image
docker build -t zig-matching-engine .

# Run container
docker run -p 9000:9000 -p 9001:9001/udp zig-matching-engine

# Test from host
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 9001
```

---

## Common Issues

### "Address already in use"
```bash
# Find and kill existing process
lsof -i :9000
kill <PID>
```

### UDP messages not received
- Check firewall: `sudo ufw allow 9001/udp`
- Ensure netcat uses UDP: `nc -u` flag

### Multicast not working
- Multicast requires network support
- Use loopback for local testing
- Check TTL settings (default=1, local subnet only)

### Binary messages rejected
- Verify magic byte is `0x4D` (not `0x01`)
- Verify big-endian byte order
- Check message sizes match spec

---

## Next Steps

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) for system design details
2. Review protocol spec in [docs/PROTOCOL.md](docs/PROTOCOL.md)
3. Run benchmarks: `zig build bench`
4. Deploy with Docker: see [Dockerfile](Dockerfile)
