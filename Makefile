# =============================================================================
# Zig Matching Engine - Makefile
# =============================================================================
#
# Common commands made easy. While `zig build` handles most things,
# this Makefile provides convenient shortcuts for development workflows.
#
# Usage:
#   make              # Build debug
#   make release      # Build optimized
#   make run          # Build and run (single-threaded)
#   make run-threaded # Build and run (dual-processor)
#   make test         # Run all tests
#   make bench        # Run benchmarks
#   make docker       # Build Docker image
#   make clean        # Clean build artifacts
#
# =============================================================================

.PHONY: all build release run test clean docker docker-run docker-stop help
.DEFAULT_GOAL := all

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Default ports (must match config.zig defaults)
TCP_PORT ?= 1234
UDP_PORT ?= 1235
MCAST_PORT ?= 1236
MCAST_GROUP ?= 239.255.0.1

# Docker settings
DOCKER_IMAGE := zig-matching-engine
DOCKER_TAG := latest
DOCKER_CONTAINER := matching-engine

# Zig build output
BUILD_DIR := zig-out
BIN := $(BUILD_DIR)/bin/matching_engine
BENCH_BIN := $(BUILD_DIR)/bin/benchmark
CLIENT_BIN := $(BUILD_DIR)/bin/engine_client

# -----------------------------------------------------------------------------
# Build Targets
# -----------------------------------------------------------------------------

## Default: build debug version
all: build

## Build debug version
build:
	zig build

## Build release version (optimized for speed)
release:
	zig build -Doptimize=ReleaseFast

## Build with safety checks (optimized but safe)
release-safe:
	zig build -Doptimize=ReleaseSafe

## Build small release (optimized for size)
release-small:
	zig build -Doptimize=ReleaseSmall

## Fast type-check without code generation
check:
	zig build check

# -----------------------------------------------------------------------------
# Run Targets
# -----------------------------------------------------------------------------

## Build and run server (single-threaded, debug)
run: build
	$(BIN)

## Build and run server (release, single-threaded)
run-release: release
	$(BIN)

## Run in dual-processor threaded mode
run-threaded:
	ENGINE_THREADED=true zig build run

## Run threaded with release build
run-threaded-release: release
	ENGINE_THREADED=true $(BIN)

## Run with TCP only
run-tcp:
	ENGINE_UDP_ENABLED=false ENGINE_MCAST_ENABLED=false zig build run

## Run with UDP only
run-udp:
	ENGINE_TCP_ENABLED=false ENGINE_MCAST_ENABLED=false zig build run

## Run with custom ports
run-custom:
	ENGINE_TCP_PORT=$(TCP_PORT) ENGINE_UDP_PORT=$(UDP_PORT) zig build run

## Show help
run-help: build
	$(BIN) --help

## Show version
run-version: build
	$(BIN) --version

# -----------------------------------------------------------------------------
# Test Targets
# -----------------------------------------------------------------------------

## Run all unit tests
test:
	zig build test

## Run tests with summary
test-summary:
	zig build test 2>&1 | tail -20

## Run specific test file
test-file:
	@test -n "$(FILE)" || (echo "Usage: make test-file FILE=src/path/to/file.zig" && exit 1)
	zig test $(FILE)

# --- Protocol Tests ---
test-protocol:
	zig test src/protocol/message_types.zig
	zig test src/protocol/codec.zig
	zig test src/protocol/binary_codec.zig
	zig test src/protocol/csv_codec.zig

# --- Core Tests ---
test-core:
	zig test src/core/order.zig
	zig test src/core/memory_pool.zig
	zig test src/core/order_book.zig
	zig test src/core/matching_engine.zig

# --- Collections Tests ---
test-collections:
	zig test src/collections/spsc_queue.zig
	zig test src/collections/bounded_channel.zig

# --- Transport Tests ---
test-transport:
	zig test src/transport/config.zig
	zig test src/transport/net_utils.zig
	zig test src/transport/tcp_client.zig
	zig test src/transport/tcp_server.zig
	zig test src/transport/udp_server.zig
	zig test src/transport/multicast.zig

# --- Threading Tests ---
test-threading:
	zig test src/threading/processor.zig
	zig test src/threading/threaded_server.zig

# -----------------------------------------------------------------------------
# Benchmarks
# -----------------------------------------------------------------------------

## Build and run benchmarks
bench: release
	zig build bench
	$(BENCH_BIN)

## Quick throughput test (requires running server)
bench-quick:
	@echo "Sending 1000 orders via UDP..."
	@for i in $$(seq 1 1000); do \
		echo "N, 1, IBM, 10000, 1, B, $$i"; \
	done | nc -u -w1 localhost $(UDP_PORT)
	@echo "Done"

## Latency test placeholder
bench-latency:
	@echo "Latency benchmark not yet implemented"
	@echo "Use: perf stat $(BIN) for CPU profiling"

