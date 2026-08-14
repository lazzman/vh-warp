#!/bin/bash
# 多开实例定时滚动硬重启：串行、探针门闩、失败跳过、叠轮忽略

set -uo pipefail

source /usr/local/bin/warp-common.sh

LOG_FILE="${WARP_LOG_ROOT:-/var/log/warp-gost}/rotate-restart.log"
PUSHKEY_FILE="${WARP_DATA_ROOT:-/var/lib/cloudflare-warp}/pushdeer.key"
LOCK_DIR="${WARP_RUN_ROOT}/rotate-restart.lock"
STATE_FILE="${WARP_RUN_ROOT}/rotate-restart.state"
TICK_SECONDS=30
MIN_INTERVAL_SECONDS=60
DRAIN_EMPTY_GRACE_SECONDS=2

mkdir -p "${WARP_LOG_ROOT}" "$WARP_RUN_ROOT"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

pushdeer_send() {
    local key title body
    key=$(cat "$PUSHKEY_FILE" 2>/dev/null || true)
    [ -n "$key" ] || return 1
    title="$1"
    body="$2"
    curl -s --max-time 10 --get \
        --data-urlencode "pushkey=$key" \
        --data-urlencode "text=$title" \
        --data-urlencode "desp=$body" \
        "https://api2.pushdeer.com/message/push" > /dev/null 2>&1 || true
}

rotate_interval_seconds() {
    local sec
    if ! sec="$(parse_duration_seconds "${ROTATE_RESTART_INTERVAL:-6h}")"; then
        log "⚠️ 无效 ROTATE_RESTART_INTERVAL=${ROTATE_RESTART_INTERVAL}，回退 6h"
        sec=21600
    fi
    if [ "$sec" -lt "$MIN_INTERVAL_SECONDS" ]; then
        log "⚠️ 间隔 ${sec}s 过短，抬到 ${MIN_INTERVAL_SECONDS}s"
        sec=$MIN_INTERVAL_SECONDS
    fi
    echo "$sec"
}

rotate_probe_timeout() {
    local t="${ROTATE_RESTART_PROBE_TIMEOUT:-90}"
    if ! [[ "$t" =~ ^[0-9]+$ ]] || [ "$t" -lt 15 ]; then
        echo 90
        return
    fi
    echo "$t"
}

rotate_retries() {
    local n="${ROTATE_RESTART_RETRIES:-2}"
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        echo 2
        return
    fi
    echo "$n"
}

rotate_drain_timeout() {
    local sec
    if ! sec="$(parse_duration_seconds "${ROTATE_RESTART_DRAIN_TIMEOUT:-120}")"; then
        log "⚠️ 无效 ROTATE_RESTART_DRAIN_TIMEOUT=${ROTATE_RESTART_DRAIN_TIMEOUT}，回退 120s"
        echo 120
        return
    fi
    echo "$sec"
}

instance_active_lb_connections() {
    local id="$1" backend state count
    backend="$(instance_backend_addr "$id")"
    state="$(lb_connection_state_file)"
    count="$(awk -F '\t' -v backend="$backend" '$1 == backend { print $2; exit }' "$state" 2>/dev/null || true)"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        count=0
    fi
    echo "$count"
}

