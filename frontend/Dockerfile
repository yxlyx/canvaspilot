# syntax=docker/dockerfile:1.6
#
# WikiBase frontend (merjs / Zig 0.16) — Milestone 1 deploy image.
#
# Multi-stage build:
#   1. `build` installs Zig 0.16, vendors merjs from zig-pkg/, runs codegen and
#      compiles the `app` binary in ReleaseSafe mode.
#   2. The runtime image is a slim Debian with the binary + public/ assets.
#
# Targets Railway by default (PORT env, binds 0.0.0.0). Works on any container
# host: Fly.io, Render, Cloud Run, plain Docker, etc. See DEPLOY.md.

# ── build stage ─────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS build

ARG ZIG_VERSION=0.16.0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.16 from the official tarball. URL format:
#   https://ziglang.org/download/<version>/zig-<arch>-linux-<version>.tar.xz
RUN set -eux; \
    ARCH="$(uname -m)"; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH

WORKDIR /src
COPY . .

ENV ZIG_GLOBAL_CACHE_DIR=/tmp/.zig-cache-global

RUN zig build -Doptimize=ReleaseSafe

# ── runtime stage ───────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 wikibase

WORKDIR /app
COPY --from=build /src/zig-out/bin/app /app/app
COPY --from=build /src/public /app/public

USER wikibase

# Railway injects $PORT; locally falls back to 3001.
ENV PORT=3001
EXPOSE 3001

# Bind 0.0.0.0 so the container is reachable from outside the network namespace.
CMD ["sh", "-c", "/app/app --host 0.0.0.0 --port ${PORT:-3001} --no-dev"]