# -----------------------------------------------------------------------------
# Integration Tests (Requires Running Server)
# -----------------------------------------------------------------------------

## Send test order via UDP (CSV format)
send-udp:
	@echo "Sending test order via UDP to port $(UDP_PORT)..."
	echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost $(UDP_PORT)

## Send test order via TCP (with length framing)
send-tcp:
	@echo "Sending test order via TCP to port $(TCP_PORT)..."
	@python3 -c "\
import socket, struct; \
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); \
s.connect(('localhost', $(TCP_PORT))); \
msg = b'N, 1, IBM, 10000, 100, B, 1\n'; \
s.send(struct.pack('>I', len(msg)) + msg); \
print('Sent:', msg.decode()); \
resp = s.recv(1024); \
print('Received:', resp.decode() if resp else '(none)'); \
s.close()"

## Send binary protocol order via UDP
send-binary:
	@echo "Sending binary order via UDP..."
	@python3 -c "\
import socket, struct; \
msg = struct.pack('>BB I 8s I I B I', \
    0x4D, ord('N'), 1, b'IBM\x00\x00\x00\x00\x00', 10000, 100, ord('B'), 1); \
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); \
sock.sendto(msg, ('localhost', $(UDP_PORT))); \
print('Sent binary:', msg.hex())"

## Send buy/sell/cancel sequence
send-orders:
	@echo "=== Order Sequence Test ==="
	@echo "1. Sending buy order..."
	@echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost $(UDP_PORT)
	@sleep 0.2
	@echo "2. Sending matching sell order..."
	@echo "N, 2, IBM, 10000, 50, S, 1" | nc -u -w1 localhost $(UDP_PORT)
	@sleep 0.2
	@echo "3. Sending cancel for remaining..."
	@echo "C, 1, 1" | nc -u -w1 localhost $(UDP_PORT)
	@echo "=== Done ==="

## Flush all orders
send-flush:
	@echo "Flushing all orders..."
	echo "F" | nc -u -w1 localhost $(UDP_PORT)

## Test dual-processor routing (A-M vs N-Z)
send-routing-test:
	@echo "=== Symbol Routing Test ==="
	@echo "Processor 0 (A-M):"
	@echo "  AAPL..." && echo "N, 1, AAPL, 15000, 100, B, 1" | nc -u -w1 localhost $(UDP_PORT)
	@echo "  IBM..."  && echo "N, 1, IBM, 10000, 100, B, 2" | nc -u -w1 localhost $(UDP_PORT)
	@echo "  META..." && echo "N, 1, META, 30000, 100, B, 3" | nc -u -w1 localhost $(UDP_PORT)
	@echo "Processor 1 (N-Z):"
	@echo "  NVDA..." && echo "N, 2, NVDA, 50000, 100, B, 1" | nc -u -w1 localhost $(UDP_PORT)
	@echo "  TSLA..." && echo "N, 2, TSLA, 25000, 100, B, 2" | nc -u -w1 localhost $(UDP_PORT)
	@echo "  ZM..."   && echo "N, 2, ZM, 8000, 100, B, 3" | nc -u -w1 localhost $(UDP_PORT)
	@echo "=== Done ==="

# -----------------------------------------------------------------------------
# Docker Targets
# -----------------------------------------------------------------------------

## Build Docker image
docker:
	docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) .

## Build Docker image (no cache)
docker-rebuild:
	docker build --no-cache -t $(DOCKER_IMAGE):$(DOCKER_TAG) .

## Run Docker container (single-threaded)
docker-run: docker
	docker run -d \
		--name $(DOCKER_CONTAINER) \
		-p $(TCP_PORT):$(TCP_PORT) \
		-p $(UDP_PORT):$(UDP_PORT)/udp \
		-p $(MCAST_PORT):$(MCAST_PORT)/udp \
		$(DOCKER_IMAGE):$(DOCKER_TAG)
	@echo "Container started: $(DOCKER_CONTAINER)"
	@echo "TCP:  localhost:$(TCP_PORT)"
	@echo "UDP:  localhost:$(UDP_PORT)"
	@echo "Logs: make docker-logs"

## Run Docker container (threaded mode)
docker-run-threaded: docker
	docker run -d \
		--name $(DOCKER_CONTAINER) \
		-p $(TCP_PORT):$(TCP_PORT) \
		-p $(UDP_PORT):$(UDP_PORT)/udp \
		-e ENGINE_THREADED=true \
		$(DOCKER_IMAGE):$(DOCKER_TAG)
	@echo "Container started (threaded): $(DOCKER_CONTAINER)"

## Run with host networking (for multicast)
docker-run-host: docker
	docker run -d \
		--name $(DOCKER_CONTAINER) \
		--network host \
		$(DOCKER_IMAGE):$(DOCKER_TAG)
	@echo "Container started with host networking"

