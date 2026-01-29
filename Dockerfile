# Build stage
FROM golang:1.21-alpine AS builder

# Install build dependencies for SQLite
RUN apk add --no-cache gcc musl-dev

WORKDIR /app

# Copy go mod file first
COPY go.mod ./

# Copy source code
COPY . .

# Download dependencies and build
RUN go mod tidy && go mod download
RUN CGO_ENABLED=1 GOOS=linux go build -o toggle-vault ./cmd/toggle-vault

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
