#!/bin/bash
# 统一入口负载均衡管理

source /usr/local/bin/warp-common.sh

LOG_FILE="${WARP_LOG_ROOT:-/var/log/warp-gost}/lb.log"
PID_FILE="${WARP_RUN_ROOT:-/var/lib/cloudflare-warp/.runtime}/lb.pid"
mkdir -p "${WARP_LOG_ROOT:-/var/log/warp-gost}" "${WARP_RUN_ROOT:-/var/lib/cloudflare-warp/.runtime}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

start_lb() {
    if ! lb_should_enable; then
        log "负载均衡未启用 (INSTANCE_COUNT=${INSTANCE_COUNT}, LB_ENABLED=${LB_ENABLED})"
        return 0
    fi

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log "LB 已在运行 (PID $(cat "$PID_FILE"))"
        return 0
    fi

    write_backends_file
    export LB_PORT LB_STRATEGY
    export LB_BACKENDS_FILE
    LB_BACKENDS_FILE="$(backends_file)"
    export LB_BACKENDS_FILE

    log "启动 LB :${LB_PORT} strategy=${LB_STRATEGY} backends=$(cat "$(backends_file)" | tr '\n' ' ')"
    python3 /usr/local/bin/lb-proxy.py >>"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    sleep 1
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log "✅ LB 启动成功 0.0.0.0:${LB_PORT}"
        return 0
    fi
    log "❌ LB 启动失败"
    return 1
}

stop_lb() {
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
        log "LB 已停止"
    fi
    pkill -f "python3 /usr/local/bin/lb-proxy.py" 2>/dev/null || true
}

status_lb() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "LB: running pid=$(cat "$PID_FILE") port=${LB_PORT} strategy=${LB_STRATEGY}"
        echo "Backends:"
        cat "$(backends_file)" 2>/dev/null | sed 's/^/  /'
    else
        echo "LB: stopped"
    fi
}

case "${1:-}" in
    start) start_lb ;;
    stop) stop_lb ;;
    restart) stop_lb; sleep 1; start_lb ;;
    status) status_lb ;;
    *) echo "用法: $0 {start|stop|restart|status}"; exit 1 ;;
esac
