#!/bin/bash
# 多实例健康检测与自愈

LOG_FILE="${WARP_LOG_ROOT:-/var/log/warp-gost}/health-check.log"
PUSHKEY_FILE="${WARP_DATA_ROOT:-/var/lib/cloudflare-warp}/pushdeer.key"

HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
HEALTH_SOFT_FAILURES="${HEALTH_SOFT_FAILURES:-3}"
HEALTH_FALLBACK_AFTER="${HEALTH_FALLBACK_AFTER:-600}"
HEALTH_PROBE_TIMEOUT="${HEALTH_PROBE_TIMEOUT:-8}"
# 1：每轮输出完整状态表到 Docker 控制台；0：只写 health-check.log。
STATUS_EVENT_LOG="${STATUS_EVENT_LOG:-1}"
WARP_REGISTRATION_TIMEOUT="${WARP_REGISTRATION_TIMEOUT:-60}"
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-180}"

COMMON_SCRIPT="/usr/local/bin/warp-common.sh"
if [ ! -f "$COMMON_SCRIPT" ]; then
    COMMON_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/warp-common.sh"
fi
source "$COMMON_SCRIPT"
mkdir -p "${WARP_LOG_ROOT}" "$WARP_RUN_ROOT"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

status_table_log_enabled() {
    case "${STATUS_EVENT_LOG:-1}" in
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
        *) return 0 ;;
    esac
}

pushdeer_send() {
    local key title body
    key=$(cat "$PUSHKEY_FILE" 2>/dev/null)
    [ -n "$key" ] || return 1
    title="$1"
    body="$2"
    curl -s --max-time 10 --get \
        --data-urlencode "pushkey=$key" \
        --data-urlencode "text=$title" \
        --data-urlencode "desp=$body" \
        "https://api2.pushdeer.com/message/push" > /dev/null 2>&1
}

state_file() {
    local id="$1"
    echo "$(instance_run_dir "$id")/health-state.txt"
}

# 保存最近一次对外可见状态的签名，用于标记本轮状态表中的变化实例。
readiness_signature_file() {
    local id="$1"
    echo "$(instance_run_dir "$id")/readiness-signature.txt"
}

readiness_line_file() {
    local id="$1"
    echo "$(instance_run_dir "$id")/readiness-last-line.txt"
}

# 本轮状态表：保存最新快照及其标记。🔄 表示本轮发生变化，🆕 表示首次观测，⏸️ 表示滚动重启跳过。
declare -a HEALTH_ROUND_LINES
declare -a HEALTH_ROUND_MARKS
HEALTH_ROUND_NUMBER=0
READINESS_TRANSITION_KIND="unchanged"

readiness_signature_from_line() {
    local line="$1" readiness ip warp colo
    readiness="$(instance_info_field "$line" "readiness")"
    ip="$(instance_info_field "$line" "ip")"
    warp="$(instance_info_field "$line" "warp")"
    colo="$(instance_info_field "$line" "colo")"
    echo "${readiness}|${ip}|${warp}|${colo}"
}

# 接收 instance_info_line 的单行快照：首次记录基线；后续状态或出口变化会标记到本轮状态表。
report_readiness_transition() {
    local id="$1" line="$2" signature_file line_file previous current
    signature_file="$(readiness_signature_file "$id")"
    line_file="$(readiness_line_file "$id")"
    mkdir -p "$(dirname "$signature_file")"
    current="$(readiness_signature_from_line "$line")"
    previous="$(cat "$signature_file" 2>/dev/null || true)"
    echo "$line" > "$line_file"
    READINESS_TRANSITION_KIND="unchanged"

    if [ -z "$previous" ]; then
        echo "$current" > "$signature_file"
        READINESS_TRANSITION_KIND="initial"
        # 启动横幅已有完整快照，基线只写文件，避免与并行启动输出交错。
        log "📍 [实例${id}] 初始就绪状态: ${current} | ${line}"
    elif [ "$previous" != "$current" ]; then
        echo "$current" > "$signature_file"
        READINESS_TRANSITION_KIND="changed"
        log "🔄 [实例${id}] 就绪状态变化: ${previous} → ${current} | ${line}"
    fi
}

