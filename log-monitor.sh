#!/bin/bash

source /usr/local/bin/warp-common.sh 2>/dev/null || true

LOG_ROOT="${WARP_LOG_ROOT:-/var/log/warp-gost}"
MAX_LOG_SIZE=$((3 * 1024 * 1024))
CHECK_INTERVAL=300

rotate_log() {
    local log_file="$1"
    if [ -f "$log_file" ]; then
        local log_size
        log_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
        if [ "$log_size" -ge "$MAX_LOG_SIZE" ]; then
            tail -c 3M "$log_file" > "${log_file}.tmp"
            mv "${log_file}.tmp" "$log_file"
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] 日志截断: $log_file (${log_size} bytes -> 3MB)"
        fi
    fi
}

rotate_tree() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local f
    # 只处理常见日志，避免扫到过大目录
    for f in "$dir"/*.log "$dir"/*.out; do
        [ -f "$f" ] || continue
        rotate_log "$f"
    done
}

monitor_logs() {
    while true; do
        rotate_tree "$LOG_ROOT"
        local id
        if [ "${INSTANCE_COUNT:-1}" -gt 1 ]; then
            for id in $(seq 0 $((INSTANCE_COUNT - 1))); do
                rotate_tree "${LOG_ROOT}/instance-${id}"
            done
        fi
        sleep $CHECK_INTERVAL
    done
}

monitor_logs
