# Docker Guide

Complete guide to building and running the Zig Matching Engine in Docker.

## Quick Start
```bash
# Build
docker build -t zig-matching-engine .

# Run (all transports enabled by default)
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine

# Test
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 1235

# Stop
docker stop matching-engine && docker rm matching-engine
```

---

## Build Options

### Standard Build
```bash
docker build -t zig-matching-engine .
```

### Build with Custom Tag
```bash
docker build -t zig-matching-engine:v1.0.0 .
docker build -t myregistry/zig-matching-engine:latest .
```

### Build with No Cache (Clean Build)
```bash
docker build --no-cache -t zig-matching-engine .
```

### Build for Different Platform
```bash
# Build for ARM64 (e.g., Apple Silicon, AWS Graviton)
docker build --platform linux/arm64 -t zig-matching-engine:arm64 .

# Build for AMD64
docker build --platform linux/amd64 -t zig-matching-engine:amd64 .
```

---

## Run Options

### Basic Run (All Transports)

The server starts with **all transports enabled by default**:
- TCP on port 1234 (with 4-byte length framing)
- UDP on port 1235 (bidirectional, no framing)
- Multicast on 239.255.0.1:1236
```bash
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### Run with Custom Ports
```bash
docker run -d \
  --name matching-engine \
  -p 8000:9000 \
  -p 8001:9001/udp \
  -e ENGINE_TCP_PORT=1234 \
  -e ENGINE_UDP_PORT=1235 \
  zig-matching-engine
```

### Run with Specific Transports Disabled
```bash
# TCP only (disable UDP and multicast)
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -e ENGINE_UDP_ENABLED=false \
  -e ENGINE_MCAST_ENABLED=false \
  zig-matching-engine

# UDP only
docker run -d \
  --name matching-engine \
  -p 1235:1235/udp \
  -e ENGINE_TCP_ENABLED=false \
  -e ENGINE_MCAST_ENABLED=false \
  zig-matching-engine
```

### Run with Multicast (Host Networking)

Multicast requires host networking to work properly:
```bash
docker run -d \
  --name matching-engine \
  --network host \
  zig-matching-engine
```

**Note:** With `--network host`, the container shares the host's network stack. No port mapping needed - ports are directly accessible.

### Run Interactive (for Debugging)
```bash
docker run -it --rm \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### Run with Volume (for Logs)
```bash
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -p 1235:1235/udp \
  -v $(pwd)/logs:/var/log/engine \
  zig-matching-engine
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ENGINE_TCP_ENABLED` | `true` | Enable TCP transport |
| `ENGINE_TCP_ADDR` | `0.0.0.0` | TCP bind address |
| `ENGINE_TCP_PORT` | `1234` | TCP port |
| `ENGINE_UDP_ENABLED` | `true` | Enable UDP transport |
| `ENGINE_UDP_ADDR` | `0.0.0.0` | UDP bind address |
| `ENGINE_UDP_PORT` | `1235` | UDP port |
| `ENGINE_MCAST_ENABLED` | `true` | Enable multicast |
| `ENGINE_MCAST_GROUP` | `239.255.0.1` | Multicast group address |
| `ENGINE_MCAST_PORT` | `1236` | Multicast port |
| `ENGINE_MCAST_TTL` | `1` | Multicast TTL (1 = local subnet) |

### Example: Full Configuration
```bash
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -p 1235:1235/udp \
  -e ENGINE_TCP_ENABLED=true \
  -e ENGINE_TCP_PORT=1234 \
  -e ENGINE_UDP_ENABLED=true \
  -e ENGINE_UDP_PORT=1235 \
  -e ENGINE_MCAST_ENABLED=true \
  -e ENGINE_MCAST_GROUP=239.255.0.1 \
  -e ENGINE_MCAST_PORT=1236 \
  -e ENGINE_MCAST_TTL=1 \
  zig-matching-engine
```

---

## Docker Compose

### Basic Setup

Create `docker-compose.yml`:
```yaml
version: '3.8'

services:
  matching-engine:
    build: .
    image: zig-matching-engine:latest
    container_name: matching-engine
    ports:
      - "1234:1234"      # TCP
      - "1235:1235/udp"  # UDP
    environment:
      - ENGINE_TCP_ENABLED=true
      - ENGINE_UDP_ENABLED=true
      - ENGINE_MCAST_ENABLED=false  # Disable in bridge mode
    restart: unless-stopped
```

### Run with Docker Compose
```bash
# Start
docker-compose up -d

# View logs
docker-compose logs -f

# Stop
docker-compose down

# Rebuild and start
docker-compose up -d --build
```

