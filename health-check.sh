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

check_proxy() {
    local result
    result=$(curl -s --max-time 10 --socks5 127.0.0.1:1111 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
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

is_cooldown() {
    local cooldown_file="/var/log/warp-gost/health-cooldown"
    if [ -f "$cooldown_file" ]; then
        local last
        last=$(cat "$cooldown_file" 2>/dev/null)
        local now
        now=$(date +%s)
        if [ $((now - last)) -lt $HEALTH_REMINDER_INTERVAL ]; then
            return 0
        fi
    fi
    date +%s > "$cooldown_file"
    return 1
}

do_soft_reconnect() {
    log "🔄 软重连: disconnect → connect"
    local msg
    msg="正在给 WARP 做心肺复苏... &#1103; &#65039;"
    msg="${msg} 已经连续失败了 ${HEALTH_SOFT_FAILURES} 次，执行 disconnect → connect $'\n'如果这一针下去还不行的话，我可要上大家伙了！"
    pushdeer_send "💉 WARP 急救中" "$msg"

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

    local msg
    msg="WARP 彻底倒下了！"$'\n\n'
    msg="${msg}软重连也没能救回来...&#128165;"$'\n\n'
    msg="${msg}检测到你的账号类型是: <b>${account_type}</b>"$'\n'
    if [ "$account_type" = "Teams" ]; then
        msg="${msg}需要在 'Teams / Zero Trust' 选项中重新输入 Token URL"
    elif [ "$account_type" = "WARP+" ]; then
        msg="${msg}需要在 'WARP+ (License Key)' 选项中重新输入 License Key"
    else
        msg="${msg}需要重新运行 'WARP 免费版' 配置"
    fi
    msg="${msg}"$'\n\n'"请执行: docker exec -it vh-warp vhwarp"$'\n'
    msg="${msg}"$'\n'"配置完成后我会自动检测并恢复监控，在这期间每小时提醒一次（最多 ${HEALTH_REMINDER_MAX} 次）"

    pushdeer_send "🚨 SOS！WARP 离线！" "$msg"

    warp-cli --accept-tos disconnect > /dev/null 2>&1 || true
    sleep 2
    warp-cli --accept-tos registration delete > /dev/null 2>&1 || true
    sleep 2
}

send_reminder() {
    local count="$1"
    local reg_info
    reg_info=$(warp-cli --accept-tos registration show 2>/dev/null 2>/dev/null)
    local account_type="WARP"
    if echo "$reg_info" 2>/dev/null | grep -q "Organization"; then
        account_type="Teams"
    elif echo "$reg_info" 2>/dev/null | grep -q "Premium"; then
        account_type="WARP+"
    fi

    local reminders
    local left=$((HEALTH_REMINDER_MAX - count))
    if [ "$left" = "2" ]; then
        reminders="我还能再催你两次..."
    elif [ "$left" = "1" ]; then
        reminders="这是我最后一次提醒你了哦，之后我就闭嘴了 &#129328;"
    else
        reminders="已经催了 ${count} 次，还剩下 ${left} 次机会提醒你"
    fi

    local msg
    local elapsed
    elapsed=$((count * HEALTH_REMINDER_INTERVAL / 3600))
    msg="第 ${count} 次提醒你——WARP 还是断着的！（约 ${elapsed} 小时了）"$'\n\n'
    msg="${msg}账号类型: <b>${account_type}</b>"$'\n'
    msg="${msg}${reminders}"$'\n\n'
    msg="${msg}快执行一下: docker exec -it vh-warp vhwarp"$'\n'
    msg="${msg}再不配置我就要摆烂了！（开玩笑的... 吗？）"

    pushdeer_send "⏰ 第${count}次催促" "$msg"
}

send_reminder_maxed() {
    local msg
    msg="算了，我不催你了。&#129394;"$'\n\n'
    msg="${msg}WARP 代理仍然离线，但通知到此为止。"$'\n'
    msg="${msg}什么时候你重新配置好了，我会悄悄恢复监控的。"
    msg="${msg}"$'\n'"&#128521; 我不吵了，但我会继续盯着。"
    pushdeer_send "🔕 通知已停止" "$msg"
}

report_recovery() {
    local msg
    msg="他回来了！！&#127881;"$'\n\n'
    msg="${msg}WARP 连接检测通过，网络恢复正常！"$'\n'
    msg="${msg}监控已自动重启，一切安好。"$'\n\n'
    msg="${msg}想你断线的这段时间，想你了（笑）&#128149;"
    pushdeer_send "💚 WARP 满血复活" "$msg"
}

monitor_credentials_needed() {
    local reminder_count=0
    local start_time
    start_time=$(date +%s)

    log "⛔ 进入 CREDENTIALS_NEEDED 状态，等待用户重新配置..."
    pushdeer_send "🛡️ 监控待命" "完整重置后，WARP 需要你重新配置。$'\n'执行 docker exec -it vh-warp vhwarp$'\n'配置完成后我会自动恢复监控！"

    while true; do
        if check_connected; then
            log "🌐 在 CREDENTIALS_NEEDED 状态下检测到 WARP 重连"
            report_recovery
            reset_failures
            return 0
        fi

        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))

        if [ "$reminder_count" -lt "$HEALTH_REMINDER_MAX" ] && \
           [ $((elapsed % HEALTH_REMINDER_INTERVAL)) -lt "$HEALTH_CHECK_INTERVAL" ] && \
           [ "$elapsed" -gt 0 ]; then
            reminder_count=$((reminder_count + 1))
            send_reminder "$reminder_count"
        fi

        if [ "$reminder_count" -ge "$HEALTH_REMINDER_MAX" ]; then
            local max_elapsed=$(((HEALTH_REMINDER_MAX + 1) * HEALTH_REMINDER_INTERVAL))
            if [ "$elapsed" -gt "$max_elapsed" ] && [ "$reminder_count" -eq "$HEALTH_REMINDER_MAX" ]; then
                send_reminder_maxed
                reminder_count=$((reminder_count + 1))
                log "🔕 已达到最大提醒次数，通知已停止"
            fi
        fi

        sleep 30
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

        local count
        count=$(increment_failures)
        log "❌ 代理检测失败 #${count}"

        if [ "$count" -eq 1 ]; then
            pushdeer_send "🟡 WARP 打了个盹" "WARP 代理检测失败一次了...$'\n'可能只是短暂波动，我先观察观察 $'\n'如果持续失败我会采取措施的！"
        fi

        if [ "$count" -eq "$HEALTH_SOFT_FAILURES" ]; then
            do_soft_reconnect
            sleep "$HEALTH_CHECK_INTERVAL"
            continue
        fi

        if [ "$count" -ge "$HEALTH_HARD_RESET" ]; then
            do_hard_reset
            set_state "CREDENTIALS_NEEDED"
            monitor_credentials_needed
            continue
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

log "🩺 健康检测守护进程启动中..."
monitor_loop