lb_is_running() {
    local pid
    pid="$(cat "$(lb_pid_file)" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

wait_instance_drain() {
    local id="$1" timeout="$2" deadline active previous=-1 empty_since=0 now
    if ! lb_should_enable; then
        log "ℹ️ [实例${id}] LB 未启用，无法统计直连连接，跳过排空等待"
        return 0
    fi
    if ! lb_is_running; then
        log "⚠️ [实例${id}] LB 进程未运行，跳过排空等待，避免读取过期连接状态"
        return 0
    fi
    if [ "$timeout" -le 0 ]; then
        log "ℹ️ [实例${id}] 排空等待已关闭（ROTATE_RESTART_DRAIN_TIMEOUT=${timeout}）"
        return 0
    fi

    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        active="$(instance_active_lb_connections "$id")"
        if [ "$active" -eq 0 ]; then
            now="$(date +%s)"
            if [ "$empty_since" -eq 0 ]; then
                empty_since="$now"
                log "⏳ [实例${id}] 连接数已归零，继续确认 ${DRAIN_EMPTY_GRACE_SECONDS}s"
            elif [ $((now - empty_since)) -ge "$DRAIN_EMPTY_GRACE_SECONDS" ]; then
                log "✅ [实例${id}] 已排空，开始硬重启"
                return 0
            fi
        else
            empty_since=0
            if [ "$active" -ne "$previous" ]; then
                log "⏳ [实例${id}] 等待 ${active} 个 LB 连接自然结束（最多 ${timeout}s）"
                previous="$active"
            fi
        fi
        sleep 1
    done

    active="$(instance_active_lb_connections "$id")"
    log "⚠️ [实例${id}] 排空等待超时（剩余 ${active} 个 LB 连接），继续硬重启"
    return 0
}

write_state() {
    local key="$1" value="$2" tmp
    mkdir -p "$(dirname "$STATE_FILE")"
    touch "$STATE_FILE"
    tmp="${STATE_FILE}.tmp"
    grep -v "^${key}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    echo "${key}=${value}" >> "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

read_state() {
    local key="$1" default="${2:-}"
    local val
    val="$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo "$default"
    fi
}

lock_owner_pid() {
    cat "${LOCK_DIR}/pid" 2>/dev/null || true
}

lock_is_live() {
    local owner
    [ -d "$LOCK_DIR" ] || return 1
    owner="$(lock_owner_pid)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        return 0
    fi
    return 1
}

try_acquire_round_lock() {
    mkdir -p "$(dirname "$LOCK_DIR")"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "${LOCK_DIR}/pid"
        date +%s > "${LOCK_DIR}/started_at"
        echo "" > "${LOCK_DIR}/current_id"
        return 0
    fi
    if ! lock_is_live; then
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "$$" > "${LOCK_DIR}/pid"
            date +%s > "${LOCK_DIR}/started_at"
            echo "" > "${LOCK_DIR}/current_id"
            return 0
        fi
    fi
    return 1
}

release_round_lock() {
    local owner
    owner="$(lock_owner_pid)"
    if [ "$owner" = "$$" ]; then
        rm -rf "$LOCK_DIR"
    fi
}

clear_stale_instance_marks() {
    local id
    for id in $(instance_id_list); do
        instance_rotate_in_progress "$id" || true
    done
}

reset_instance_health_state() {
    local id="$1" run_dir
    run_dir="$(instance_run_dir "$id")"
    mkdir -p "$run_dir"
    echo "MONITORING" > "${run_dir}/health-state.txt"
    rm -f "${run_dir}/health-failure-since.txt" \
        "${run_dir}/free-retry-attempt.txt" \
        "${run_dir}/free-retry-next-at.txt"
}

wait_instance_proxy_ok() {
    local id="$1" timeout="$2"
    local deadline info warp
    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        info="$(probe_instance_trace "$id" 8 2>/dev/null || true)"
        if [ -n "$info" ]; then
            warp="${info#*warp=}"
            warp="${warp%%|*}"
            case "$warp" in
                on|plus)
                    log "✅ [实例${id}] 探针通过 (${info})"
                    return 0
                    ;;
            esac
            log "⏳ [实例${id}] 探针未就绪 warp=${warp:-?}"
        else
            log "⏳ [实例${id}] 探针无响应，继续等待"
        fi
        sleep 3
    done
    return 1
}

restart_instance_hard() {
    local id="$1"
    set_instance_context "$id"
    if ! acquire_warp_lock 15; then
        log "⏸️ [实例${id}] 配置锁占用，本轮尝试放弃"
        return 1
    fi
    /usr/local/bin/instance-ctl.sh restart "$id" >> "$LOG_FILE" 2>&1
    local rc=$?
    release_warp_lock
    return $rc
}

rotate_one_instance() {
    local id="$1" drain_timeout
    local attempts timeout try
    attempts=$(( $(rotate_retries) + 1 ))
    timeout="$(rotate_probe_timeout)"
    drain_timeout="$(rotate_drain_timeout)"

    echo "$id" > "${LOCK_DIR}/current_id" 2>/dev/null || true
    mark_instance_rotating "$id" "$$"
    # 给正在跑的 health-check tick 一点时间退出该实例
    sleep 1
    update_backend_health "$id" "down"
    log "🔄 [实例${id}] 已从 LB 摘流，等待现有连接排空（最多 ${drain_timeout}s）"
    wait_instance_drain "$id" "$drain_timeout"
    log "🔧 [实例${id}] 开始硬重启（最多 ${attempts} 次）"

    try=1
    while [ "$try" -le "$attempts" ]; do
        log "🔧 [实例${id}] 硬重启 ${try}/${attempts}"
        if ! restart_instance_hard "$id"; then
            log "⚠️ [实例${id}] instance-ctl restart 失败 (${try}/${attempts})"
        elif wait_instance_proxy_ok "$id" "$timeout"; then
            reset_instance_health_state "$id"
            update_backend_health "$id" "up"
            unmark_instance_rotating "$id"
            echo "" > "${LOCK_DIR}/current_id" 2>/dev/null || true
            log "✅ [实例${id}] 滚动重启成功 (${try}/${attempts})"
            return 0
        else
            log "⚠️ [实例${id}] 探针超时 ${timeout}s (${try}/${attempts})"
        fi
        try=$((try + 1))
        if [ "$try" -le "$attempts" ]; then
            sleep 2
        fi
    done

    log "❌ [实例${id}] 重试耗尽，跳过并继续下一台"
    unmark_instance_rotating "$id"
    echo "" > "${LOCK_DIR}/current_id" 2>/dev/null || true
    return 1
}

run_round() {
    local id ok=0 fail=0 total=0 started ended
    started="$(date +%s)"
    write_state last_start "$started"
    write_state last_result "running"
    log "🚀 滚动重启本轮开始: instances=${INSTANCE_COUNT} interval=${ROTATE_RESTART_INTERVAL} drain=$(rotate_drain_timeout)s probe=$(rotate_probe_timeout)s retries=$(rotate_retries)"

    for id in $(instance_id_list); do
        total=$((total + 1))
        if rotate_one_instance "$id"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done

    ended="$(date +%s)"
    write_state last_end "$ended"
    write_state last_ok "$ok"
    write_state last_fail "$fail"
    if [ "$fail" -eq 0 ]; then
        write_state last_result "ok"
    else
        write_state last_result "partial"
    fi
    log "🏁 滚动重启本轮结束: success=${ok}/${total} skipped=${fail} elapsed=$((ended - started))s"

    if [ "$fail" -eq 0 ]; then
        pushdeer_send "WARP 滚动重启完成" "实例 ${ok}/${total} 全部成功，耗时 $((ended - started))s。"
    else
        pushdeer_send "WARP 滚动重启部分失败" "成功 ${ok}/${total}，跳过 ${fail}，耗时 $((ended - started))s。失败实例已交健康检查继续恢复。"
    fi
}

sleep_until_epoch() {
    local target="$1" now remain chunk
    while true; do
        now="$(date +%s)"
        remain=$((target - now))
        if [ "$remain" -le 0 ]; then
            return 0
        fi
        chunk="$TICK_SECONDS"
        if [ "$remain" -lt "$chunk" ]; then
            chunk=$remain
        fi
        sleep "$chunk"
    done
}

advance_due_past() {
    local due="$1" interval="$2" now="$3" skipped=0
    while [ "$due" -le "$now" ]; do
        due=$((due + interval))
        skipped=$((skipped + 1))
    done
    echo "${due} ${skipped}"
}

show_status() {
    local interval due last_start last_end last_result enabled_txt
    interval="$(rotate_interval_seconds)"
    if rotate_restart_enabled; then
        enabled_txt="yes"
    else
        enabled_txt="no"
    fi
    due="$(read_state next_due "")"
    last_start="$(read_state last_start "")"
    last_end="$(read_state last_end "")"
    last_result="$(read_state last_result "")"
    echo "ROTATE_RESTART_ENABLED=${ROTATE_RESTART_ENABLED} active=${enabled_txt}"
    echo "INSTANCE_COUNT=${INSTANCE_COUNT} min_count=${ROTATE_RESTART_MIN_COUNT:-4}"
    echo "interval=${ROTATE_RESTART_INTERVAL} (${interval}s)"
    echo "drain_timeout=$(rotate_drain_timeout)s probe_timeout=$(rotate_probe_timeout)s retries=$(rotate_retries)"
    if [ -n "$due" ]; then
        echo "next_due=$(date -d "@${due}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$due") epoch=${due}"
    else
        echo "next_due=n/a"
    fi
    if [ -n "$last_start" ]; then
        echo "last_start=$(date -d "@${last_start}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_start")"
    fi
    if [ -n "$last_end" ]; then
        echo "last_end=$(date -d "@${last_end}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_end")"
    fi
    [ -n "$last_result" ] && echo "last_result=${last_result} ok=$(read_state last_ok 0) skipped=$(read_state last_fail 0)"
    if lock_is_live; then
        echo "lock=busy pid=$(lock_owner_pid) current=$(cat "${LOCK_DIR}/current_id" 2>/dev/null || true)"
    else
        echo "lock=idle"
    fi
}

cleanup_and_exit() {
    local id
    for id in $(instance_id_list); do
        if [ -f "$(rotate_mark_file "$id")" ]; then
            unmark_instance_rotating "$id"
        fi
    done
    release_round_lock
    exit 0
}

daemon_loop() {
    local interval now due skipped_pair skipped owner
    interval="$(rotate_interval_seconds)"
    now="$(date +%s)"
    due=$((now + interval))
    write_state next_due "$due"
    clear_stale_instance_marks

    if rotate_restart_enabled; then
        log "💚 定时滚动重启已启用: count=${INSTANCE_COUNT} interval=${ROTATE_RESTART_INTERVAL} (${interval}s) first_due=$(date -d "@${due}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$due")"
    else
        log "ℹ️ 定时滚动重启未启用（ROTATE_RESTART_ENABLED=${ROTATE_RESTART_ENABLED}, INSTANCE_COUNT=${INSTANCE_COUNT} < ${ROTATE_RESTART_MIN_COUNT:-4}）。守护进程待命，可用 rotate-restart once 手动跑一轮。"
    fi

    trap cleanup_and_exit SIGTERM SIGINT

    while true; do
        sleep_until_epoch "$due"
        if ! rotate_restart_enabled; then
            now="$(date +%s)"
            due=$((now + interval))
            write_state next_due "$due"
            continue
        fi

        if ! try_acquire_round_lock; then
            owner="$(lock_owner_pid)"
            log "⏭️ 上一轮仍在进行（pid=${owner}），忽略本轮触发"
            due=$((due + interval))
            now="$(date +%s)"
            skipped_pair="$(advance_due_past "$due" "$interval" "$now")"
            due="${skipped_pair%% *}"
            skipped="${skipped_pair#* }"
            if [ "$skipped" -gt 0 ]; then
                log "⏭️ 额外忽略 ${skipped} 个已过期触发点"
            fi
            write_state next_due "$due"
            continue
        fi

        run_round || log "⚠️ 本轮执行异常"
        release_round_lock

        due=$((due + interval))
        now="$(date +%s)"
        skipped_pair="$(advance_due_past "$due" "$interval" "$now")"
        due="${skipped_pair%% *}"
        skipped="${skipped_pair#* }"
        if [ "$skipped" -gt 0 ]; then
            log "⏭️ 本轮超时覆盖了 ${skipped} 个触发点，已忽略；下次=$(date -d "@${due}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$due")"
        fi
        write_state next_due "$due"
    done
}

run_once() {
    if ! rotate_restart_enabled && [ "${1:-}" != "--force" ]; then
        log "ℹ️ 未启用定时滚动重启，拒绝 once（需要 --force 或 ROTATE_RESTART_ENABLED=1 / 实例数>=${ROTATE_RESTART_MIN_COUNT:-4}）"
        return 1
    fi
    if ! try_acquire_round_lock; then
        log "⏭️ 已有一轮在进行（pid=$(lock_owner_pid)），忽略本次 once"
        return 0
    fi
    trap cleanup_and_exit SIGTERM SIGINT
    run_round || true
    release_round_lock
}

usage() {
    echo "用法: $0 {daemon|once [--force]|status}"
}

cmd="${1:-daemon}"
shift || true
case "$cmd" in
    daemon|"") daemon_loop ;;
    once) run_once "${1:-}" ;;
    status) show_status ;;
    *) usage; exit 1 ;;
esac
