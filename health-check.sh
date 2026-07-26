#!/bin/bash

LOG_FILE="/var/log/warp-gost/health-check.log"
STATE_FILE="/var/log/warp-gost/health-state.txt"
PUSHKEY_FILE="/var/lib/cloudflare-warp/pushdeer.key"

HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
HEALTH_SOFT_FAILURES="${HEALTH_SOFT_FAILURES:-3}"
HEALTH_HARD_RESET="${HEALTH_HARD_RESET:-9}"
HEALTH_REMINDER_MAX="${HEALTH_REMINDER_MAX:-3}"
HEALTH_REMINDER_INTERVAL="${HEALTH_REMINDER_INTERVAL:-3600}"

mkdir -p /var/log/warp-gost

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

pushdeer_send() {
    local key
    key=$(cat "$PUSHKEY_FILE" 2>/dev/null)
    if [ -z "$key" ]; then
        return 1
    fi
    local title="$1"
    local body="$2"
    local encoded_title
    encoded_title=$(echo -n "$title" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo -n "$title" | sed 's/ /%20/g')
    local encoded_body
    encoded_body=$(echo -n "$body" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo -n "$body" | sed 's/ /%20/g')
    curl -s --max-time 10 "https://api2.pushdeer.com/message/push?pushkey=${key}&text=${encoded_title}&desp=${encoded_body}" > /dev/null 2>&1
}

get_state() {
    cat "$STATE_FILE" 2>/dev/null || echo "MONITORING"
}

set_state() {
    echo "$1" > "$STATE_FILE"
}

get_fail_count() {
    local state
    state=$(get_state)
    if [ "$state" = "MONITORING" ]; then
        echo "0"
    else
        local count
        count=$(echo "$state" | grep -oE '[0-9]+' | head -1)
        echo "${count:-0}"
    fi
}

check_connected() {
    if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
        return 0
    fi
    return 1
}

