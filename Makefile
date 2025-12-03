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
#   make run          # Build and run
#   make test         # Run all tests
#   make docker       # Build Docker image
#   make clean        # Clean build artifacts
#
# =============================================================================

.PHONY: all build release run test clean docker docker-run docker-stop help

# Default target
all: build

# -----------------------------------------------------------------------------
# Build Targets
# -----------------------------------------------------------------------------

## Build debug version
build:
	zig build

## Build release version (optimized)
release:
	zig build -Doptimize=ReleaseFast

## Build small release (size optimized)
release-small:
	zig build -Doptimize=ReleaseSmall

## Build with safety checks (for testing)
release-safe:
	zig build -Doptimize=ReleaseSafe

# -----------------------------------------------------------------------------
# Run Targets
# -----------------------------------------------------------------------------

## Build and run server (debug)
run: build
	./zig-out/bin/matching_engine

## Build and run server (release)
run-release: release
	./zig-out/bin/matching_engine

## Run with TCP only
run-tcp:
	ENGINE_UDP_ENABLED=false ENGINE_MCAST_ENABLED=false zig build run

## Run with UDP only  
run-udp:
	ENGINE_TCP_ENABLED=false ENGINE_MCAST_ENABLED=false zig build run

## Run with all transports (default)
run-all:
	zig build run

## Run with custom ports
run-custom:
	ENGINE_TCP_PORT=8000 ENGINE_UDP_PORT=8001 zig build run

# -----------------------------------------------------------------------------
# Test Targets
# -----------------------------------------------------------------------------

## Run all tests
test:
	zig build test

## Run tests with verbose output
test-verbose:
	zig build test -- --verbose

## Run specific test module
test-codec:
	zig test src/protocol/codec.zig

test-binary:
	zig test src/protocol/binary_codec.zig

test-csv:
	zig test src/protocol/csv_codec.zig

test-order:
	zig test src/core/order.zig

test-book:
	zig test src/core/order_book.zig

# -----------------------------------------------------------------------------
# Docker Targets
# -----------------------------------------------------------------------------

DOCKER_IMAGE = zig-matching-engine
DOCKER_TAG = latest
DOCKER_CONTAINER = matching-engine

## Build Docker image
docker:
	docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) .

## Build Docker image (no cache)
docker-clean:
	docker build --no-cache -t $(DOCKER_IMAGE):$(DOCKER_TAG) .

## Run Docker container (all transports)
docker-run: docker
	docker run -d \
		--name $(DOCKER_CONTAINER) \
		-p 9000:9000 \
		-p 9001:9001/udp \
		$(DOCKER_IMAGE):$(DOCKER_TAG)
	@echo "Container started. Logs: docker logs -f $(DOCKER_CONTAINER)"

## Run Docker container with host networking (for multicast)
docker-run-host: docker
	docker run -d \
		--name $(DOCKER_CONTAINER) \
		--network host \
		$(DOCKER_IMAGE):$(DOCKER_TAG)
	@echo "Container started with host networking"

## Run Docker container interactively
docker-run-it: docker
	docker run -it --rm \
		-p 9000:9000 \
		-p 9001:9001/udp \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

## Stop Docker container
docker-stop:
	docker stop $(DOCKER_CONTAINER) || true
	docker rm $(DOCKER_CONTAINER) || true

## View Docker logs
docker-logs:
	docker logs -f $(DOCKER_CONTAINER)

## Shell into running container
docker-shell:
	docker exec -it $(DOCKER_CONTAINER) sh

## Docker compose up
compose-up:
	docker-compose up -d

## Docker compose down
compose-down:
	docker-compose down

## Docker compose logs
compose-logs:
	docker-compose logs -f

# -----------------------------------------------------------------------------
# Clean Targets
# -----------------------------------------------------------------------------

## Clean build artifacts
clean:
	rm -rf zig-out/
	rm -rf .zig-cache/
	rm -rf zig-cache/

## Clean everything including Docker
clean-all: clean docker-stop
	docker rmi $(DOCKER_IMAGE):$(DOCKER_TAG) || true

# -----------------------------------------------------------------------------
# Development Helpers
# -----------------------------------------------------------------------------

## Format source code
fmt:
	zig fmt src/