### With Multicast (Host Network)
```yaml
version: '3.8'

services:
  matching-engine:
    build: .
    image: zig-matching-engine:latest
    container_name: matching-engine
    network_mode: host
    environment:
      - ENGINE_MCAST_ENABLED=true
      - ENGINE_MCAST_GROUP=239.255.0.1
    restart: unless-stopped
```

### Multiple Instances (Different Symbols)
```yaml
version: '3.8'

services:
  engine-az:
    build: .
    container_name: engine-az
    ports:
      - "1234:1234"
      - "1235:1235/udp"
    environment:
      - ENGINE_SYMBOL_RANGE=A-M
    
  engine-nz:
    build: .
    container_name: engine-nz
    ports:
      - "9100:1234"
      - "9101:1235/udp"
    environment:
      - ENGINE_SYMBOL_RANGE=N-Z
```

---

## Testing the Container

### Check Container is Running
```bash
docker ps
docker logs matching-engine
```

### Test TCP Connection
```bash
# Using Python (handles framing)
python3 -c "
import socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', 1234))
msg = b'N, 1, IBM, 10000, 100, B, 1\n'
s.send(struct.pack('>I', len(msg)) + msg)
print('Sent:', msg)
s.close()
"
```

### Test UDP Connection
```bash
# Simple UDP test (no framing needed)
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 1235
```

### Test Binary Protocol (UDP)
```bash
python3 -c "
import socket, struct

# Create binary new order
magic = 0x4D
msg_type = ord('N')
user_id = 1
symbol = b'IBM\x00\x00\x00\x00\x00'
price = 10000
qty = 100
side = ord('B')
order_id = 1

msg = struct.pack('>BB I 8s I I B I',
    magic, msg_type, user_id, symbol, price, qty, side, order_id)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.sendto(msg, ('localhost', 1235))
print(f'Sent binary: {msg.hex()}')
"
```

### Health Check
```bash
# Check if TCP port is responding
nc -z localhost 1234 && echo "TCP OK" || echo "TCP FAIL"

# Check if UDP port is responding
echo "F" | nc -u -w1 localhost 1235 && echo "UDP OK"
```

---

## Production Deployment

### Resource Limits
```bash
docker run -d \
  --name matching-engine \
  --memory=512m \
  --cpus=2 \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### With Restart Policy
```bash
docker run -d \
  --name matching-engine \
  --restart=unless-stopped \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### With Logging Configuration
```bash
docker run -d \
  --name matching-engine \
  --log-driver=json-file \
  --log-opt max-size=100m \
  --log-opt max-file=3 \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### Security: Read-Only Filesystem
```bash
docker run -d \
  --name matching-engine \
  --read-only \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

---

## Troubleshooting

### Container Won't Start
```bash
# Check logs
docker logs matching-engine

# Run interactively to see errors
docker run -it --rm zig-matching-engine
```

### Port Already in Use
```bash
# Find what's using the port
lsof -i :1234
netstat -tlnp | grep 1234

# Kill the process or use different port
docker run -p 9100:1234 zig-matching-engine
```

### UDP Not Working
```bash
# Check UDP port is exposed
docker port matching-engine

# Test from inside container
docker exec -it matching-engine sh -c "nc -u -l 1235"
```

### Multicast Not Working

1. Use host networking: `--network host`
2. Ensure multicast is enabled on host network
3. Check TTL setting (may need TTL > 1 for cross-subnet)
```bash
# Check multicast routing
ip route show | grep multicast
netstat -gn  # Show multicast group memberships
```

### High Latency
```bash
# Run with host networking (bypasses Docker NAT)
docker run --network host zig-matching-engine

# Or use macvlan for direct L2 access
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  -o parent=eth0 \
  trading-net

docker run --network trading-net zig-matching-engine
```

---

## Image Management

### List Images
```bash
docker images | grep matching-engine
```

### Remove Image
```bash
docker rmi zig-matching-engine
```

### Save/Load Image
```bash
# Save to file
docker save zig-matching-engine:latest | gzip > matching-engine.tar.gz

# Load from file
docker load < matching-engine.tar.gz
```

### Push to Registry
```bash
docker tag zig-matching-engine:latest myregistry/matching-engine:latest
docker push myregistry/matching-engine:latest
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Build | `docker build -t zig-matching-engine .` |
| Run (all transports) | `docker run -d -p 1234:1234 -p 1235:1235/udp zig-matching-engine` |
| Run (with multicast) | `docker run -d --network host zig-matching-engine` |
| View logs | `docker logs -f matching-engine` |
| Stop | `docker stop matching-engine` |
| Remove | `docker rm matching-engine` |
| Shell access | `docker exec -it matching-engine sh` |
| Test UDP | `echo "N,1,IBM,100,50,B,1" \| nc -u -w1 localhost 1235` |
