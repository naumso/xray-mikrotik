# syntax=docker/dockerfile:1
ARG ALPINE_VERSION=3.24
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS builder

# 1. Define the versions
#https://github.com/XTLS/Xray-core
ARG XRAY_VERSION=26.7.28

#https://github.com/xjasonlyu/tun2socks
ARG TUN2SOCKS_VERSION=2.6.0
# 2. These are automatically populated by Docker Buildx
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /tmp
RUN apk add --no-cache wget unzip

# 3. Use a single RUN with logic to map names
RUN set -ex; \
    # --- Map Tun2Socks Arch names ---
    if [ "$TARGETARCH" = "amd64" ]; then TUN_ARCH="linux-amd64"; \
    elif [ "$TARGETARCH" = "arm64" ]; then TUN_ARCH="linux-arm64"; \
    elif [ "$TARGETARCH" = "arm" ];   then TUN_ARCH="linux-armv7"; \
    fi; \
    # --- Map Xray Arch names ---
    if [ "$TARGETARCH" = "amd64" ]; then XRAY_ARCH="linux-64"; \
    elif [ "$TARGETARCH" = "arm64" ]; then XRAY_ARCH="linux-arm64-v8a"; \
    elif [ "$TARGETARCH" = "arm" ];   then XRAY_ARCH="linux-arm32-v7a"; \
    fi; \
    \
    # Download and Extract Tun2Socks
    wget -q https://github.com/xjasonlyu/tun2socks/releases/download/v${TUN2SOCKS_VERSION}/tun2socks-${TUN_ARCH}.zip; \
    unzip -q tun2socks-${TUN_ARCH}.zip -d t2s_dir; \
    mv t2s_dir/tun2socks-${TUN_ARCH} /tmp/tun2socks; \
    \
    # Download and Extract Xray
    wget -q https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-${XRAY_ARCH}.zip; \
    unzip -q Xray-${XRAY_ARCH}.zip -d xray_dir; \
    mv xray_dir/xray /tmp/xray

# --- Final Stage ---
FROM alpine:${ALPINE_VERSION}

RUN apk update

RUN apk add --no-cache openrc openresolv iproute2 bind-tools jq curl ca-certificates

COPY ./scripts /opt
COPY --from=builder /tmp/tun2socks /opt/tun2socks
COPY --from=builder /tmp/xray /opt/xray

RUN mkdir -p /var/run/openrc && \
    chmod +x /opt/tun2socks /opt/xray /opt/*.sh && \
    sed -i 's/^tty/#tty/' /etc/inittab && \
    touch /run/openrc/softlevel

WORKDIR /opt

# Fix: Use ENV to update PATH
ENV PATH="/opt:${PATH}"

ENTRYPOINT ["sh", "-c"]
CMD ["/bin/sh /opt/start.sh"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD /opt/healthcheck.sh