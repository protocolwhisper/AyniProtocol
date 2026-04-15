# ────────────────────────────────────────────────────────────────────────────
# Stage 1: Build
# ────────────────────────────────────────────────────────────────────────────
FROM rust:1.82-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy manifest files first so dependency compilation is cached separately
# from source changes.
COPY Cargo.toml Cargo.lock ./

# Build a dummy binary to pre-compile all dependencies
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs
RUN cargo build --release --locked
RUN rm -rf src

# Copy real source and rebuild (only re-links when source changes)
COPY src ./src
RUN touch src/main.rs && cargo build --release --locked

# ────────────────────────────────────────────────────────────────────────────
# Stage 2: Runtime
# ────────────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/target/release/ayni-intents-router /app/ayni-intents-router

# Volume mount point for the block cursor file
RUN mkdir -p /app/data
ENV LAST_BLOCK_FILE=/app/data/last_block.json

EXPOSE 8080

ENTRYPOINT ["/app/ayni-intents-router"]