begin_health_round() {
    HEALTH_ROUND_LINES=()
    HEALTH_ROUND_MARKS=()
}

record_health_round_line() {
    local id="$1" line="$2" transition="${3:-unchanged}" old_mark
    HEALTH_ROUND_LINES[$id]="$line"
    old_mark="${HEALTH_ROUND_MARKS[$id]:-}"
    case "$transition" in
        changed) HEALTH_ROUND_MARKS[$id]="🔄" ;;
        initial)
            [ "$old_mark" = "🔄" ] || HEALTH_ROUND_MARKS[$id]="🆕"
            ;;
        skipped)
            [ -n "$old_mark" ] || HEALTH_ROUND_MARKS[$id]="⏸️"
            ;;
        *)
            [ -n "$old_mark" ] || HEALTH_ROUND_MARKS[$id]="·"
            ;;
    esac
}

health_round_line_for() {
    local id="$1" line
    line="${HEALTH_ROUND_LINES[$id]:-}"
    if [ -z "$line" ]; then
        line="$(cat "$(readiness_line_file "$id")" 2>/dev/null || true)"
    fi
    if [ -z "$line" ]; then
        line="instance-${id} port=$(instance_port "$id") readiness=probe_failed cli=unavailable trace=failed curl_rc=n/a error=not_probed"
    fi
    echo "$line"
}

emit_health_status_table() {
    local id line mark formatted readiness table
    local ready_count=0 waiting_count=0 direct_count=0 probe_failed_count=0 service_down_count=0 skipped_count=0
    HEALTH_ROUND_NUMBER=$((HEALTH_ROUND_NUMBER + 1))
    table="[$(date +'%Y-%m-%d %H:%M:%S')] 📊 WARP 健康状态第 ${HEALTH_ROUND_NUMBER} 轮（🔄 本轮变化 · 未变化 🆕 首次 ⏸️ 跳过）"

    for id in $(instance_id_list); do
        line="$(health_round_line_for "$id")"
        mark="${HEALTH_ROUND_MARKS[$id]:-·}"
        formatted="$(format_instance_info_line "$line")"
        table="${table}
  ${mark} ${formatted}"
        readiness="$(instance_info_field "$line" "readiness")"
        case "$readiness" in
            ready) ready_count=$((ready_count + 1)) ;;
            waiting) waiting_count=$((waiting_count + 1)) ;;
            direct) direct_count=$((direct_count + 1)) ;;
            service_down) service_down_count=$((service_down_count + 1)) ;;
            *) probe_failed_count=$((probe_failed_count + 1)) ;;
        esac
        [ "$mark" = "⏸️" ] && skipped_count=$((skipped_count + 1))
    done
    table="${table}
  汇总：ready=${ready_count} waiting=${waiting_count} direct=${direct_count} probe_failed=${probe_failed_count} service_down=${service_down_count} skipped=${skipped_count}"

    printf '%b\n' "$table" >> "$LOG_FILE"
    if status_table_log_enabled; then
        printf '%b\n' "$table"
    fi
}

failure_since_file() {
    local id="$1"
    echo "$(instance_run_dir "$id")/health-failure-since.txt"
}

# Free 恢复退避（非阻塞状态机）
free_retry_attempt_file() {
    local id="$1"
    echo "$(instance_run_dir "$id")/free-retry-attempt.txt"
}

free_retry_next_at_file() {
    local id="$1"
    echo "$(instance_run_dir "$id")/free-retry-next-at.txt"
}

# 退避序列：60 → 120 → 300 → 600 → 900s（之后固定 900）
free_retry_delay_for() {
    local attempt="$1"
    case "$attempt" in
        0) echo 60 ;;
        1) echo 120 ;;
        2) echo 300 ;;
        3) echo 600 ;;
        *) echo 900 ;;
    esac
}

