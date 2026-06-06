# Multi-stage build for the HouseCall backend.
#
# Stage 1 (builder): compile a static binary using the official Go image.
# Stage 2 (runtime): copy the binary into a minimal Alpine image; no Go
#   toolchain, no source code, minimal attack surface.
#
# The migrations directory is baked into the image so `server -cmd migrate`
# works inside the container without a volume mount.

# ── Stage 1: build ──────────────────────────────────────────────────────────
FROM golang:1.25-alpine AS builder

WORKDIR /src

# Download dependencies first — this layer is cached unless go.mod/go.sum change.
COPY go.mod go.sum ./
RUN go mod download

# Copy source and build a static binary.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /housecall ./cmd/server

# ── Stage 2: runtime ────────────────────────────────────────────────────────
FROM alpine:3.21

# ca-certificates lets the agent client make TLS calls (e.g. to hosted model APIs).
# curl is used by the e2e test driver (exec mode) to make HTTP calls from inside
# the container; BusyBox wget cannot reliably capture Set-Cookie headers or
# suppress redirect-following on a 303.
RUN apk add --no-cache ca-certificates curl

WORKDIR /app

COPY --from=builder /housecall ./housecall
COPY --from=builder /src/migrations ./migrations

EXPOSE 8080

# Default: run the HTTP server.
# Override CMD to run migrations: ["./housecall", "-cmd", "migrate"]
CMD ["./housecall", "-cmd", "serve"]