check_gost() {
    if pgrep -x "gost" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

restart_gost() {
    log "🔧 GOST 未运行，尝试重启..."
    gost -L "mixed://0.0.0.0:1111" >> /var/log/warp-gost/gost.log 2>&1 &
    sleep 2
    if check_gost; then
        log "✅ GOST 重启成功"
        return 0
    fi
    log "❌ GOST 重启失败"
    return 1
}

check_proxy() {
    local result
    result=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:1111 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    if echo "$result" | grep -qE "warp=(on|plus)"; then
        return 0
    fi
    return 1
}

reset_failures() {
    set_state "MONITORING"
    log "✅ 健康恢复，重置计数器"
}

increment_failures() {
    local count
    count=$(get_fail_count)
    count=$((count + 1))
    set_state "FAIL_${count}"
    echo "$count"
}

do_soft_reconnect() {
    log "🔄 软重连: disconnect → connect"
    local msg="**失败次数**: ${HEALTH_SOFT_FAILURES}"$'\n'"**操作**: \`disconnect\` → \`connect\`"$'\n\n'"已执行软重连，观察恢复情况..."
    pushdeer_send "🔧 WARP 软重连" "$msg"

    warp-cli --accept-tos disconnect > /dev/null 2>&1 || true
    sleep 3
    warp-cli --accept-tos connect > /dev/null 2>&1 || true
    sleep 5
}

do_hard_reset() {
    log "🛟 完整重置: 删除注册信息"
    local reg_info
    reg_info=$(warp-cli --accept-tos registration show 2>/dev/null)
    local account_type="WARP"
    if echo "$reg_info" | grep -q "Organization"; then
        account_type="Teams"
    elif echo "$reg_info" | grep -q "Premium"; then
        account_type="WARP+"
    fi

    warp-cli --accept-tos disconnect > /dev/null 2>&1 || true
    sleep 2
    warp-cli --accept-tos registration delete > /dev/null 2>&1 || true
    sleep 2
    warp-cli --accept-tos registration new > /dev/null 2>&1
    sleep 3
    warp-cli --accept-tos connect > /dev/null 2>&1 || true
    sleep 3

    if check_connected; then
        log "✅ 自动重连成功（免费版）"
        if [ "$account_type" = "WARP" ]; then
            local rmsg="**账号类型**: 免费版"$'\n'"**操作**: 自动重连"$'\n\n'"WARP 已自动恢复，无需干预。"
            pushdeer_send "✅ WARP 已恢复" "$rmsg"
        else
            local rmsg="**原账号**: ${account_type}"$'\n'"**已恢复为**: 免费版"$'\n\n'"代理已恢复，原套餐降级。"$'\n\n'"---"$'\n'"恢复原套餐: \`docker exec -it vh-warp vhwarp\`"
            pushdeer_send "✅ WARP 已恢复（降级）" "$rmsg"
        fi
        return 0
    fi

    log "⚠️ 自动重连失败，进入等待状态"
    local rmsg="**账号类型**: ${account_type}"$'\n'"**状态**: 自动重连失败"$'\n\n'"---"$'\n'"\`docker exec -it vh-warp vhwarp\`"
    pushdeer_send "🚨 WARP 离线" "$rmsg"
    return 1
}

send_reminder() {
    local count="$1"
    local reg_info
    reg_info=$(warp-cli --accept-tos registration show 2>/dev/null)
    local account_type="WARP"
    if echo "$reg_info" 2>/dev/null | grep -q "Organization"; then
        account_type="Teams"
    elif echo "$reg_info" 2>/dev/null | grep -q "Premium"; then
        account_type="WARP+"
    fi

    local reminders
    local left=$((HEALTH_REMINDER_MAX - count))
    if [ "$left" = "0" ]; then
        reminders="最后一次提醒"
    else
        reminders="剩余 ${left} 次提醒"
    fi

    local elapsed=$((count * HEALTH_REMINDER_INTERVAL / 3600))
    local msg="**提醒**: ${count}/${HEALTH_REMINDER_MAX}"$'\n'"**已离线**: 约 ${elapsed} 小时"$'\n'"**账号**: ${account_type}"$'\n\n'"${reminders}"$'\n\n'"---"$'\n'"\`docker exec -it vh-warp vhwarp\`"

    pushdeer_send "⏰ 提醒 (${count}/${HEALTH_REMINDER_MAX})" "$msg"
}

send_reminder_maxed() {
    local msg="**状态**: 通知已停止"$'\n\n'"WARP 仍离线，不再催促。"$'\n'"配置恢复后监控自动重启。"
    pushdeer_send "🔕 通知静默" "$msg"
}

report_recovery() {
    local msg="**状态**: 网络已恢复"$'\n\n'"WARP 连接检测通过，监控正常运行。"
    pushdeer_send "✅ WARP 已恢复" "$msg"
}

monitor_credentials_needed() {
    local reminder_count=0
    local start_time
    start_time=$(date +%s)
    local last_reminder_time=$start_time

    log "⛔ 进入 CREDENTIALS_NEEDED 状态，等待用户重新配置..."
    pushdeer_send "⏳ 等待配置" "**状态**: 等待手动配置"$'\n\n'"---"$'\n'"\`docker exec -it vh-warp vhwarp\`"

    while true; do
        if check_connected; then
            log "🌐 在 CREDENTIALS_NEEDED 状态下检测到 WARP 重连"
            report_recovery
            reset_failures
            return 0
        fi

        local now
        now=$(date +%s)

        if [ "$reminder_count" -lt "$HEALTH_REMINDER_MAX" ] && \
           [ $((now - last_reminder_time)) -ge "$HEALTH_REMINDER_INTERVAL" ]; then
            reminder_count=$((reminder_count + 1))
            send_reminder "$reminder_count"
            last_reminder_time=$now
        fi

        if [ "$reminder_count" -ge "$HEALTH_REMINDER_MAX" ]; then
            local max_elapsed=$(((HEALTH_REMINDER_MAX + 1) * HEALTH_REMINDER_INTERVAL))
            local elapsed=$((now - start_time))
            if [ "$elapsed" -gt "$max_elapsed" ] && [ "$reminder_count" -eq "$HEALTH_REMINDER_MAX" ]; then
                send_reminder_maxed
                reminder_count=$((reminder_count + 1))
                log "🔕 已达到最大提醒次数，通知已停止"
            fi
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

monitor_loop() {
    log "💚 健康检测已启动（间隔: ${HEALTH_CHECK_INTERVAL}秒, 软重连: ${HEALTH_SOFT_FAILURES}, 完整重置: ${HEALTH_HARD_RESET}）"

    while true; do
        local state
        state=$(get_state)

        if [ "$state" = "CREDENTIALS_NEEDED" ]; then
            monitor_credentials_needed
            state=$(get_state)
            if [ "$state" != "CREDENTIALS_NEEDED" ]; then
                continue
            fi
        fi

        if check_proxy; then
            if [ "$state" != "MONITORING" ]; then
                log "✅ 代理从状态 $state 恢复"
                report_recovery
            fi
            reset_failures
            sleep "$HEALTH_CHECK_INTERVAL"
            continue
        fi

        if ! check_gost; then
            log "⚠️ GOST 未运行，尝试重启..."
            restart_gost
            if check_proxy; then
                log "✅ GOST 重启后代理恢复"
                reset_failures
                sleep "$HEALTH_CHECK_INTERVAL"
                continue
            fi
            log "⚠️ GOST 重启后代理仍失败"
        fi

        local count
        count=$(increment_failures)
        log "❌ 代理检测失败 #${count}"

        if [ "$count" -eq 1 ]; then
            pushdeer_send "🟡 WARP 检测异常" "**失败次数**: 1"$'\n\n'"可能为短暂波动，持续观察中。"$'\n'"若连续失败将自动采取措施。"
        fi

        if [ "$count" -eq "$HEALTH_SOFT_FAILURES" ]; then
            do_soft_reconnect
            if check_proxy; then
                log "✅ 软重连后检测通过"
                reset_failures
            else
                log "⚠️ 软重连后检测仍失败"
            fi
            sleep "$HEALTH_CHECK_INTERVAL"
            continue
        fi

        if [ "$count" -ge "$HEALTH_HARD_RESET" ]; then
            if do_hard_reset; then
                reset_failures
                sleep "$HEALTH_CHECK_INTERVAL"
                continue
            else
                set_state "CREDENTIALS_NEEDED"
                monitor_credentials_needed
                continue
            fi
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

log "🩺 健康检测守护进程启动中..."
monitor_loop