## Run interactively (foreground)
docker-run-it: docker
	docker run -it --rm \
		-p $(TCP_PORT):$(TCP_PORT) \
		-p $(UDP_PORT):$(UDP_PORT)/udp \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

## Stop and remove container
docker-stop:
	-docker stop $(DOCKER_CONTAINER)
	-docker rm $(DOCKER_CONTAINER)

## View container logs
docker-logs:
	docker logs -f $(DOCKER_CONTAINER)

## Shell into running container
docker-shell:
	docker exec -it $(DOCKER_CONTAINER) sh

## Show container status
docker-status:
	@docker ps -f name=$(DOCKER_CONTAINER) --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

## Docker Compose up
compose-up:
	docker compose up -d

## Docker Compose down
compose-down:
	docker compose down

## Docker Compose logs
compose-logs:
	docker compose logs -f

# -----------------------------------------------------------------------------
# Clean Targets
# -----------------------------------------------------------------------------

## Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)/
	rm -rf .zig-cache/
	rm -rf zig-cache/

## Clean everything including Docker
clean-all: clean docker-stop
	-docker rmi $(DOCKER_IMAGE):$(DOCKER_TAG)

# -----------------------------------------------------------------------------
# Development Tools
# -----------------------------------------------------------------------------

## Format source code
fmt:
	zig fmt src/

## Check formatting (for CI)
fmt-check:
	zig fmt --check src/

## Watch and rebuild on changes (requires entr)
watch:
	@command -v entr >/dev/null 2>&1 || (echo "Install entr: apt install entr" && exit 1)
	find src -name '*.zig' | entr -c make build

## Watch and test on changes
watch-test:
	@command -v entr >/dev/null 2>&1 || (echo "Install entr: apt install entr" && exit 1)
	find src -name '*.zig' | entr -c make test

## Count lines of code
loc:
	@echo "Lines of Zig code:"
	@find src -name '*.zig' | xargs wc -l | tail -1

## Show TODO/FIXME comments
todos:
	@grep -rn "TODO\|FIXME\|XXX\|HACK" src/ --include="*.zig" || echo "No TODOs found!"

# -----------------------------------------------------------------------------
# CI/CD
# -----------------------------------------------------------------------------

## Full CI check (format, test, build)
ci: fmt-check test build
	@echo "✓ CI checks passed"

## Pre-commit hook (fast checks)
pre-commit: fmt-check check
	@echo "✓ Pre-commit checks passed"

## Create release distribution
dist: clean release
	@mkdir -p dist
	@cp $(BIN) dist/
	@cp README.md dist/ 2>/dev/null || true
	@cp QUICK_START.md dist/ 2>/dev/null || true
	@tar -czvf dist/matching-engine-$$(uname -s)-$$(uname -m).tar.gz -C dist .
	@echo "Distribution: dist/matching-engine-$$(uname -s)-$$(uname -m).tar.gz"

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

## Show this help
help:
	@echo ""
	@echo "Zig Matching Engine - Build System"
	@echo "==================================="
	@echo ""
	@echo "Build:"
	@echo "  make              Build debug version"
	@echo "  make release      Build optimized version"
	@echo "  make check        Fast type-check (no codegen)"
	@echo "  make clean        Clean build artifacts"
	@echo ""
	@echo "Run:"
	@echo "  make run          Run single-threaded (debug)"
	@echo "  make run-release  Run single-threaded (release)"
	@echo "  make run-threaded Run dual-processor mode"
	@echo "  make run-tcp      Run with TCP only"
	@echo "  make run-udp      Run with UDP only"
	@echo ""
	@echo "Test:"
	@echo "  make test         Run all unit tests"
	@echo "  make test-core    Run core module tests"
	@echo "  make test-protocol Run protocol tests"
	@echo "  make bench        Run benchmarks"
	@echo ""
	@echo "Integration (server must be running):"
	@echo "  make send-udp     Send CSV order via UDP"
	@echo "  make send-tcp     Send CSV order via TCP"
	@echo "  make send-binary  Send binary order via UDP"
	@echo "  make send-orders  Send buy/sell/cancel sequence"
	@echo ""
	@echo "Docker:"
	@echo "  make docker       Build Docker image"
	@echo "  make docker-run   Run container"
	@echo "  make docker-stop  Stop container"
	@echo "  make docker-logs  View logs"
	@echo ""
	@echo "Development:"
	@echo "  make fmt          Format code"
	@echo "  make watch        Rebuild on changes"
	@echo "  make watch-test   Test on changes"
	@echo "  make ci           Run CI checks"
	@echo ""
	@echo "Configuration (environment variables):"
	@echo "  TCP_PORT=$(TCP_PORT)  UDP_PORT=$(UDP_PORT)  MCAST_PORT=$(MCAST_PORT)"
	@echo ""
