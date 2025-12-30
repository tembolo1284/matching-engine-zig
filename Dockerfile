# =============================================================================
# Zig Matching Engine - Production Multi-Architecture Docker Build
# =============================================================================
#
# Supports: linux/amd64 (x86_64), linux/arm64 (Graviton, Apple Silicon)
#
# Build:
#   docker build -t zig-matching-engine .
#   docker build --platform linux/arm64 -t zig-matching-engine:arm64 .
#
# Run:
#   docker run -p 1234:1234 -p 1235:1235/udp zig-matching-engine
#
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Builder
# -----------------------------------------------------------------------------
FROM alpine:3.20 AS builder

# Build arguments for architecture detection
ARG TARGETARCH
# Zig version: Your code uses 0.15+ syntax (tuple constraints in inline asm)
# Use 0.15.0 or later
ARG ZIG_VERSION=0.15.0

# Install build dependencies
RUN apk add --no-cache \
    curl \
    xz \
    tar \
    musl-dev

# Download and install Zig based on target architecture
RUN case "${TARGETARCH}" in \
        "amd64") ZIG_ARCH="x86_64" ;; \
        "arm64") ZIG_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    echo "Installing Zig ${ZIG_VERSION} for ${ZIG_ARCH}" && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" \
    | tar -xJ && \
    mv "zig-linux-${ZIG_ARCH}-${ZIG_VERSION}" /opt/zig

ENV PATH="/opt/zig:${PATH}"

# Verify Zig installation
RUN zig version

# Set working directory
WORKDIR /build

# Copy build files first (for layer caching)
COPY build.zig ./
COPY build.zig.zon ./

# Copy source
COPY src/ src/

# Build optimized release binary
# ReleaseFast for maximum performance
RUN zig build -Doptimize=ReleaseFast --summary all

# Find and verify binary (handles different Zig versions' output paths)
# Zig 0.13 uses ./zig-out/bin/, Zig 0.14+ may use .zig-cache/... or custom paths
RUN echo "=== Finding binary ===" && \
    find . -name "matching_engine" -type f 2>/dev/null && \
    BINARY=$(find . -name "matching_engine" -type f -executable 2>/dev/null | head -1) && \
    if [ -z "$BINARY" ]; then \
        echo "ERROR: Binary not found!" && \
        ls -la . && \
        ls -la zig-out 2>/dev/null || true && \
        ls -la .zig-cache 2>/dev/null || true && \
        exit 1; \
    fi && \
    echo "Found binary: $BINARY" && \
    $BINARY --version && \
    strip $BINARY || true && \
    mkdir -p /build/out && \
    cp $BINARY /build/out/matching_engine && \
    file /build/out/matching_engine

# -----------------------------------------------------------------------------
# Stage 2: Runtime (Minimal)
# -----------------------------------------------------------------------------
FROM alpine:3.20 AS runtime

# Install minimal runtime dependencies
RUN apk add --no-cache \
    libgcc \
    tini \
    && rm -rf /var/cache/apk/*

# Create non-root user for security
RUN addgroup -g 10000 -S engine \
    && adduser -u 10000 -S -G engine -H -s /sbin/nologin engine

# Copy binary from builder
COPY --from=builder --chown=engine:engine \
    /build/out/matching_engine /usr/local/bin/matching_engine

# Ensure binary is executable
RUN chmod 755 /usr/local/bin/matching_engine

# Switch to non-root user
USER engine

# Working directory (optional, binary doesn't need state)
WORKDIR /

# Default ports
# TCP:       1234 (length-prefixed framing)
# UDP:       1235 (raw messages)
# Multicast: 1236 (market data feed)
EXPOSE 1234/tcp
EXPOSE 1235/udp
EXPOSE 1236/udp

# Environment variables with secure defaults
ENV ENGINE_TCP_ENABLED=true \
    ENGINE_TCP_PORT=1234 \
    ENGINE_UDP_ENABLED=true \
    ENGINE_UDP_PORT=1235 \
    ENGINE_MCAST_ENABLED=false \
    ENGINE_MCAST_GROUP=239.255.0.1 \
    ENGINE_MCAST_PORT=1236 \
    ENGINE_THREADED=true

# OCI Labels
LABEL org.opencontainers.image.title="Zig Matching Engine" \
      org.opencontainers.image.description="High-performance order matching engine with dual-processor architecture" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.vendor="Your Company" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/youruser/matching-engine-zig" \
      org.opencontainers.image.documentation="https://github.com/youruser/matching-engine-zig/blob/main/docs/DOCKER.md"

# Health check using nc (available in busybox/alpine)
# Checks if TCP port is accepting connections
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD nc -z localhost 1234 || exit 1

# Use tini as init process for proper signal handling
# This ensures SIGTERM is forwarded correctly for graceful shutdown
ENTRYPOINT ["/sbin/tini", "--"]

# Run the matching engine in threaded mode by default
CMD ["/usr/local/bin/matching_engine", "--threaded"]
