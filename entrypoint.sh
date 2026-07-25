#!/bin/bash

LOG_DIR="/var/log/warp-gost"
LOG_FILE="$LOG_DIR/entrypoint.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "vh-warp 容器启动中..."
log "正在优化 DNS..."
/usr/local/bin/setup-dns.sh >> "$LOG_FILE" 2>&1

ln -sf /usr/local/bin/vhwarp.sh /usr/bin/vhwarp 2>/dev/null
ln -sf /usr/local/bin/gost-setup.sh /usr/bin/gost-setup 2>/dev/null
ln -sf /usr/local/bin/log-monitor.sh /usr/bin/log-monitor 2>/dev/null
ln -sf /usr/local/bin/health-check.sh /usr/bin/health-check 2>/dev/null

if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun
    log "已创建 TUN 设备 /dev/net/tun"
fi

if ! pgrep -x "dbus-daemon" > /dev/null 2>&1; then
    dbus-daemon --system --fork 2>/dev/null || \
    service dbus start 2>/dev/null || \
    mkdir -p /var/run/dbus && dbus-daemon --system --fork 2>/dev/null || \
    true
    sleep 2
    log "dbus 已启动"
fi

log "正在启动 warp-svc..."
warp-svc >> "$LOG_DIR/warp-svc.log" 2>&1 &
WARP_PID=$!

attempt=1
while true; do
    sleep 10
    if kill -0 $WARP_PID 2>/dev/null; then
        log "warp-svc 启动成功 (PID: $WARP_PID, 第 ${attempt} 次尝试)"
        break
    fi
    log "warp-svc 未就绪，第 ${attempt} 次尝试，10 秒后重试..."
    attempt=$((attempt + 1))
    warp-svc >> "$LOG_DIR/warp-svc.log" 2>&1 &
    WARP_PID=$!
done

log "等待 warp-cli 就绪..."
until warp-cli --accept-tos status > /dev/null 2>&1; do
    sleep 1
done
log "warp-cli 已就绪"

log "正在启动日志监控..."
/usr/local/bin/log-monitor.sh > /dev/null 2>&1 &

log "正在启动健康检测..."
/usr/local/bin/health-check.sh > /dev/null 2>&1 &

echo ""
echo "========================================"
echo "  🥝 vh-warp Cloudflare WARP 隐私保护 + 网络加速"
echo ""
echo "  📝 下一步："
echo "  1) docker exec -it vh-warp bash"
echo "  2) vhwarp"
echo ""
echo "  🔧 配置选项："
echo "  1) WARP 免费版 (MASQUE)"
echo "  2) Teams / Zero Trust"
echo "  3) WARP+ (License Key)"
echo ""
echo "  🌐 SOCKS5/HTTP: 主机IP:1111"
echo "  ⚠️  首次配置可能需等待 3 分钟，请耐心等待"
echo "========================================"
echo ""

log "日志监控已启动"
log "健康检测已启动"

wait $WARP_PID