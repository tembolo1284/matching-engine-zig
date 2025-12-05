# =============================================================================
# Zig Matching Engine - Multi-stage Docker Build
# =============================================================================
#
# Build: docker build -t zig-matching-engine .
# Run:   docker run -p 9000:9000 -p 9001:9001/udp zig-matching-engine
#
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Builder
# -----------------------------------------------------------------------------
FROM alpine:3.20 AS builder

# Install build dependencies
RUN apk add --no-cache \
    curl \
    xz \
    tar

# Install Zig 0.13.0 (or latest stable)
ARG ZIG_VERSION=0.13.0
RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
    | tar -xJ \
    && mv "zig-linux-x86_64-${ZIG_VERSION}" /opt/zig

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

# Build release binary
RUN zig build -Doptimize=ReleaseFast

# Verify binary exists and works
RUN ls -la ./zig-out/bin/ \
    && ./zig-out/bin/matching_engine --version

# -----------------------------------------------------------------------------
# Stage 2: Runtime
# -----------------------------------------------------------------------------
FROM alpine:3.20 AS runtime

# Install minimal runtime dependencies
# Note: Static Zig binaries typically don't need these, but included for safety
RUN apk add --no-cache \
    libgcc

# Create non-root user for security
RUN addgroup -g 1000 -S engine \
    && adduser -u 1000 -S -G engine -h /app engine

# Copy binary from builder
COPY --from=builder /build/zig-out/bin/matching_engine /usr/local/bin/matching_engine

# Ensure binary is executable
RUN chmod +x /usr/local/bin/matching_engine

# Create data directory (if needed for future use)
RUN mkdir -p /app/data && chown engine:engine /app/data

# Switch to non-root user
USER engine
WORKDIR /app

# Default ports (matching config.zig defaults)
# TCP:       1234
# UDP:       1235
# Multicast: 1236
EXPOSE 1234/tcp
EXPOSE 1235/udp
EXPOSE 1236/udp

# Environment variables (defaults matching config.zig)
ENV ENGINE_TCP_ENABLED=true \
    ENGINE_TCP_PORT=1234 \
    ENGINE_UDP_ENABLED=true \
    ENGINE_UDP_PORT=1235 \
    ENGINE_MCAST_ENABLED=true \
    ENGINE_MCAST_GROUP=239.255.0.1 \
    ENGINE_MCAST_PORT=1236 \
    ENGINE_THREADED=false

# Labels
LABEL org.opencontainers.image.title="Zig Matching Engine" \
      org.opencontainers.image.description="High-performance order matching engine" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.source="https://github.com/youruser/matching-engine-zig"

# Health check - verify TCP port is listening
# Uses timeout + shell to check if port is open
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD timeout 1 sh -c 'echo > /dev/tcp/localhost/1234' 2>/dev/null || exit 1

# Run the matching engine
ENTRYPOINT ["/usr/local/bin/matching_engine"]
