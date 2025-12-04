# =============================================================================
# Zig Matching Engine - Makefile
# =============================================================================

.PHONY: all build release run test clean docker docker-run docker-stop help
.DEFAULT_GOAL := all

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

TCP_PORT ?= 1234
UDP_PORT ?= 1235
MCAST_PORT ?= 1236
MCAST_GROUP ?= 239.255.0.1

DOCKER_IMAGE := zig-matching-engine
DOCKER_TAG := latest
DOCKER_CONTAINER := matching-engine

BUILD_DIR := zig-out
BIN := $(BUILD_DIR)/bin/matching_engine
BENCH_BIN := $(BUILD_DIR)/bin/benchmark
CLIENT_BIN := $(BUILD_DIR)/bin/engine_client

# -----------------------------------------------------------------------------
# Build Targets
# -----------------------------------------------------------------------------

all: build

build:
	zig build

release:
	zig build -Doptimize=ReleaseFast

release-safe:
	zig build -Doptimize=ReleaseSafe

release-small:
	zig build -Doptimize=ReleaseSmall

check:
	zig build check

# -----------------------------------------------------------------------------
# Run Targets (Binary Protocol Default)
# -----------------------------------------------------------------------------

## Run single-threaded with binary protocol (default)
run: build
	@exec env ENGINE_BINARY_PROTOCOL=true $(BIN)

## Run release with binary protocol
run-release: release
	@exec env ENGINE_BINARY_PROTOCOL=true $(BIN)

## Run threaded with binary protocol (default)
run-threaded: build
	@exec env ENGINE_BINARY_PROTOCOL=true ENGINE_THREADED=true $(BIN)

## Run threaded release with binary protocol
run-threaded-release: release
	@exec env ENGINE_BINARY_PROTOCOL=true ENGINE_THREADED=true $(BIN)

## Run with TCP only (binary)
run-tcp: build
	@exec env ENGINE_BINARY_PROTOCOL=true ENGINE_UDP_ENABLED=false ENGINE_MCAST_ENABLED=false $(BIN)

## Run with UDP only (binary)
run-udp: build
	@exec env ENGINE_BINARY_PROTOCOL=true ENGINE_TCP_ENABLED=false ENGINE_MCAST_ENABLED=false $(BIN)

# -----------------------------------------------------------------------------
# Run Targets (CSV Protocol - for testing)
# -----------------------------------------------------------------------------

## Run single-threaded with CSV protocol
run-csv: build
	@exec env ENGINE_BINARY_PROTOCOL=false $(BIN)

## Run threaded with CSV protocol
run-threaded-csv: build
	@exec env ENGINE_BINARY_PROTOCOL=false ENGINE_THREADED=true $(BIN)

## Run with TCP only (CSV)
run-tcp-csv: build
	@exec env ENGINE_BINARY_PROTOCOL=false ENGINE_UDP_ENABLED=false ENGINE_MCAST_ENABLED=false $(BIN)

## Run with UDP only (CSV)
run-udp-csv: build
	@exec env ENGINE_BINARY_PROTOCOL=false ENGINE_TCP_ENABLED=false ENGINE_MCAST_ENABLED=false $(BIN)

## Run with custom ports (binary)
run-custom: build
	@exec env ENGINE_BINARY_PROTOCOL=true ENGINE_TCP_PORT=$(TCP_PORT) ENGINE_UDP_PORT=$(UDP_PORT) $(BIN)

## Show help
run-help: build
	$(BIN) --help

## Show version
run-version: build
	$(BIN) --version

# -----------------------------------------------------------------------------
# Test Targets
# -----------------------------------------------------------------------------

test:
	zig build test

test-summary:
	zig build test 2>&1 | tail -20

test-file:
	@test -n "$(FILE)" || (echo "Usage: make test-file FILE=src/path/to/file.zig" && exit 1)
	zig test $(FILE)

test-protocol:
	zig test src/protocol/message_types.zig
	zig test src/protocol/codec.zig
	zig test src/protocol/binary_codec.zig
	zig test src/protocol/csv_codec.zig

test-collections:
	zig test src/collections/spsc_queue.zig
	zig test src/collections/bounded_channel.zig

# -----------------------------------------------------------------------------
# Benchmarks
# -----------------------------------------------------------------------------

bench: release
	zig build bench
	$(BENCH_BIN)

bench-quick:
	@echo "Sending 1000 orders via UDP..."
	@for i in $$(seq 1 1000); do \
		echo "N, 1, IBM, 10000, 1, B, $$i"; \
	done | nc -u -w1 localhost $(UDP_PORT)
	@echo "Done"

# -----------------------------------------------------------------------------
# Integration Tests (CSV - human readable)
# -----------------------------------------------------------------------------

send-udp:
	@echo "Sending test order via UDP to port $(UDP_PORT)..."
	echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost $(UDP_PORT)

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

send-binary:
	@echo "Sending binary order via UDP..."
	@python3 -c "\
import socket, struct; \
msg = struct.pack('>BB I 8s I I B I', \
    0x4D, ord('N'), 1, b'IBM\x00\x00\x00\x00\x00', 10000, 100, ord('B'), 1); \
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); \
sock.sendto(msg, ('localhost', $(UDP_PORT))); \
print('Sent binary:', msg.hex())"

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

send-flush:
	@echo "Flushing all orders..."
	echo "F" | nc -u -w1 localhost $(UDP_PORT)

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

docker:
	docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) .

