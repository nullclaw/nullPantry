# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS build

ARG BUILDARCH
ARG TARGETARCH
ARG VERSION=dev
ARG ZIG_VERSION=0.16.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN set -eux; \
    case "${BUILDARCH}" in \
        amd64) zig_host="x86_64-linux" ;; \
        arm64) zig_host="aarch64-linux" ;; \
        *) echo "unsupported build architecture: ${BUILDARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_host}-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

COPY build.zig build.zig.zon ./
COPY src ./src
COPY vendor ./vendor

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) zig_target="x86_64-linux-musl" ;; \
        arm64) zig_target="aarch64-linux-musl" ;; \
        *) echo "unsupported target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    zig build -Doptimize=ReleaseSmall -Dtarget="${zig_target}" -Dversion="${VERSION}"; \
    cp zig-out/bin/nullpantry /usr/local/bin/nullpantry

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 nullpantry \
    && useradd --system --uid 10001 --gid nullpantry --home-dir /var/lib/nullpantry --create-home --shell /usr/sbin/nologin nullpantry \
    && chmod 700 /var/lib/nullpantry

COPY --from=build /usr/local/bin/nullpantry /usr/local/bin/nullpantry

ENV NULLPANTRY_HOME=/var/lib/nullpantry \
    NULLPANTRY_HOST=0.0.0.0 \
    NULLPANTRY_PORT=8765

EXPOSE 8765
VOLUME ["/var/lib/nullpantry"]

USER 10001:10001
ENTRYPOINT ["/usr/local/bin/nullpantry"]
