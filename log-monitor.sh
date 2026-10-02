#!/bin/bash

LOG_DIR="/var/log/warp-gost"
MAX_LOG_SIZE=$((3 * 1024 * 1024))
CHECK_INTERVAL="${LOG_CHECK_INTERVAL:-60}"

rotate_log() {
    local log_file="$1"
    [ -f "$log_file" ] || return 0

    local log_size
    log_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
    [ "$log_size" -ge "$MAX_LOG_SIZE" ] 2>/dev/null || return 0

    # copytruncate：先取尾部副本，再就地截断原文件。
    # 不能用 mv 替换文件：warp-svc / gost 由 entrypoint 与 gost-setup 以 ">>" 拉起
    # 并长期持有该文件的 fd。mv 会 unlink 旧 inode，进程继续向无路径的 inode 追加
    # 写入，空间永不回收，磁盘与页缓存持续增长。
    if ! tail -c "$MAX_LOG_SIZE" "$log_file" > "${log_file}.tmp" 2>/dev/null; then
        rm -f "${log_file}.tmp"
        return 0
    fi
    if cat "${log_file}.tmp" > "$log_file" 2>/dev/null; then
        printf '[%s] 日志截断: %s (%s bytes -> %s bytes)\n' \
            "$(date +'%Y-%m-%d %H:%M:%S')" "$log_file" "$log_size" "$MAX_LOG_SIZE" \
            >> "$LOG_DIR/entrypoint.log"
    fi
    rm -f "${log_file}.tmp"
    return 0
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