## Check formatting (CI)
fmt-check:
	zig fmt --check src/

## Generate documentation
docs:
	zig build-docs

## Watch and rebuild on changes (requires entr)
watch:
	find src -name '*.zig' | entr -c make build

## Watch and run tests on changes
watch-test:
	find src -name '*.zig' | entr -c make test

# -----------------------------------------------------------------------------
# Quick Testing
# -----------------------------------------------------------------------------

## Send test order via UDP
test-udp:
	@echo "Sending test order via UDP..."
	echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 9001

## Send test order via TCP (requires Python for framing)
test-tcp:
	@echo "Sending test order via TCP..."
	@python3 -c "\
import socket, struct; \
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); \
s.connect(('localhost', 9000)); \
msg = b'N, 1, IBM, 10000, 100, B, 1\n'; \
s.send(struct.pack('>I', len(msg)) + msg); \
print('Sent:', msg); \
s.close()"

## Send multiple test orders
test-orders:
	@echo "Sending buy order..."
	echo "N, 1, IBM, 10000, 100, B, 1" | nc -u -w1 localhost 9001
	@sleep 0.1
	@echo "Sending sell order (should match)..."
	echo "N, 2, IBM, 10000, 50, S, 1" | nc -u -w1 localhost 9001
	@sleep 0.1
	@echo "Sending cancel..."
	echo "C, 1, 1" | nc -u -w1 localhost 9001

## Flush all orders
test-flush:
	echo "F" | nc -u -w1 localhost 9001

## Binary protocol test
test-binary:
	@python3 -c "\
import socket, struct; \
msg = struct.pack('>BB I 8s I I B I', \
    0x4D, ord('N'), 1, b'IBM\x00\x00\x00\x00\x00', 10000, 100, ord('B'), 1); \
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); \
sock.sendto(msg, ('localhost', 9001)); \
print('Sent binary:', msg.hex())"

# -----------------------------------------------------------------------------
# Benchmarks
# -----------------------------------------------------------------------------

## Run simple throughput test
bench:
	@echo "Sending 1000 orders..."
	@for i in $$(seq 1 1000); do \
		echo "N, 1, IBM, 10000, 1, B, $$i"; \
	done | nc -u -w1 localhost 9001
	@echo "Done"

## Run latency test (requires server running)
bench-latency:
	@echo "Latency test not yet implemented"
	@echo "TODO: Implement round-trip latency measurement"

# -----------------------------------------------------------------------------
# CI/CD
# -----------------------------------------------------------------------------

## CI build and test
ci: fmt-check test build
	@echo "CI checks passed"

## Release build for distribution
dist: clean release
	mkdir -p dist
	cp zig-out/bin/matching_engine dist/
	cp README.md dist/
	cp QUICK_START.md dist/
	tar -czvf dist/matching-engine-$(shell uname -s)-$(shell uname -m).tar.gz -C dist .
	@echo "Distribution package created: dist/matching-engine-*.tar.gz"

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

## Show this help
help:
	@echo "Zig Matching Engine - Available targets:"
	@echo ""
	@echo "Build:"
	@echo "  make build          Build debug version"
	@echo "  make release        Build optimized version"
	@echo "  make clean          Clean build artifacts"
	@echo ""
	@echo "Run:"
	@echo "  make run            Build and run (debug)"
	@echo "  make run-release    Build and run (optimized)"
	@echo "  make run-tcp        Run with TCP only"
	@echo "  make run-udp        Run with UDP only"
	@echo ""
	@echo "Test:"
	@echo "  make test           Run all tests"
	@echo "  make test-orders    Send test orders to running server"
	@echo "  make test-udp       Send single UDP test order"
	@echo "  make test-binary    Send binary protocol test"
	@echo ""
	@echo "Docker:"
	@echo "  make docker         Build Docker image"
	@echo "  make docker-run     Run Docker container"
	@echo "  make docker-stop    Stop Docker container"
	@echo "  make docker-logs    View Docker logs"
	@echo ""
	@echo "Development:"
	@echo "  make fmt            Format source code"
	@echo "  make watch          Watch and rebuild on changes"
	@echo "  make watch-test     Watch and test on changes"
	@echo ""
	@echo "For all targets, run: make help"
