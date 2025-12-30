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
FROM alpine:3.21 AS builder

# Build arguments for architecture detection
ARG TARGETARCH
# Zig version: Use 0.14.0 (March 2025 stable) or 0.13.0 (older stable)
# Check your build.zig API compatibility before changing
ARG ZIG_VERSION=0.14.0

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
# ReleaseFast for maximum performance, strip for smaller binary
RUN zig build -Doptimize=ReleaseFast \
    && strip /build/zig-out/bin/matching_engine || true

# Verify binary
RUN ls -la ./zig-out/bin/ && \
    ./zig-out/bin/matching_engine --version && \
    file ./zig-out/bin/matching_engine

# -----------------------------------------------------------------------------
# Stage 2: Runtime (Minimal)
# -----------------------------------------------------------------------------
FROM alpine:3.21 AS runtime

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
    /build/zig-out/bin/matching_engine /usr/local/bin/matching_engine

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
