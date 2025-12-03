# =============================================================================
# Zig Matching Engine - Multi-stage Docker Build
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Build
# -----------------------------------------------------------------------------
FROM alpine:3.19 AS builder

# Install Zig
RUN apk add --no-cache \
    curl \
    xz \
    && curl -L https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz | tar -xJ \
    && mv zig-linux-x86_64-0.11.0 /opt/zig

ENV PATH="/opt/zig:${PATH}"

# Set working directory
WORKDIR /build

# Copy source
COPY build.zig .
COPY src/ src/

# Build release binary
RUN zig build -Doptimize=ReleaseFast

# Verify binary
RUN ./zig-out/bin/matching_engine --help || true
RUN ls -la ./zig-out/bin/

# -----------------------------------------------------------------------------
# Stage 2: Runtime
# -----------------------------------------------------------------------------
FROM alpine:3.19 AS runtime

# Install runtime dependencies (minimal)
RUN apk add --no-cache \
    libgcc \
    libstdc++

# Create non-root user
RUN addgroup -S engine && adduser -S engine -G engine

# Copy binary from builder
COPY --from=builder /build/zig-out/bin/matching_engine /usr/local/bin/

# Set ownership
RUN chown engine:engine /usr/local/bin/matching_engine

# Switch to non-root user
USER engine

# Expose ports
EXPOSE 1234/tcp
EXPOSE 1235/udp
EXPOSE 1236/udp

# Environment variables (defaults)
ENV ENGINE_TCP_ENABLED=true \
    ENGINE_TCP_PORT=1234 \
    ENGINE_UDP_ENABLED=true \
    ENGINE_UDP_PORT=1235 \
    ENGINE_MCAST_ENABLED=true \
    ENGINE_MCAST_GROUP=239.255.0.1 \
    ENGINE_MCAST_PORT=1236

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD nc -z localhost 1234 || exit 1

# Run
ENTRYPOINT ["/usr/local/bin/matching_engine"]
