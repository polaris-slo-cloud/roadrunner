# ---- Build stage ----
FROM rust:1.81.0-slim-bookworm AS builder

# Install the WASI target
RUN rustup target add wasm32-wasi

# Set working directory
WORKDIR /build

# Copy only the Cargo files first for layer caching
COPY Cargo.toml Cargo.lock ./

# Dummy main to prefetch dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --target wasm32-wasi --release || true

# Replace with actual source
COPY src ./src

# Build the real Wasm binary
RUN cargo build --target wasm32-wasi --release

# ---- Runtime stage ----
FROM scratch

# Copy the compiled Wasm binary
COPY --from=builder /build/target/wasm32-wasi/release/image-resize-wasm.wasm /

# Set Wasm binary as the entrypoint
ENTRYPOINT ["/image-resize-wasm.wasm"]