docker-rebuild:
	docker build --no-cache -t $(DOCKER_IMAGE):$(DOCKER_TAG) .

docker-run: docker
	docker run -d \
		--name $(DOCKER_CONTAINER) \
		-p $(TCP_PORT):$(TCP_PORT) \
		-p $(UDP_PORT):$(UDP_PORT)/udp \
		-p $(MCAST_PORT):$(MCAST_PORT)/udp \
		-e ENGINE_BINARY_PROTOCOL=true \
		$(DOCKER_IMAGE):$(DOCKER_TAG)
	@echo "Container started: $(DOCKER_CONTAINER)"

docker-run-threaded: docker
	docker run -d \
		--name $(DOCKER_CONTAINER) \
		-p $(TCP_PORT):$(TCP_PORT) \
		-p $(UDP_PORT):$(UDP_PORT)/udp \
		-e ENGINE_THREADED=true \
		-e ENGINE_BINARY_PROTOCOL=true \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

docker-run-host: docker
	docker run -d \
		--name $(DOCKER_CONTAINER) \
		--network host \
		-e ENGINE_BINARY_PROTOCOL=true \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

docker-run-it: docker
	docker run -it --rm \
		-p $(TCP_PORT):$(TCP_PORT) \
		-p $(UDP_PORT):$(UDP_PORT)/udp \
		-e ENGINE_BINARY_PROTOCOL=true \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

docker-stop:
	-docker stop $(DOCKER_CONTAINER)
	-docker rm $(DOCKER_CONTAINER)

docker-logs:
	docker logs -f $(DOCKER_CONTAINER)

docker-shell:
	docker exec -it $(DOCKER_CONTAINER) sh

docker-status:
	@docker ps -f name=$(DOCKER_CONTAINER) --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

compose-up:
	docker compose up -d

compose-down:
	docker compose down

compose-logs:
	docker compose logs -f

# -----------------------------------------------------------------------------
# Clean Targets
# -----------------------------------------------------------------------------

clean:
	rm -rf $(BUILD_DIR)/
	rm -rf .zig-cache/
	rm -rf zig-cache/

clean-all: clean docker-stop
	-docker rmi $(DOCKER_IMAGE):$(DOCKER_TAG)

# -----------------------------------------------------------------------------
# Development Tools
# -----------------------------------------------------------------------------

fmt:
	zig fmt src/

fmt-check:
	zig fmt --check src/

watch:
	@command -v entr >/dev/null 2>&1 || (echo "Install entr: apt install entr" && exit 1)
	find src -name '*.zig' | entr -c make build

watch-test:
	@command -v entr >/dev/null 2>&1 || (echo "Install entr: apt install entr" && exit 1)
	find src -name '*.zig' | entr -c make test

loc:
	@echo "Lines of Zig code:"
	@find src -name '*.zig' | xargs wc -l | tail -1

todos:
	@grep -rn "TODO\|FIXME\|XXX\|HACK" src/ --include="*.zig" || echo "No TODOs found!"

# -----------------------------------------------------------------------------
# CI/CD
# -----------------------------------------------------------------------------

ci: fmt-check test build
	@echo "✓ CI checks passed"

pre-commit: fmt-check check
	@echo "✓ Pre-commit checks passed"

dist: clean release
	@mkdir -p dist
	@cp $(BIN) dist/
	@cp README.md dist/ 2>/dev/null || true
	@tar -czvf dist/matching-engine-$$(uname -s)-$$(uname -m).tar.gz -C dist .
	@echo "Distribution: dist/matching-engine-$$(uname -s)-$$(uname -m).tar.gz"

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

help:
	@echo ""
	@echo "Zig Matching Engine - Build System"
	@echo "==================================="
	@echo ""
	@echo "Build:"
	@echo "  make              Build debug version"
	@echo "  make release      Build optimized version"
	@echo "  make check        Fast type-check"
	@echo "  make clean        Clean build artifacts"
	@echo ""
	@echo "Run (Binary Protocol - Default):"
	@echo "  make run          Single-threaded"
	@echo "  make run-release  Single-threaded (optimized)"
	@echo "  make run-threaded Dual-processor mode"
	@echo "  make run-tcp      TCP only"
	@echo "  make run-udp      UDP only"
	@echo ""
	@echo "Run (CSV Protocol - Testing):"
	@echo "  make run-csv          Single-threaded CSV"
	@echo "  make run-threaded-csv Dual-processor CSV"
	@echo "  make run-tcp-csv      TCP only CSV"
	@echo "  make run-udp-csv      UDP only CSV"
	@echo ""
	@echo "Test:"
	@echo "  make test         Run all unit tests"
	@echo "  make test-protocol Run protocol tests only"
	@echo "  make bench        Run benchmarks"
	@echo ""
	@echo "Integration (start server first with make run-csv):"
	@echo "  make send-udp     Send CSV order via UDP"
	@echo "  make send-tcp     Send CSV order via TCP"
	@echo "  make send-binary  Send binary order via UDP"
	@echo "  make send-orders  Send buy/sell/cancel sequence"
	@echo ""
	@echo "Docker:"
	@echo "  make docker       Build Docker image"
	@echo "  make docker-run   Run container (binary)"
	@echo "  make docker-stop  Stop container"
	@echo ""
	@echo "Ports: TCP=$(TCP_PORT) UDP=$(UDP_PORT) MCAST=$(MCAST_PORT)"
	@echo ""