clear_free_retry_state() {
    local id="$1"
    rm -f "$(free_retry_attempt_file "$id")" "$(free_retry_next_at_file "$id")"
}

# 进入 FREE_PENDING：立即允许下一次 tick 尝试（next_at=0）
enter_free_pending() {
    local id="$1" reason="${2:-}"
    mkdir -p "$(instance_run_dir "$id")"
    echo "FREE_PENDING" > "$(state_file "$id")"
    echo "0" > "$(free_retry_attempt_file "$id")"
    echo "0" > "$(free_retry_next_at_file "$id")"
    update_backend_health "$id" "down"
    if [ -n "$reason" ]; then
        log "🛟 [实例${id}] 进入 FREE_PENDING（非阻塞后台重试）: $reason"
    else
        log "🛟 [实例${id}] 进入 FREE_PENDING（非阻塞后台重试）"
    fi
}

schedule_free_retry() {
    local id="$1" attempt delay now next_at
    attempt=$(cat "$(free_retry_attempt_file "$id")" 2>/dev/null || echo 0)
    delay=$(free_retry_delay_for "$attempt")
    now=$(date +%s)
    next_at=$((now + delay))
    echo $((attempt + 1)) > "$(free_retry_attempt_file "$id")"
    echo "$next_at" > "$(free_retry_next_at_file "$id")"
    log "⏳ [实例${id}] Free 恢复第 $((attempt + 1)) 次已调度，${delay}s 后重试（不阻塞其它实例）"
}

get_fail_count() {
    local id="$1" state
    state=$(cat "$(state_file "$id")" 2>/dev/null)
    case "$state" in
        FAIL_*) echo "${state#FAIL_}" ;;
        *) echo 0 ;;
    esac
}

failure_elapsed() {
    local id="$1" since now
    since=$(cat "$(failure_since_file "$id")" 2>/dev/null)
    [ -n "$since" ] || { echo 0; return; }
    now=$(date +%s)
    echo $((now - since))
}

increment_failures() {
    local id="$1" count
    count=$(get_fail_count "$id")
    count=$((count + 1))
    if [ "$count" -eq 1 ]; then
        date +%s > "$(failure_since_file "$id")"
    fi
    echo "FAIL_${count}" > "$(state_file "$id")"
    echo "$count"
}

reset_failures() {
    local id="$1" previous
    previous=$(cat "$(state_file "$id")" 2>/dev/null)
    echo "MONITORING" > "$(state_file "$id")"
    rm -f "$(failure_since_file "$id")"
    clear_free_retry_state "$id"
    if [ -n "$previous" ] && [ "$previous" != "MONITORING" ]; then
        log "✅ [实例${id}] 健康恢复，原状态: $previous"
    fi
    update_backend_health "$id" "up"
}

