FROM debian:bookworm-slim

ARG GITHUB_PROXY=""
ENV DEBIAN_FRONTEND=noninteractive
ENV GOST_VERSION=3.2.6

RUN apt update && apt install -y --no-install-recommends \
    curl \
    wget \
    gnupg2 \
    ca-certificates \
    procps \
    iproute2 \
    iptables \
    dbus \
    bash \
    && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
    gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" \
    > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt update && \
    apt install -y --no-install-recommends cloudflare-warp && \
    apt autoremove -y --purge wget gnupg2 && \
    apt clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    /usr/share/doc/* /usr/share/man/* /usr/share/locale/* \
    /var/cache/apt/* /var/cache/debconf/* \
    /var/log/*.log /var/log/apt/*

RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL -o /tmp/gost.tar.gz \
    "${GITHUB_PROXY}https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" && \
    tar xzf /tmp/gost.tar.gz -C /usr/local/bin gost && \
    chmod +x /usr/local/bin/gost && \
    rm /tmp/gost.tar.gz

RUN mkdir -p /var/log/warp-gost

COPY entrypoint.sh vhwarp.sh gost-setup.sh log-monitor.sh health-check.sh setup-dns.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh \
    /usr/local/bin/vhwarp.sh \
    /usr/local/bin/gost-setup.sh \
    /usr/local/bin/log-monitor.sh \
    /usr/local/bin/health-check.sh \
    /usr/local/bin/setup-dns.sh

EXPOSE 1111

CMD ["/usr/local/bin/entrypoint.sh"]