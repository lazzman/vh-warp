#!/bin/bash

LOG_FILE="/var/log/warp-gost/gost.log"
mkdir -p /var/log/warp-gost

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

configure_nat() {
    local warp_if
    warp_if=$(ip link show 2>/dev/null | grep -oE "CloudflareWARP|wgcf" | head -1)
    if [ -z "$warp_if" ]; then
        warp_if=$(ip link show 2>/dev/null | awk -F: '/warp|WARP/{print $2}' | tr -d ' ' | head -1)
    fi
    if [ -z "$warp_if" ]; then
        return 1
    fi

    log "检测到 WARP 网卡: $warp_if，配置 NAT 规则..."
    iptables -t nat -C POSTROUTING -o "$warp_if" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$warp_if" -j MASQUERADE
    iptables -C FORWARD -o "$warp_if" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -o "$warp_if" -j ACCEPT
    iptables -C FORWARD -i "$warp_if" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$warp_if" -m state --state RELATED,ESTABLISHED -j ACCEPT
    return 0
}

start_gost() {
    log "启动 GOST 代理 (mixed SOCKS5+HTTP 监听 0.0.0.0:1111)..."

    pkill -x gost 2>/dev/null || true
    sleep 1

    gost -L "mixed://0.0.0.0:1111" >> "$LOG_FILE" 2>&1 &

    local i=0
    while [ $i -lt 10 ]; do
        sleep 1
        if pgrep -x "gost" > /dev/null; then
            log "GOST 启动成功，端口: 1111"
            configure_nat || true
            return 0
        fi
        i=$((i + 1))
    done

    log "GOST 启动失败"
}

stop_gost() {
    log "停止 GOST..."
    pkill -x gost 2>/dev/null || true
    sleep 1
    log "GOST 已停止"
}

case "$1" in
    start)
        start_gost
        ;;
    stop)
        stop_gost
        ;;
    restart)
        stop_gost
        sleep 1
        start_gost
        ;;
    status)
        if pgrep -x "gost" > /dev/null; then
            echo "GOST 运行中（端口 1111）"
        else
            echo "GOST 未运行"
        fi
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac