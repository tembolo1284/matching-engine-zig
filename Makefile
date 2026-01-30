# =============================================================================
# Zig Matching Engine - Makefile
# =============================================================================
.PHONY: all build release run test clean help
.DEFAULT_GOAL := all

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TCP_PORT ?= 1234
FIX_PORT ?= 1237
DOCKER_IMAGE := zig-matching-engine
DOCKER_TAG := latest
DOCKER_CONTAINER := matching-engine
BUILD_DIR := zig-out
BIN := $(BUILD_DIR)/bin/matching_engine
BENCH_BIN := $(BUILD_DIR)/bin/benchmark
ZIG_FLAGS := -freference-trace

# -----------------------------------------------------------------------------
# Build Targets
# -----------------------------------------------------------------------------
all: build

build:
	zig build $(ZIG_FLAGS)

release:
	zig build -Doptimize=ReleaseFast $(ZIG_FLAGS)

release-safe:
	zig build -Doptimize=ReleaseSafe $(ZIG_FLAGS)

release-small:
	zig build -Doptimize=ReleaseSmall $(ZIG_FLAGS)

check:
	zig build check $(ZIG_FLAGS)

# -----------------------------------------------------------------------------
# Run Targets (all use threaded mode by default)
# -----------------------------------------------------------------------------
run: build
	@exec $(BIN) --threaded --port=$(TCP_PORT)

run-release: release
	@exec $(BIN) --threaded --port=$(TCP_PORT)

run-verbose: build
	@exec $(BIN) --threaded --verbose --port=$(TCP_PORT)

run-verbose-release: release
	@exec $(BIN) --threaded --verbose --port=$(TCP_PORT)

run-help: build
	$(BIN) --help

run-version: build
	$(BIN) --version

# -----------------------------------------------------------------------------
# Test Targets
# -----------------------------------------------------------------------------
test:
	zig build test $(ZIG_FLAGS)

test-summary:
	zig build test $(ZIG_FLAGS) 2>&1 | tail -30

test-file:
	@test -n "$(FILE)" || (echo "Usage: make test-file FILE=src/path/to/file.zig" && exit 1)
	zig test $(FILE) $(ZIG_FLAGS)

test-protocol:
	zig test src/protocol/message_types.zig $(ZIG_FLAGS)
	zig test src/protocol/binary_codec.zig $(ZIG_FLAGS)
	zig test src/protocol/fix_codec.zig $(ZIG_FLAGS)

test-core:
	zig test src/core/order.zig $(ZIG_FLAGS)
	zig test src/core/output_buffer.zig $(ZIG_FLAGS)
	zig test src/core/order_book.zig $(ZIG_FLAGS)
	zig test src/core/matching_engine.zig $(ZIG_FLAGS)

test-threading:
	zig test src/threading/spsc_queue.zig $(ZIG_FLAGS)
	zig test src/threading/processor.zig $(ZIG_FLAGS)

test-transport:
	zig test src/transport/framing.zig $(ZIG_FLAGS)
	zig test src/transport/tcp_connection.zig $(ZIG_FLAGS)
	zig test src/transport/tcp_server.zig $(ZIG_FLAGS)

# -----------------------------------------------------------------------------
# Benchmarks
# -----------------------------------------------------------------------------
bench: release
	zig build bench -Doptimize=ReleaseFast
	$(BENCH_BIN)

bench-debug: build
	zig build bench
	$(BENCH_BIN)

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
		-e ENGINE_THREADED=true \
		$(DOCKER_IMAGE):$(DOCKER_TAG)
	@echo "Container started: $(DOCKER_CONTAINER)"

docker-run-it: docker
	docker run -it --rm \
		-p $(TCP_PORT):$(TCP_PORT) \
		-e ENGINE_THREADED=true \
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
	@command -v entr >/dev/null 2>&1 || (echo "Install entr: pacman -S entr" && exit 1)
	find src -name '*.zig' | entr -c make build

watch-test:
	@command -v entr >/dev/null 2>&1 || (echo "Install entr: pacman -S entr" && exit 1)
	find src -name '*.zig' | entr -c make test

loc:
	@echo "Lines of Zig code:"
	@find src -name '*.zig' | xargs wc -l | tail -1

loc-detail:
	@echo "Lines of Zig code by module:"
	@echo "  Protocol:" && find src/protocol -name '*.zig' | xargs wc -l | tail -1
	@echo "  Core:" && find src/core -name '*.zig' | xargs wc -l | tail -1
	@echo "  Threading:" && find src/threading -name '*.zig' | xargs wc -l | tail -1
	@echo "  Transport:" && find src/transport -name '*.zig' | xargs wc -l | tail -1
	@echo "  Total:" && find src -name '*.zig' | xargs wc -l | tail -1

todos:
	@grep -rn "TODO\|FIXME\|XXX\|HACK" src/ --include="*.zig" || echo "No TODOs found!"

sizes: build
	@$(BIN) 2>&1 | head -10

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
	@echo "  make release-safe Build with safety checks"
	@echo "  make check        Fast type-check"
	@echo "  make clean        Clean build artifacts"
	@echo ""
	@echo "Run:"
	@echo "  make run              Run server (threaded, port $(TCP_PORT))"
	@echo "  make run-release      Run optimized server"
	@echo "  make run-verbose      With verbose logging"
	@echo ""
	@echo "Test:"
	@echo "  make test             Run all unit tests"
	@echo "  make test-protocol    Test protocol modules"
	@echo "  make test-core        Test core modules"
	@echo "  make test-threading   Test threading modules"
	@echo "  make test-transport   Test transport modules"
	@echo "  make bench            Run benchmarks (release)"
	@echo ""
	@echo "Docker:"
	@echo "  make docker           Build Docker image"
	@echo "  make docker-run       Run container"
	@echo "  make docker-stop      Stop container"
	@echo ""
	@echo "Development:"
	@echo "  make fmt              Format source code"
	@echo "  make fmt-check        Check formatting"
	@echo "  make watch            Auto-rebuild on change"
	@echo "  make watch-test       Auto-test on change"
	@echo "  make loc              Count lines of code"
	@echo "  make sizes            Show struct sizes"
	@echo ""
	@echo "Configuration:"
	@echo "  TCP_PORT=$(TCP_PORT)  (override with TCP_PORT=xxxx make run)"
	@echo ""
