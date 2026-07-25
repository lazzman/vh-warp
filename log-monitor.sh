#!/bin/bash

LOG_DIR="/var/log/warp-gost"
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

monitor_logs() {
    while true; do
        rotate_log "$LOG_DIR/warp-svc.log"
        rotate_log "$LOG_DIR/gost.log"
        rotate_log "$LOG_DIR/vhwarp.log"
        rotate_log "$LOG_DIR/entrypoint.log"
        rotate_log "$LOG_DIR/health-check.log"
        sleep $CHECK_INTERVAL
    done
}

monitor_logs