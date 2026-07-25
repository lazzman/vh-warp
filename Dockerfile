FROM debian:bookworm-slim AS builder

ARG GITHUB_PROXY=""
ENV DEBIAN_FRONTEND=noninteractive
ENV GOST_VERSION=3.2.6

RUN apt update && apt install -y --no-install-recommends \
    curl wget gnupg2 ca-certificates libc-bin && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
    gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" \
    > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt update && \
    apt install cloudflare-warp -y && \
    mkdir -p /stage && \
    cp /usr/bin/warp-cli /usr/bin/warp-svc /stage/ && \
    cp -a /etc/dbus-1/. /stage/rootfs/etc/dbus-1/ 2>/dev/null || true && \
    for bin in /stage/warp-cli /stage/warp-svc; do \
    ldd "$bin" 2>/dev/null | grep -oP '/[^ ]+' | while read -r lib; do \
    real=$(readlink -f "$lib" 2>/dev/null) && lib="$real"; \
    if [ -f "$lib" ]; then \
    mkdir -p "/stage/rootfs$(dirname "$lib")" && \
    cp -n "$lib" "/stage/rootfs$(dirname "$lib")/" 2>/dev/null || true; \
    fi; done; done

FROM debian:bookworm-slim

ARG GITHUB_PROXY=""
ENV DEBIAN_FRONTEND=noninteractive
ENV GOST_VERSION=3.2.6

RUN     apt update && apt install -y --no-install-recommends \
    curl ca-certificates procps iproute2 iptables dbus bash dnsutils net-tools libcap2-bin nftables libpcap0.8 \
    && apt clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /stage/warp-cli /stage/warp-svc /usr/bin/
COPY --from=builder /stage/rootfs/ /

RUN ldconfig && \
    setcap cap_setuid,cap_setgid,cap_net_raw,cap_dac_read_search,cap_net_admin,cap_net_bind_service,cap_sys_ptrace+ei /usr/bin/warp-svc

RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL -o /tmp/gost.tar.gz \
    "${GITHUB_PROXY}https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" && \
    tar xzf /tmp/gost.tar.gz -C /usr/local/bin gost && \
    chmod +x /usr/local/bin/gost && rm /tmp/gost.tar.gz && \
    mkdir -p /var/log/warp-gost

COPY entrypoint.sh vhwarp.sh gost-setup.sh log-monitor.sh health-check.sh setup-dns.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh \
    /usr/local/bin/vhwarp.sh \
    /usr/local/bin/gost-setup.sh \
    /usr/local/bin/log-monitor.sh \
    /usr/local/bin/health-check.sh \
    /usr/local/bin/setup-dns.sh

RUN which warp-cli && which warp-svc && which gost && \
    echo "=== 构建验证通过 ===" && \
    warp-cli --version

EXPOSE 1111

CMD ["/usr/local/bin/entrypoint.sh"]