# 通过对外端口探测（单/多实例统一）
check_gost_listening() {
    local id="$1" port fpid
    port="$(instance_port "$id")"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        pgrep -x gost > /dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ":${port} "
        return $?
    fi
    if ss -lnt 2>/dev/null | grep -q ":${port} "; then
        return 0
    fi
    if [ -f "$(instance_run_dir "$id")/forward.pid" ]; then
        fpid=$(cat "$(instance_run_dir "$id")/forward.pid" 2>/dev/null)
        if [ -n "$fpid" ] && kill -0 "$fpid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

restart_gost_for() {
    local id="$1"
    log "🔧 [实例${id}] GOST/转发不可用，尝试重启"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        /usr/local/bin/gost-setup.sh restart "$id" >> "$LOG_FILE" 2>&1
    else
        # 重启端口转发；若内部 gost 挂了，supervisor 会拉起
        /usr/local/bin/instance-ctl.sh exec "$id" true 2>/dev/null || true
        # 重新拉起 forward
        bash -c "source /usr/local/bin/warp-common.sh; source /usr/local/bin/instance-ctl.sh; true" 2>/dev/null || true
        # 直接调内部函数有难度（script 以 case 结尾），改为独立重启 forward
        local port ns_ip run_dir log_dir
        port="$(instance_port "$id")"
        ns_ip="$(instance_ns_ip "$id")"
        run_dir="$(instance_run_dir "$id")"
        log_dir="$(instance_log_dir "$id")"
        if [ -f "${run_dir}/forward.pid" ]; then
            kill "$(cat "${run_dir}/forward.pid")" 2>/dev/null || true
        fi
        gost -L "mixed://0.0.0.0:${port}?$(gost_forward_query)" \
             -F "mixed://${ns_ip}:${INSTANCE_GOST_PORT}" \
             >>"${log_dir}/forward.log" 2>&1 &
        echo $! > "${run_dir}/forward.pid"
    fi
    sleep 2
    check_gost_listening "$id"
}

check_proxy_instance() {
    local id="$1" line readiness
    # 与启动横幅共用同一份真实就绪判定：只有 trace 实测 warp=on/plus 才算健康。
    line="$(instance_info_line "$id" "$HEALTH_PROBE_TIMEOUT" 2>&1 || true)"
    if [ -z "$line" ]; then
        line="instance-${id} readiness=probe_failed trace=failed error=status_command_failed"
    fi
    report_readiness_transition "$id" "$line"
    record_health_round_line "$id" "$line" "$READINESS_TRANSITION_KIND"
    readiness="$(instance_info_field "$line" "readiness")"
    [ "$readiness" = "ready" ]
}

check_direct_network() {
    curl -fsS --max-time "$HEALTH_PROBE_TIMEOUT" "https://www.cloudflare.com/cdn-cgi/trace" > /dev/null 2>&1 || \
        curl -fsS --max-time "$HEALTH_PROBE_TIMEOUT" "https://connectivitycheck.gstatic.com/generate_204" > /dev/null 2>&1
}

check_registration_api() {
    curl -sS --max-time "$HEALTH_PROBE_TIMEOUT" -o /dev/null "https://api.devices.cloudflare.com" 2>/dev/null
}

# 在实例上下文执行 warp-cli
inst_warp() {
    local id="$1"
    shift
    /usr/local/bin/instance-ctl.sh exec "$id" warp-cli --accept-tos "$@"
}

inst_has_registration() {
    local id="$1"
    inst_warp "$id" registration show 2>/dev/null | grep -q "Device ID"
}

inst_is_connected() {
    local id="$1"
    inst_warp "$id" status 2>/dev/null | grep -q "Connected"
}

inst_wait_connected() {
    local id="$1" timeout="${2:-180}" elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if inst_is_connected "$id"; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

inst_get_account_type() {
    local id="$1" info
    info=$(inst_warp "$id" registration show 2>/dev/null)
    if echo "$info" | grep -q "Organization"; then
        echo "Teams"
    elif echo "$info" | grep -qE "Premium|Unlimited|WARP[+]"; then
        echo "WARP+"
    elif echo "$info" | grep -q "Device ID"; then
        echo "Free"
    else
        echo "Unknown"
    fi
}

connect_current_registration() {
    local id="$1" timeout="${2:-$WARP_CONNECT_TIMEOUT}"
    set_instance_context "$id"
    if ! acquire_warp_lock 5; then
        return 1
    fi
    # 重连前确保上游 TUN 仍在（节点不可达时 WARP 也连不上）
    upstream_pin_for "$id" >> "$LOG_FILE" 2>&1 || true
    inst_warp "$id" mode warp+doh >> "$LOG_FILE" 2>&1 || true
    inst_warp "$id" connect >> "$LOG_FILE" 2>&1 || true
    inst_wait_connected "$id" "$timeout"
    local rc=$?
    upstream_pin_for "$id" >> "$LOG_FILE" 2>&1 || true
    release_warp_lock
    return $rc
}

do_soft_reconnect() {
    local id="$1"
    log "🔄 [实例${id}] 软重连: disconnect → connect"
    pushdeer_send "WARP 软重连 #${id}" "实例 ${id} 连续 ${HEALTH_SOFT_FAILURES} 次检测异常，保留注册软重连。"
    set_instance_context "$id"
    if ! acquire_warp_lock 5; then
        log "⏸️ [实例${id}] 用户配置进行中，跳过软重连"
        return 1
    fi
    upstream_pin_for "$id" >> "$LOG_FILE" 2>&1 || true
    inst_warp "$id" disconnect >> "$LOG_FILE" 2>&1 || true
    sleep 3
    inst_warp "$id" connect >> "$LOG_FILE" 2>&1 || true
    inst_wait_connected "$id" 30 || true
    upstream_pin_for "$id" >> "$LOG_FILE" 2>&1 || true
    release_warp_lock
    if check_proxy_instance "$id"; then
        return 0
    fi
    log "⚠️ [实例${id}] 软重连后仍不可用"
    set_instance_context "$id"
    if acquire_warp_lock 5; then
        inst_warp "$id" disconnect >> "$LOG_FILE" 2>&1 || true
        release_warp_lock
    fi
    return 1
}

register_free() {
    local id="$1"
    if inst_has_registration "$id"; then
        return 0
    fi
    log "🆕 [实例${id}] 创建 Free WARP 注册"
    inst_warp "$id" tunnel protocol set MASQUE >> "$LOG_FILE" 2>&1 || true
    if ! inst_warp "$id" registration new >> "$LOG_FILE" 2>&1; then
        log "⚠️ [实例${id}] registration new 失败"
    fi
    local elapsed=0
    while [ "$elapsed" -lt "$WARP_REGISTRATION_TIMEOUT" ]; do
        if inst_has_registration "$id"; then
            log "✅ [实例${id}] Free 注册完成"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log "⚠️ [实例${id}] Free 注册超时"
    return 1
}

fallback_to_free() {
    local id="$1" original_type
    original_type=$(inst_get_account_type "$id")
    log "🛟 [实例${id}] 准备回退 Free，当前账户: $original_type"

    set_instance_context "$id"
    if ! acquire_warp_lock 5; then
        log "⏸️ [实例${id}] 用户配置进行中，取消回退"
        return 1
    fi

    inst_warp "$id" disconnect >> "$LOG_FILE" 2>&1 || true
    sleep 3
    if ! check_direct_network; then
        log "🌐 [实例${id}] 基础网络不可用，保留注册"
        inst_warp "$id" connect >> "$LOG_FILE" 2>&1 || true
        release_warp_lock
        return 2
    fi
    if ! check_registration_api; then
        log "🌐 [实例${id}] 注册 API 不可达，保留注册"
        release_warp_lock
        return 4
    fi

    inst_warp "$id" mode warp+doh >> "$LOG_FILE" 2>&1 || true
    inst_warp "$id" connect >> "$LOG_FILE" 2>&1 || true
    if inst_wait_connected "$id" 45 && check_proxy_instance "$id"; then
        log "✅ [实例${id}] 原注册重连成功，取消回退"
        release_warp_lock
        return 0
    fi

    inst_warp "$id" disconnect >> "$LOG_FILE" 2>&1 || true
    sleep 2
    if ! check_direct_network; then
        log "🌐 [实例${id}] 最后重连后基础网络异常"
        release_warp_lock
        return 2
    fi

    log "💥 [实例${id}] 回退到 Free"
    if inst_has_registration "$id"; then
        inst_warp "$id" registration delete >> "$LOG_FILE" 2>&1 || true
        local e=0
        while [ $e -lt 30 ]; do
            inst_has_registration "$id" || break
            sleep 1
            e=$((e + 1))
        done
        if inst_has_registration "$id"; then
            log "⚠️ [实例${id}] 原注册删除未确认"
            release_warp_lock
            return 1
        fi
    fi

    if ! register_free "$id"; then
        release_warp_lock
        enter_free_pending "$id" "原账户 ${original_type} 已回退，Free 注册未完成"
        schedule_free_retry "$id"   # 当轮已尝试，进入退避，避免立刻再 tick 一次
        pushdeer_send "WARP Free 注册等待 #${id}" "实例 ${id} 原账户 ${original_type} 已回退，后台非阻塞重试中。"
        return 3
    fi

    inst_warp "$id" mode warp+doh >> "$LOG_FILE" 2>&1 || true
    inst_warp "$id" connect >> "$LOG_FILE" 2>&1 || true
    # 回退当轮用较短等待，避免长时间卡住其它实例；未通则交 FREE_PENDING 后台重试
    if inst_wait_connected "$id" 45 && check_proxy_instance "$id"; then
        log "✅ [实例${id}] Free 回退成功"
        pushdeer_send "WARP 已恢复为 Free #${id}" "实例 ${id}\n原账户: ${original_type}\n当前: Free"
        release_warp_lock
        return 0
    fi

    log "⚠️ [实例${id}] Free 已注册但暂未连通，转入后台重试"
    inst_warp "$id" disconnect >> "$LOG_FILE" 2>&1 || true
    release_warp_lock
    enter_free_pending "$id" "Free 已注册但暂未连通"
    schedule_free_retry "$id"
    return 3
}

# 非阻塞 Free 恢复：每轮主循环最多尝试一次，退避期内只探针不重连
# 恢复成功 → reset_failures 重新加入 LB；失败 → 调度下次，立刻返回让其它实例继续检测
tick_free_pending() {
    local id="$1" now next_at remain

    if ! check_gost_listening "$id"; then
        restart_gost_for "$id" || log "⚠️ [实例${id}] FREE_PENDING 期间 GOST 重启失败"
    fi

    # 每轮都探针：好了立刻回池，不等退避结束
    if check_proxy_instance "$id"; then
        reset_failures "$id"
        return 0
    fi
    update_backend_health "$id" "down"

    now=$(date +%s)
    next_at=$(cat "$(free_retry_next_at_file "$id")" 2>/dev/null || echo 0)
    if [ -z "$next_at" ]; then
        next_at=0
    fi

    if [ "$now" -lt "$next_at" ]; then
        remain=$((next_at - now))
        log "⏳ [实例${id}] FREE_PENDING 冷却中，${remain}s 后重试（本轮跳过重连，不阻塞其它实例）"
        return 0
    fi

    log "🔧 [实例${id}] FREE_PENDING 执行一次恢复尝试"
    set_instance_context "$id"
    if ! acquire_warp_lock 5; then
        log "⏸️ [实例${id}] 用户配置进行中，推迟 Free 恢复"
        # 短延迟后再试，避免狂打锁
        echo $((now + 30)) > "$(free_retry_next_at_file "$id")"
        return 0
    fi

    inst_warp "$id" disconnect >> "$LOG_FILE" 2>&1 || true
    sleep 1

    if ! check_direct_network; then
        log "🌐 [实例${id}] 基础网络不可用，推迟 Free 恢复"
        release_warp_lock
        schedule_free_retry "$id"
        return 0
    fi

    if ! inst_has_registration "$id"; then
        if ! check_registration_api; then
            log "🌐 [实例${id}] 注册 API 不可达，推迟 Free 注册"
            release_warp_lock
            schedule_free_retry "$id"
            return 0
        fi
        # 注册等待仍可能占用数十秒，但只在本实例 tick 内发生一次
        register_free "$id" || true
    fi

    if inst_has_registration "$id"; then
        inst_warp "$id" mode warp+doh >> "$LOG_FILE" 2>&1 || true
        inst_warp "$id" connect >> "$LOG_FILE" 2>&1 || true
        # 短等待：未连上留给后续探针 / 下次 tick，避免阻塞整轮
        inst_wait_connected "$id" 30 || true
    fi
    release_warp_lock

    if check_proxy_instance "$id"; then
        reset_failures "$id"
        pushdeer_send "WARP Free 已恢复 #${id}" "实例 ${id} 后台重试成功，已重新加入负载均衡。"
        return 0
    fi

    # 失败：断开以保持直连可用，调度下次，返回主循环
    set_instance_context "$id"
    if acquire_warp_lock 3; then
        inst_warp "$id" disconnect >> "$LOG_FILE" 2>&1 || true
        release_warp_lock
    fi
    schedule_free_retry "$id"
    return 0
}

check_one_instance() {
    local id="$1" count elapsed fallback_rc state

    if instance_rotate_in_progress "$id"; then
        log "⏸️ [实例${id}] 定时滚动重启进行中，本轮健康检查跳过"
        record_health_round_line "$id" "$(health_round_line_for "$id")" "skipped"
        return 0
    fi

    state=$(cat "$(state_file "$id")" 2>/dev/null || echo "MONITORING")

    # FREE_PENDING：独立非阻塞路径，不进入长 sleep
    if [ "$state" = "FREE_PENDING" ]; then
        tick_free_pending "$id" || true
        return 0
    fi

    if ! check_gost_listening "$id"; then
        restart_gost_for "$id" || log "⚠️ [实例${id}] GOST 重启失败"
    fi

    if check_proxy_instance "$id"; then
        reset_failures "$id"
        return 0
    fi

    # 标记后端 down，LB 摘流（后续轮次仍会检测，恢复后 reset 加回）
    update_backend_health "$id" "down"

    if ! inst_has_registration "$id" && check_direct_network; then
        enter_free_pending "$id" "无注册，转入后台 Free 注册"
        # 当轮立刻 tick 一次（next_at=0），然后返回，不阻塞后续实例
        tick_free_pending "$id" || true
        return 0
    fi

    count=$(increment_failures "$id")
    elapsed=$(failure_elapsed "$id")
    log "❌ [实例${id}] 代理检测失败 #${count}，持续 ${elapsed}s"

    if [ "$count" -eq 1 ]; then
        pushdeer_send "WARP 检测异常 #${id}" "实例 ${id} 首次检测异常，观察中。"
    fi

    if [ "$count" -eq "$HEALTH_SOFT_FAILURES" ]; then
        if do_soft_reconnect "$id"; then
            reset_failures "$id"
            return 0
        fi
    fi

    if [ "$elapsed" -ge "$HEALTH_FALLBACK_AFTER" ]; then
        fallback_to_free "$id"
        fallback_rc=$?
        case "$fallback_rc" in
            0) reset_failures "$id" ;;
            2) log "⏳ [实例${id}] 基础网络异常"; reset_failures "$id" ;;
            3)
                # fallback 当轮已尝试并 schedule；只保证状态，不在当轮重复 tick
                if [ "$(cat "$(state_file "$id")" 2>/dev/null)" != "FREE_PENDING" ]; then
                    enter_free_pending "$id" "fallback 返回 3"
                    schedule_free_retry "$id"
                fi
                ;;
            4) log "⏳ [实例${id}] 注册 API 不可达" ;;
            *) log "⚠️ [实例${id}] 本轮回退未执行" ;;
        esac
    fi
}

monitor_loop() {
    local id
    log "💚 健康检测启动: instances=${INSTANCE_COUNT} interval=${HEALTH_CHECK_INTERVAL}s soft=${HEALTH_SOFT_FAILURES} fallback=${HEALTH_FALLBACK_AFTER}s"

    for id in $(instance_id_list); do
        mkdir -p "$(instance_run_dir "$id")"
        # 每次守护进程启动重新建立基线，首轮状态表会以 🆕 标出。
        rm -f "$(readiness_signature_file "$id")"
        echo "MONITORING" > "$(state_file "$id")"
        update_backend_health "$id" "up"
    done

    while true; do
        begin_health_round
        for id in $(instance_id_list); do
            check_one_instance "$id" || true
        done
        emit_health_status_table
        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

if [ "${HEALTH_CHECK_LIB_ONLY:-0}" != "1" ]; then
    log "🩺 健康检测守护进程启动中 (instances=${INSTANCE_COUNT})"
    monitor_loop
fi
