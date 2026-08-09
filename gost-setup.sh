#!/bin/bash
# 单实例模式 GOST 管理；多实例模式由 instance-ctl 在 netns 内拉起

source /usr/local/bin/warp-common.sh

INSTANCE_ID="${1:-${CURRENT_INSTANCE_ID:-0}}"
# 兼容: gost-setup.sh start [id]  或  gost-setup.sh start
CMD="${1:-status}"
ARG2="${2:-}"

# 重新解析：gost-setup.sh {start|stop|restart|status} [instance_id]
case "$1" in
    start|stop|restart|status)
        CMD="$1"
        INSTANCE_ID="${2:-0}"
        ;;
    *)
        CMD="status"
        INSTANCE_ID=0
        ;;
esac

set_instance_context "$INSTANCE_ID"
LOG_DIR="$(instance_log_dir "$INSTANCE_ID")"
LOG_FILE="${LOG_DIR}/gost.log"
PID_FILE="$(instance_run_dir "$INSTANCE_ID")/gost.pid"
PORT="$(instance_port "$INSTANCE_ID")"
mkdir -p "$LOG_DIR" "$(instance_run_dir "$INSTANCE_ID")"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

gost_listen_spec() {
    echo "mixed://0.0.0.0:${PORT}?$(gost_listen_query)"
}

start_gost() {
    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        log "多实例模式：GOST 由 instance-ctl 管理，跳过主机侧启动"
        return 0
    fi

    if pgrep -x gost > /dev/null 2>&1; then
        # 已有 gost 时检查是否是我们的监听
        if ss -lnt 2>/dev/null | grep -q ":${PORT} "; then
            log "GOST 已在运行，端口 ${PORT}，跳过"
            return 0
        fi
    fi

    log "🚀 启动 GOST 代理 (mixed SOCKS5+HTTP 监听 0.0.0.0:${PORT})..."
    gost -L "$(gost_listen_spec)" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    local i=0
    while [ $i -lt 10 ]; do
        sleep 1
        if pgrep -x "gost" > /dev/null && ss -lnt 2>/dev/null | grep -q ":${PORT} "; then
            log "✅ GOST 启动成功，端口: ${PORT}"
            return 0
        fi
        i=$((i + 1))
    done

    log "❌ GOST 启动失败"
    return 1
}

stop_gost() {
    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        log "多实例模式：请使用 instance-ctl 停止"
        return 0
    fi
    log "🛑 停止 GOST..."
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    pkill -x gost 2>/dev/null || true
    sleep 1
    log "✅ GOST 已停止"
}

status_gost() {
    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        local ns
        ns="$(instance_netns "$INSTANCE_ID")"
        if ip netns exec "$ns" pgrep -x gost >/dev/null 2>&1; then
            echo "✅ 实例 ${INSTANCE_ID} GOST 运行中（内部 :${INSTANCE_GOST_PORT} → 外部 :${PORT}）"
        else
            echo "⭕ 实例 ${INSTANCE_ID} GOST 未运行"
        fi
        return 0
    fi
    if pgrep -x "gost" > /dev/null && ss -lnt 2>/dev/null | grep -q ":${PORT} "; then
        echo "✅ GOST 运行中（端口 ${PORT}）"
    else
        echo "⭕ GOST 未运行"
    fi
}

case "$CMD" in
    start) start_gost ;;
    stop) stop_gost ;;
    restart) stop_gost; sleep 1; start_gost ;;
    status) status_gost ;;
    *)
        echo "用法: $0 {start|stop|restart|status} [instance_id]"
        exit 1
        ;;
esac
