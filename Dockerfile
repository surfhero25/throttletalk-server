# Build stage — compiles Swift server natively on Linux
FROM swift:5.10-jammy AS builder

WORKDIR /app
COPY Package.swift ./
COPY Sources/ Sources/
COPY Tests/ Tests/

RUN swift build -c release --static-swift-stdlib

# Runtime stage — minimal image with just the binary
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/.build/release/ThrottleTalkServer .

EXPOSE 9000/udp

ENTRYPOINT ["./ThrottleTalkServer"]
CMD ["--host", "0.0.0.0", "--port", "9000"]
