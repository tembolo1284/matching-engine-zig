# Docker Guide

Complete guide to building, running, and deploying the Zig Matching Engine in Docker, including AWS deployment.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Building](#building)
3. [Running](#running)
4. [Configuration](#configuration)
5. [Docker Compose](#docker-compose)
6. [Testing](#testing)
7. [AWS Deployment](#aws-deployment)
8. [Production Hardening](#production-hardening)
9. [Troubleshooting](#troubleshooting)
10. [Quick Reference](#quick-reference)

---

## Quick Start

```bash
# Build
docker build -t zig-matching-engine .

# Run (threaded mode, all transports except multicast)
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine

# Test UDP
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 1235

# Test TCP (Python)
python3 -c "
import socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', 1234))
msg = b'N, 1, IBM, 10000, 100, B, 1\n'
s.send(struct.pack('>I', len(msg)) + msg)
print('Sent order, check container logs')
s.close()
"

# View logs
docker logs -f matching-engine

# Stop
docker stop matching-engine && docker rm matching-engine
```

---

## Building

### Standard Build

```bash
docker build -t zig-matching-engine .
```

### Multi-Architecture Build

Build for both AMD64 and ARM64 (Graviton):

```bash
# Setup buildx (one time)
docker buildx create --name multiarch --use

# Build for multiple platforms
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t zig-matching-engine:latest \
  --push \
  .
```

### Platform-Specific Builds

```bash
# AMD64 (Intel/AMD)
docker build --platform linux/amd64 -t zig-matching-engine:amd64 .

# ARM64 (Apple Silicon, AWS Graviton)
docker build --platform linux/arm64 -t zig-matching-engine:arm64 .
```

### Build with Custom Tag

```bash
docker build -t zig-matching-engine:v0.1.0 .
docker build -t myregistry/matching-engine:latest .
```

### Clean Build (No Cache)

```bash
docker build --no-cache -t zig-matching-engine .
```

---

## Running

### Basic Run

Starts with threaded mode enabled by default:

```bash
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

**Default Ports:**
| Port | Protocol | Description |
|------|----------|-------------|
| 1234 | TCP | Length-prefixed framed messages |
| 1235 | UDP | Raw messages (no framing) |
| 1236 | UDP | Multicast market data (disabled by default) |

### Run Options

#### Single-Threaded Mode (Debugging)

```bash
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine \
  /usr/local/bin/matching_engine  # No --threaded flag
```

#### Custom Ports

```bash
docker run -d \
  --name matching-engine \
  -p 8000:8000 \
  -p 8001:8001/udp \
  -e ENGINE_TCP_PORT=8000 \
  -e ENGINE_UDP_PORT=8001 \
  zig-matching-engine
```

#### TCP Only

```bash
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -e ENGINE_UDP_ENABLED=false \
  -e ENGINE_MCAST_ENABLED=false \
  zig-matching-engine
```

#### UDP Only

```bash
docker run -d \
  --name matching-engine \
  -p 1235:1235/udp \
  -e ENGINE_TCP_ENABLED=false \
  -e ENGINE_MCAST_ENABLED=false \
  zig-matching-engine
```

#### With Multicast (Host Networking Required)

```bash
docker run -d \
  --name matching-engine \
  --network host \
  -e ENGINE_MCAST_ENABLED=true \
  -e ENGINE_MCAST_GROUP=239.255.0.1 \
  zig-matching-engine
```

**Note:** Multicast requires `--network host` to work properly. Port mapping is not needed with host networking.

#### Interactive Mode (Debugging)

```bash
docker run -it --rm \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ENGINE_THREADED` | `true` | Enable dual-processor mode |
| `ENGINE_TCP_ENABLED` | `true` | Enable TCP transport |
| `ENGINE_TCP_PORT` | `1234` | TCP listen port |
| `ENGINE_UDP_ENABLED` | `true` | Enable UDP transport |
| `ENGINE_UDP_PORT` | `1235` | UDP listen port |
| `ENGINE_MCAST_ENABLED` | `false` | Enable multicast (requires host networking) |
| `ENGINE_MCAST_GROUP` | `239.255.0.1` | Multicast group address |
| `ENGINE_MCAST_PORT` | `1236` | Multicast port |
| `ENGINE_MCAST_TTL` | `1` | Multicast TTL (1 = local subnet) |

### Full Configuration Example

```bash
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  -p 1235:1235/udp \
  -e ENGINE_TCP_ENABLED=true \
  -e ENGINE_TCP_PORT=1234 \
  -e ENGINE_UDP_ENABLED=true \
  -e ENGINE_UDP_PORT=1235 \
  -e ENGINE_MCAST_ENABLED=false \
  -e ENGINE_THREADED=true \
  zig-matching-engine
```

---

## Docker Compose

### Basic Usage

```bash
# Start
docker compose up -d

# View logs
docker compose logs -f

# Stop
docker compose down

# Rebuild and start
docker compose up -d --build
```

### docker-compose.yml

```yaml
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
      - ENGINE_MCAST_ENABLED=false
      - ENGINE_THREADED=true
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "1234"]
      interval: 30s
      timeout: 5s
      retries: 3
```

### Environment Overrides

```bash
# Custom ports
TCP_PORT=8000 UDP_PORT=8001 docker compose up -d

# More resources
CPU_LIMIT=4.0 MEMORY_LIMIT=2G docker compose up -d

# Custom image tag
TAG=v0.1.0 docker compose up -d
```

### Multicast Configuration (Host Network)

```yaml
services:
  matching-engine:
    build: .
    network_mode: host
    environment:
      - ENGINE_MCAST_ENABLED=true
      - ENGINE_MCAST_GROUP=239.255.0.1
    restart: unless-stopped
```

---

## Testing

### Health Check

```bash
# Check container status
docker ps
docker inspect --format='{{.State.Health.Status}}' matching-engine

# Manual TCP check
nc -z localhost 1234 && echo "TCP OK" || echo "TCP FAIL"

# Manual UDP check (send flush command)
echo "F" | nc -u -w1 localhost 1235
```

### Send Test Orders

#### UDP (Simple)

```bash
# New order: Buy 100 IBM @ $100.00
echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 1235

# Cancel order
echo "C, 1, 1, IBM" | nc -u -w1 localhost 1235
```

#### TCP (Python)

```python
import socket
import struct

def send_tcp_order(host, port, msg):
    """Send order with 4-byte big-endian length prefix."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((host, port))
    sock.send(struct.pack('>I', len(msg)) + msg)
    
    # Read response
    length = struct.unpack('>I', sock.recv(4))[0]
    response = sock.recv(length)
    sock.close()
    return response

# Send buy order
msg = b"N, 1, AAPL, 15000, 100, B, 1\n"
response = send_tcp_order('localhost', 1234, msg)
print(f"Response: {response.decode()}")
```

#### Binary Protocol (UDP)

```python
import socket
import struct

def make_binary_order(user_id, symbol, price, qty, side, order_id):
    """Create binary new order (27 bytes, big-endian)."""
    return struct.pack(
        '>BB I 8s I I B I',
        0x4D,                              # magic
        ord('N'),                          # msg_type
        user_id,
        symbol.encode().ljust(8, b'\x00'),
        price,
        qty,
        ord(side),
        order_id
    )

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
msg = make_binary_order(1, "AAPL", 15000, 100, 'B', 1)
sock.sendto(msg, ('localhost', 1235))
print(f"Sent {len(msg)} bytes: {msg.hex()}")
```

### View Container Logs

```bash
# Follow logs
docker logs -f matching-engine

# Last 100 lines
docker logs --tail 100 matching-engine

# With timestamps
docker logs -t matching-engine
```

---

## AWS Deployment

### Prerequisites

```bash
# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Configure credentials
aws configure
```

### Push to Amazon ECR

```bash
# Variables
AWS_REGION=us-east-1
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO=matching-engine

# Create ECR repository
aws ecr create-repository \
  --repository-name $ECR_REPO \
  --region $AWS_REGION

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Tag and push (AMD64)
docker build -t $ECR_REPO:latest .
docker tag $ECR_REPO:latest \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest
docker push \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest

# Multi-arch build and push (AMD64 + ARM64)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest \
  --push \
  .
```

### ECS Fargate Deployment

#### 1. Create Task Definition

Save as `task-definition.json`:

```json
{
  "family": "matching-engine",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "matching-engine",
      "image": "ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/matching-engine:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 1234,
          "protocol": "tcp"
        },
        {
          "containerPort": 1235,
          "protocol": "udp"
        }
      ],
      "environment": [
        {"name": "ENGINE_THREADED", "value": "true"},
        {"name": "ENGINE_TCP_ENABLED", "value": "true"},
        {"name": "ENGINE_UDP_ENABLED", "value": "true"},
        {"name": "ENGINE_MCAST_ENABLED", "value": "false"}
      ],
      "healthCheck": {
        "command": ["CMD", "nc", "-z", "localhost", "1234"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 10
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/matching-engine",
          "awslogs-region": "REGION",
          "awslogs-stream-prefix": "ecs",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
```

#### 2. Register Task Definition

```bash
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region $AWS_REGION
```

#### 3. Create ECS Cluster

```bash
aws ecs create-cluster \
  --cluster-name matching-engine-cluster \
  --capacity-providers FARGATE FARGATE_SPOT \
  --region $AWS_REGION
```

#### 4. Create Service

```bash
aws ecs create-service \
  --cluster matching-engine-cluster \
  --service-name matching-engine-service \
  --task-definition matching-engine \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx],assignPublicIp=ENABLED}" \
  --region $AWS_REGION
```

### EC2 Deployment (Low Latency)

For lowest latency, deploy directly on EC2 with host networking:

#### 1. Launch EC2 Instance

```bash
# Use Graviton for better price/performance
aws ec2 run-instances \
  --image-id ami-0c55b159cbfafe1f0 \
  --instance-type c7g.large \
  --key-name your-key \
  --security-group-ids sg-xxx \
  --subnet-id subnet-xxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=matching-engine}]'
```

#### 2. Install Docker

```bash
# On the EC2 instance
sudo yum update -y
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user
```

#### 3. Run Container

```bash
# Pull from ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

docker pull ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/matching-engine:latest

# Run with host networking (lowest latency)
docker run -d \
  --name matching-engine \
  --network host \
  --restart unless-stopped \
  -e ENGINE_THREADED=true \
  -e ENGINE_MCAST_ENABLED=true \
  ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/matching-engine:latest
```

### AWS Security Groups

```bash
# Create security group
aws ec2 create-security-group \
  --group-name matching-engine-sg \
  --description "Matching Engine ports"

# Allow TCP 1234
aws ec2 authorize-security-group-ingress \
  --group-name matching-engine-sg \
  --protocol tcp \
  --port 1234 \
  --cidr 10.0.0.0/8

# Allow UDP 1235
aws ec2 authorize-security-group-ingress \
  --group-name matching-engine-sg \
  --protocol udp \
  --port 1235 \
  --cidr 10.0.0.0/8
```

### CloudWatch Logging

View logs:

```bash
aws logs tail /ecs/matching-engine --follow
```

Create metric filter for errors:

```bash
aws logs put-metric-filter \
  --log-group-name /ecs/matching-engine \
  --filter-name ErrorCount \
  --filter-pattern "error" \
  --metric-transformations \
    metricName=ErrorCount,metricNamespace=MatchingEngine,metricValue=1
```

---

## Production Hardening

### Resource Limits

```bash
docker run -d \
  --name matching-engine \
  --memory=1g \
  --memory-swap=1g \
  --cpus=2 \
  --ulimit nofile=65536:65536 \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### Security Options

```bash
docker run -d \
  --name matching-engine \
  --read-only \
  --security-opt=no-new-privileges:true \
  --cap-drop=ALL \
  --cap-add=NET_BIND_SERVICE \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### Logging Configuration

```bash
docker run -d \
  --name matching-engine \
  --log-driver=json-file \
  --log-opt max-size=100m \
  --log-opt max-file=5 \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### Restart Policy

```bash
docker run -d \
  --name matching-engine \
  --restart=unless-stopped \
  -p 1234:1234 \
  -p 1235:1235/udp \
  zig-matching-engine
```

### All Production Options Combined

```bash
docker run -d \
  --name matching-engine \
  --restart=unless-stopped \
  --memory=1g \
  --cpus=2 \
  --ulimit nofile=65536:65536 \
  --read-only \
  --security-opt=no-new-privileges:true \
  --cap-drop=ALL \
  --cap-add=NET_BIND_SERVICE \
  --log-driver=json-file \
  --log-opt max-size=100m \
  --log-opt max-file=5 \
  -p 1234:1234 \
  -p 1235:1235/udp \
  -e ENGINE_THREADED=true \
  zig-matching-engine
```

---

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker logs matching-engine

# Run interactively
docker run -it --rm zig-matching-engine

# Check health
docker inspect --format='{{json .State.Health}}' matching-engine | jq
```

### Port Already in Use

```bash
# Find process using port
sudo lsof -i :1234
sudo netstat -tlnp | grep 1234

# Use different port
docker run -p 8000:1234 zig-matching-engine
```

### UDP Not Working

```bash
# Check port is exposed
docker port matching-engine

# Test from inside container
docker exec -it matching-engine sh -c "nc -z localhost 1235"

# Check firewall
sudo iptables -L -n | grep 1235
```

### High Latency

```bash
# Use host networking (bypasses Docker NAT)
docker run --network host zig-matching-engine

# Or use macvlan for direct L2 access
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  -o parent=eth0 \
  trading-net

docker run --network trading-net zig-matching-engine
```

### Container Keeps Restarting

```bash
# Check exit code
docker inspect matching-engine --format='{{.State.ExitCode}}'

# Check OOM killed
docker inspect matching-engine --format='{{.State.OOMKilled}}'

# Increase memory limit
docker run --memory=2g zig-matching-engine
```

### Performance Issues

```bash
# Check resource usage
docker stats matching-engine

# Check for throttling
docker inspect matching-engine --format='{{json .HostConfig.CpuQuota}}'
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Build | `docker build -t zig-matching-engine .` |
| Build ARM64 | `docker build --platform linux/arm64 -t zig-matching-engine:arm64 .` |
| Run | `docker run -d -p 1234:1234 -p 1235:1235/udp zig-matching-engine` |
| Run (host net) | `docker run -d --network host zig-matching-engine` |
| View logs | `docker logs -f matching-engine` |
| Health check | `docker inspect --format='{{.State.Health.Status}}' matching-engine` |
| Stop | `docker stop matching-engine` |
| Remove | `docker rm matching-engine` |
| Shell access | `docker exec -it matching-engine sh` |
| Test TCP | `nc -z localhost 1234` |
| Test UDP | `echo "N, 1, IBM, 10000, 100, B, 1" \| nc -u -w1 localhost 1235` |
| Push to ECR | `docker push ACCOUNT.dkr.ecr.REGION.amazonaws.com/matching-engine:latest` |

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
# Docker Hub
docker tag zig-matching-engine:latest username/matching-engine:latest
docker push username/matching-engine:latest

# AWS ECR
docker tag zig-matching-engine:latest \
  ACCOUNT.dkr.ecr.REGION.amazonaws.com/matching-engine:latest
docker push ACCOUNT.dkr.ecr.REGION.amazonaws.com/matching-engine:latest
```
