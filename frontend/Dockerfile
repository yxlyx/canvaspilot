# syntax=docker/dockerfile:1.6
#
# WikiBase frontend (merjs / Zig 0.16) — Milestone 1 deploy image.
#
# Multi-stage build:
#   1. `build` installs Zig 0.16, vendors merjs from zig-pkg/, runs codegen and
#      compiles the `app` binary in ReleaseSafe mode.
#   2. The runtime image is a package-free scratch image with the static-musl
#      binary, CA trust bundle, and public/ assets.
#
# Targets Railway by default (PORT env, binds 0.0.0.0). Works on any container
# host: Fly.io, Render, Cloud Run, plain Docker, etc. See DEPLOY.md.

# ── build stage ─────────────────────────────────────────────────────────────
FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818 AS build

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
    case "$ARCH" in \
        x86_64) ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
        aarch64) ZIG_SHA256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
        *) printf 'unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    echo "$ZIG_SHA256  /tmp/zig.tar.xz" | sha256sum --check --strict; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH

WORKDIR /src
COPY . .

ENV ZIG_GLOBAL_CACHE_DIR=/tmp/.zig-cache-global

RUN set -eux; \
    case "$(uname -m)" in \
        x86_64) TARGET=x86_64-linux-musl ;; \
        aarch64) TARGET=aarch64-linux-musl ;; \
        *) printf 'unsupported architecture\n' >&2; exit 1 ;; \
    esac; \
    zig build -Doptimize=ReleaseSafe -Dtarget="$TARGET"

# ── runtime stage ───────────────────────────────────────────────────────────
FROM scratch

COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build --chown=10001:10001 /src/zig-out/bin/app /app/app
COPY --from=build --chown=10001:10001 /src/public /app/public

WORKDIR /app
USER 10001:10001

# Railway injects $PORT; the application falls back to 3001.
ENV PORT=3001
EXPOSE 3001

# Bind 0.0.0.0 so the container is reachable from outside the network namespace.
CMD ["/app/app", "--host", "0.0.0.0", "--no-dev"]
