# Docker Deployment

*This document is a placeholder for Docker deployment documentation.*

## Quick Start

```bash
# Build image
make docker

# Run container
make docker-run

# View logs
make docker-logs

# Stop container
make docker-stop
```

## Configuration

The container accepts configuration via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ENGINE_TCP_PORT` | 1234 | TCP listen port |
| `ENGINE_VERBOSE` | false | Enable verbose logging |
| `ENGINE_THREADED` | true | Use multi-threaded mode |

## Docker Compose

```yaml
version: '3.8'
services:
  matching-engine:
    build: .
    ports:
      - "1234:1234"
    environment:
      - ENGINE_TCP_PORT=1234
      - ENGINE_THREADED=true
    restart: unless-stopped
```

## Building

```bash
# Standard build
docker build -t zig-matching-engine:latest .

# No cache rebuild
docker build --no-cache -t zig-matching-engine:latest .
```

## Running

```bash
# Detached mode
docker run -d \
  --name matching-engine \
  -p 1234:1234 \
  zig-matching-engine:latest

# Interactive mode
docker run -it --rm \
  -p 1234:1234 \
  zig-matching-engine:latest
```

## Health Checks

*TODO: Implement health check endpoint*

## Kubernetes

*TODO: Add Kubernetes deployment manifests*

## Monitoring

*TODO: Add Prometheus metrics and Grafana dashboards*
