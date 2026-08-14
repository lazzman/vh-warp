FROM debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV GOST_VERSION=3.2.6

RUN apt update && apt install -y --no-install-recommends curl ca-certificates && \
    curl -fsSLo /tmp/warp.deb \
    "https://pkg.cloudflareclient.com/pool/bookworm/main/c/cloudflare-warp/cloudflare-warp_2026.6.880.0_$(dpkg --print-architecture).deb" && \
    dpkg-deb -x /tmp/warp.deb /tmp/warp && \
    mkdir -p /stage/rootfs/etc/dbus-1 && \
    cp /tmp/warp/bin/warp-cli /tmp/warp/bin/warp-svc /tmp/warp/bin/warp-diag /stage/ && \
    cp -a /tmp/warp/etc/dbus-1/. /stage/rootfs/etc/dbus-1/ 2>/dev/null || true && \
    rm -rf /tmp/warp.deb /tmp/warp

FROM debian:bookworm-slim

ARG GITHUB_PROXY=""
ENV DEBIAN_FRONTEND=noninteractive
ENV GOST_VERSION=3.2.6

RUN apt update && apt install -y --no-install-recommends \
    curl ca-certificates procps iproute2 iptables nftables dbus tzdata \
    util-linux iputils-ping \
    libcap2-bin libnss3-tools libpcap0.8 \
    libtss2-esys-3.0.2-0 libtss2-tctildr0 \
    python3 \
    && apt clean && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone

COPY --from=builder /stage/warp-cli /stage/warp-svc /stage/warp-diag /usr/bin/
COPY --from=builder /stage/rootfs/ /

ENV HEV_VERSION=2.17.0

RUN ldconfig && \
    setcap cap_setuid,cap_setgid,cap_net_raw,cap_dac_read_search,cap_net_admin,cap_net_bind_service,cap_sys_ptrace+ei /usr/bin/warp-svc && \
    ARCH=$(dpkg --print-architecture) && \
    curl -fsSL -o /tmp/gost.tar.gz \
    "${GITHUB_PROXY}https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" && \
    tar xzf /tmp/gost.tar.gz -C /usr/local/bin gost && \
    chmod +x /usr/local/bin/gost && rm /tmp/gost.tar.gz && \
    case "$ARCH" in amd64) HEV_ARCH=x86_64 ;; arm64) HEV_ARCH=arm64 ;; *) HEV_ARCH=x86_64 ;; esac && \
    curl -fsSL -o /usr/local/bin/hev-socks5-tunnel \
      "${GITHUB_PROXY}https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_VERSION}/hev-socks5-tunnel-linux-${HEV_ARCH}" && \
    chmod +x /usr/local/bin/hev-socks5-tunnel && \
    mkdir -p /var/log/warp-gost /var/lib/cloudflare-warp/.runtime

COPY entrypoint.sh vhwarp.sh gost-setup.sh log-monitor.sh health-check.sh \
     warp-common.sh instance-ctl.sh lb-setup.sh lb-proxy.py upstream-setup.sh \
     rotate-restart.sh \
     /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh \
    /usr/local/bin/vhwarp.sh \
    /usr/local/bin/gost-setup.sh \
    /usr/local/bin/log-monitor.sh \
    /usr/local/bin/health-check.sh \
    /usr/local/bin/warp-common.sh \
    /usr/local/bin/instance-ctl.sh \
    /usr/local/bin/lb-setup.sh \
    /usr/local/bin/lb-proxy.py \
    /usr/local/bin/upstream-setup.sh \
    /usr/local/bin/rotate-restart.sh && \
    which warp-cli && which warp-svc && which warp-diag && which gost && which python3 && \
    which hev-socks5-tunnel && \
    echo "=== 构建验证通过 ===" && \
    warp-cli --version

# LB 默认 1110；实例端口默认自 1111 起，预留至 1142（最多 32 实例）
EXPOSE 1110 1111-1142

ENV TZ=Asia/Shanghai \
    INSTANCE_COUNT=1 \
    BASE_PORT=1111 \
    LB_PORT=1110 \
    LB_STRATEGY=round \
    LB_ROTATE_INTERVAL=5m \
    LB_ENABLED=auto \
    STATUS_EVENT_LOG=1 \
    UPSTREAM_SOCKS5= \
    UPSTREAM_SOCKS5_UDP=udp \
    UPSTREAM_MTU=1280

# 健康检查：优先探测 LB；单实例时 LB 可能未启用，回退到 BASE_PORT
HEALTHCHECK --interval=30s --timeout=12s --start-period=90s --retries=3 \
    CMD bash -c 'P="${LB_PORT:-1110}"; B="${BASE_PORT:-1111}"; \
      curl -fsS --max-time 8 --socks5-hostname 127.0.0.1:$P https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -qE "^warp=(on|plus)$" \
      || curl -fsS --max-time 8 --socks5-hostname 127.0.0.1:$B https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -qE "^warp=(on|plus)$"'

CMD ["/usr/local/bin/entrypoint.sh"]
