# ---- Build stage ----
FROM rust:latest AS builder

# Set workdir inside the container
WORKDIR /app

# Copy your manifest files
COPY Cargo.toml Cargo.lock ./

# Create dummy main.rs to prefetch dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release

# Now copy actual source
COPY src ./src

# Rebuild with real source
RUN cargo build --release

# ---- Runtime stage ----
FROM debian:bookworm-slim

# Install required system libraries (for JPEG, PNG, etc.)
RUN apt-get update && apt-get install -y \
    libjpeg62-turbo \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy compiled binary from build stage
COPY --from=builder /app/target/release/image-resize-native /usr/local/bin/image-resize

# Set working directory for output
WORKDIR /data

# Run your app (can be overridden via `docker run`)
ENTRYPOINT ["/usr/local/bin/image-resize"]
