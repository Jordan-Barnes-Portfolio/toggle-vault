# Build stage
FROM golang:1.21-alpine AS builder

# Install build dependencies for SQLite
RUN apk add --no-cache gcc musl-dev

WORKDIR /app

# Copy go mod files first for better layer caching
COPY go.mod go.sum* ./

# Copy vendor directory if it exists (for airgap builds)
COPY vendor* ./vendor/

# Copy source code
COPY . .

# Download dependencies only if not vendored, then build
# Uses -mod=vendor if vendor exists, otherwise downloads
RUN if [ -d "vendor" ] && [ -n "$(ls -A vendor 2>/dev/null)" ]; then \
        echo "Building with vendored dependencies..." && \
        CGO_ENABLED=1 GOOS=linux go build -mod=vendor -o toggle-vault ./cmd/toggle-vault; \
    else \
        echo "Downloading dependencies..." && \
        go mod tidy && go mod download && \
        CGO_ENABLED=1 GOOS=linux go build -o toggle-vault ./cmd/toggle-vault; \
    fi

# Runtime stage
FROM alpine:3.19

# Install CA certificates for HTTPS and SQLite runtime
RUN apk --no-cache add ca-certificates

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/toggle-vault .

# Copy example config
COPY config.yaml ./config.yaml

# Create data directory for SQLite database
RUN mkdir -p /app/data

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/api/health || exit 1

# Run the application
CMD ["./toggle-vault", "-config", "config.yaml"]
