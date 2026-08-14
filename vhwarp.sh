#!/bin/bash

LOG_FILE="/var/log/warp-gost/vhwarp.log"
mkdir -p /var/log/warp-gost
source /usr/local/bin/warp-common.sh

# 解析 -i / --instance
INSTANCE_ID="${INSTANCE_ID:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--instance)
            INSTANCE_ID="$2"
            shift 2
            ;;
        -h|--help)
            echo "用法: vhwarp [-i 实例ID]"
            echo "  环境变量: INSTANCE_COUNT BASE_PORT LB_PORT LB_STRATEGY LB_ROTATE_INTERVAL ROTATE_RESTART_*"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 选择实例（多实例时）
select_instance() {
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        INSTANCE_ID=0
        set_instance_context 0
        return 0
    fi
    if [ -n "$INSTANCE_ID" ]; then
        if ! [[ "$INSTANCE_ID" =~ ^[0-9]+$ ]] || [ "$INSTANCE_ID" -ge "$INSTANCE_COUNT" ]; then
            echo "❌ 无效实例 ID: ${INSTANCE_ID}（有效范围 0-$((INSTANCE_COUNT - 1))）"
            return 1
        fi
        set_instance_context "$INSTANCE_ID"
        return 0
    fi

    echo ""
    echo "  当前共 ${INSTANCE_COUNT} 个实例："
    local id
    for id in $(instance_id_list); do
        echo "    [${id}] 端口 $(instance_port "$id")  数据 $(instance_data_dir "$id")"
    done
    echo "    [a] 全部实例（逐个配置）"
    echo ""
    read -r -p "  选择实例 ID [0-$((INSTANCE_COUNT - 1))/a]: " choice
    if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
        INSTANCE_ID="all"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -ge "$INSTANCE_COUNT" ]; then
        echo "❌ 无效选择"
        return 1
    fi
    INSTANCE_ID="$choice"
    set_instance_context "$INSTANCE_ID"
}

# 通过 instance-ctl 执行 warp-cli，兼容单/多实例
wcli() {
    /usr/local/bin/instance-ctl.sh exec "${CURRENT_INSTANCE_ID:-0}" warp-cli --accept-tos "$@"
}

check_warp_svc() {
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        if ! pgrep -x "warp-svc" > /dev/null; then
            echo "❌ 错误: warp-svc 未运行"
            return 1
        fi
    else
        local ns
        ns="$(instance_netns "${CURRENT_INSTANCE_ID:-0}")"
        if ! ip netns exec "$ns" pgrep -x warp-svc >/dev/null 2>&1; then
            # 尝试 nsenter
            if ! /usr/local/bin/instance-ctl.sh exec "${CURRENT_INSTANCE_ID:-0}" pgrep -x warp-svc >/dev/null 2>&1; then
                echo "❌ 错误: 实例 ${CURRENT_INSTANCE_ID} 的 warp-svc 未运行"
                return 1
            fi
        fi
    fi
    return 0
}

wait_for_connected_local() {
    local max_attempts=${1:-60}
    local count=0
    while [ $count -lt $max_attempts ]; do
        local status
        status=$(wcli status 2>/dev/null)
        echo "$status" >> "$LOG_FILE"
        if echo "$status" | grep -q "Connected" 2>/dev/null; then
            return 0
        fi
        echo -n "."
        sleep 3
        count=$((count + 1))
    done
    return 1
}

wait_for_registration_local() {
    local i=0
    while [ $i -lt 30 ]; do
        if wcli registration show 2>/dev/null | grep -q "Device ID"; then
            echo ""
            return 0
        fi
        echo -n "."
        sleep 2
        i=$((i + 1))
    done
    echo ""
    return 1
}

has_registration_local() {
    wcli registration show 2>/dev/null | grep -q "Device ID"
}

get_account_type_local() {
    local info
    info=$(wcli registration show 2>/dev/null)
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

clean_config() {
    echo "🧹 正在清理旧配置 (实例 ${CURRENT_INSTANCE_ID})..."
    log "清理旧配置 instance=${CURRENT_INSTANCE_ID}"
    wcli disconnect > /dev/null 2>&1 || true
    if has_registration_local; then
        wcli registration delete >> "$LOG_FILE" 2>&1 || true
        local i=0
        while [ $i -lt 30 ]; do
            has_registration_local || break
            sleep 1
            i=$((i + 1))
        done
        if has_registration_local; then
            echo "❌ 旧注册删除超时，请稍后重试"
            return 1
        fi
    fi
    return 0
}

begin_configuration() {
    set_instance_context "${CURRENT_INSTANCE_ID:-0}"
    if ! acquire_warp_lock 30; then
        echo "❌ 另一个 WARP 配置或恢复操作正在进行，请稍后重试"
        return 1
    fi
}

finish_configuration() {
    mkdir -p "$(instance_run_dir "${CURRENT_INSTANCE_ID:-0}")"
    echo "MONITORING" > "$(instance_run_dir "${CURRENT_INSTANCE_ID:-0}")/health-state.txt"
    rm -f "$(instance_run_dir "${CURRENT_INSTANCE_ID:-0}")/health-failure-since.txt"
    release_warp_lock
}

run_on_instances() {
    local action="$1"
    if [ "$INSTANCE_ID" = "all" ]; then
        local id
        for id in $(instance_id_list); do
            echo ""
            echo "════════ 实例 ${id} ════════"
            INSTANCE_ID="$id"
            set_instance_context "$id"
            "$action"
        done
        INSTANCE_ID="all"
    else
        set_instance_context "${INSTANCE_ID:-0}"
        "$action"
    fi
}

configure_free() {
    echo ""
    echo "📡 正在配置 WARP 免费版 (实例 ${CURRENT_INSTANCE_ID})..."
    echo "📡 协议: MASQUE  端口: $(instance_port "${CURRENT_INSTANCE_ID}")"

    if ! check_warp_svc; then
        return 1
    fi

    local current_type confirm
    current_type=$(get_account_type_local)
    if [ "$current_type" = "WARP+" ] || [ "$current_type" = "Teams" ]; then
        echo "⚠️ 当前账户为 ${current_type}，切换到 Free 将删除当前设备注册。"
        read -r -p "确认继续？(y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "↩️ 已取消"
            return 0
        fi
    fi

    begin_configuration || return 1

    if ! clean_config; then
        finish_configuration
        return 1
    fi
    log "开始配置 WARP Free instance=${CURRENT_INSTANCE_ID}"

    wcli tunnel protocol set MASQUE > /dev/null 2>&1
    sleep 2

    wcli registration new > /dev/null 2>&1
    if ! wait_for_registration_local; then
        echo "❌ 注册失败"
        finish_configuration
        return 1
    fi

    wcli mode warp+doh > /dev/null 2>&1
    sleep 1

    wcli connect > /dev/null 2>&1
    echo -n "⏳ 正在连接（最长等待 3 分钟）..."
    if wait_for_connected_local 60; then
        echo ""
        echo "✅ 实例 ${CURRENT_INSTANCE_ID} WARP 免费版连接成功 (MASQUE)"
        log "WARP Free 配置成功 instance=${CURRENT_INSTANCE_ID}"
        show_status_one

        if [ "$INSTANCE_COUNT" -eq 1 ]; then
            echo ""
            echo "🔍 检查 GOST 代理..."
            if /usr/local/bin/gost-setup.sh start 0; then
                echo "✅ GOST 代理已启动，端口: $(instance_port 0)"
            else
                echo "❌ GOST 代理启动失败"
            fi
        fi
    else
        echo ""
        echo "❌ WARP 连接失败"
        finish_configuration
        return 1
    fi
    finish_configuration
}

configure_teams() {
    echo ""
    echo "🔧 正在配置 Teams / Zero Trust (实例 ${CURRENT_INSTANCE_ID})..."
    echo "🔗 从 https://<团队名>.cloudflareaccess.com/warp 获取 Token URL"

    if ! check_warp_svc; then
        return 1
    fi

    read -r -p "请输入 Teams Token URL: " token_url
    if [ -z "$token_url" ]; then
        echo "❌ Token URL 不能为空"
        return 1
    fi

    begin_configuration || return 1
    if ! clean_config; then
        finish_configuration
        return 1
    fi
    log "开始配置 Teams instance=${CURRENT_INSTANCE_ID}"

    echo "⏳ 正在注册 Teams Token..."
    if ! wcli registration token "$token_url" > /dev/null 2>&1; then
        echo "❌ Teams Token 注册失败，Token 可能已过期"
        finish_configuration
        return 1
    fi
    if ! wait_for_registration_local; then
        echo "❌ Teams 注册超时"
        finish_configuration
        return 1
    fi
    if [ "$(get_account_type_local)" != "Teams" ]; then
        echo "❌ 注册未关联到 Teams Organization"
        finish_configuration
        return 1
    fi

    wcli mode warp+doh > /dev/null 2>&1
    sleep 1
    wcli connect > /dev/null 2>&1
    echo -n "⏳ 正在连接（最长等待 5 分钟）..."
    if wait_for_connected_local 100; then
        echo ""
        echo "✅ 实例 ${CURRENT_INSTANCE_ID} Teams 连接成功"
        show_status_one
    else
        echo ""
        echo "❌ Teams 连接失败"
        wcli status || true
        finish_configuration
        return 1
    fi
    finish_configuration
}

configure_plus() {
    echo ""
    echo "💎 正在配置 WARP+ (实例 ${CURRENT_INSTANCE_ID})..."

    if ! check_warp_svc; then
        return 1
    fi

    read -r -p "请输入 WARP+ License Key: " license_key
    if [ -z "$license_key" ]; then
        echo "❌ License Key 不能为空"
        return 1
    fi

    begin_configuration || return 1
    if ! clean_config; then
        finish_configuration
        return 1
    fi
    log "开始配置 WARP+ instance=${CURRENT_INSTANCE_ID}"

    wcli registration new > /dev/null 2>&1
    if ! wait_for_registration_local; then
        echo "❌ 注册失败"
        finish_configuration
        return 1
    fi

    if ! wcli registration license "$license_key" > /dev/null 2>&1; then
        echo "❌ License 应用失败"
        finish_configuration
        return 1
    fi
    sleep 2
    if [ "$(get_account_type_local)" != "WARP+" ]; then
        echo "❌ License 未生效"
        finish_configuration
        return 1
    fi

    wcli mode warp+doh > /dev/null 2>&1
    sleep 1
    wcli connect > /dev/null 2>&1
    echo -n "⏳ 正在连接（最长等待 3 分钟）..."
    if wait_for_connected_local 60; then
        echo ""
        echo "✅ 实例 ${CURRENT_INSTANCE_ID} WARP+ 连接成功"
        show_status_one
    else
        echo ""
        echo "❌ WARP+ 连接失败"
        finish_configuration
        return 1
    fi
    finish_configuration
}

show_status_one() {
    echo ""
    echo "========================================"
    echo "  📊 实例 ${CURRENT_INSTANCE_ID} 状态  端口:$(instance_port "${CURRENT_INSTANCE_ID}")"
    echo "========================================"
    wcli status 2>/dev/null || echo "(无法获取 status)"
    echo ""
    local reg_info
    reg_info=$(wcli registration show 2>/dev/null)
    if echo "$reg_info" | grep -q "Organization"; then
        echo "👥 账户类型: Teams (Zero Trust)"
    elif echo "$reg_info" | grep -qE "Premium|Unlimited|WARP[+]"; then
        echo "💎 账户类型: WARP+"
    elif echo "$reg_info" | grep -q "Device ID"; then
        echo "📡 账户类型: WARP 免费版"
    else
        echo "⭕ 账户类型: 未配置"
    fi
    echo "📂 数据目录: $(instance_data_dir "${CURRENT_INSTANCE_ID}")"
    echo "========================================"
}

show_status() {
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        set_instance_context 0
        show_status_one
    else
        local id
        for id in $(instance_id_list); do
            set_instance_context "$id"
            show_status_one
        done
    fi
    echo ""
    if lb_should_enable; then
        /usr/local/bin/lb-setup.sh status 2>/dev/null || true
    fi
    /usr/local/bin/instance-ctl.sh status 2>/dev/null || true
}

reset_config() {
    echo "🔄 正在重置配置 (实例 ${CURRENT_INSTANCE_ID})..."
    if ! check_warp_svc; then
        return 1
    fi
    read -r -p "确认重置实例 ${CURRENT_INSTANCE_ID}？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "↩️ 已取消"
        return 0
    fi
    begin_configuration || return 1
    log "重置配置 instance=${CURRENT_INSTANCE_ID}"
    wcli disconnect > /dev/null 2>&1 || true
    sleep 2
    wcli registration delete > /dev/null 2>&1 || true
    sleep 2
    echo "✅ 实例 ${CURRENT_INSTANCE_ID} 配置已重置"
    finish_configuration
}

pushdeer_menu() {
    local pushkey_file="${WARP_DATA_ROOT}/pushdeer.key"

    while true; do
        clear
        echo ""
        echo "========================================"
        echo "       🔔 PushDeer 断线通知"
        echo "========================================"
        echo ""
        local current_key=""
        if [ -f "$pushkey_file" ]; then
            current_key=$(cat "$pushkey_file" 2>/dev/null)
            echo "  ✅ 状态: 已启用"
            echo "  Key:  ${current_key:0:8}..."
        else
            echo "  ⭕ 状态: 未启用"
        fi
        echo ""
        echo "1) 设置 / 更新 PushKey"
        echo "2) 测试推送通知"
        echo "3) 关闭通知"
        echo "0) 返回主菜单"
        echo ""
        echo "========================================"
        read -r -p "请选择 [0-3]: " choice

        case $choice in
            1)
                echo ""
                read -r -p "请输入 PushDeer PushKey: " new_key
                if [ -n "$new_key" ]; then
                    echo "$new_key" > "$pushkey_file"
                    echo "📥 PushKey 已保存。"
                    curl -s --max-time 10 --get \
                        --data-urlencode "pushkey=${new_key}" \
                        --data-urlencode "text=vh-warp 已就绪" \
                        --data-urlencode "desp=PushDeer 通知已成功配置！" \
                        "https://api2.pushdeer.com/message/push" > /dev/null 2>&1
                    echo "📨 测试通知已发送！"
                    log "PushDeer 已配置"
                fi
                read -r -p "按回车键继续..."
                ;;
            2)
                if [ ! -f "$pushkey_file" ]; then
                    echo ""
                    echo "⚠️ 尚未配置 PushKey，请先设置。"
                else
                    local key
                    key=$(cat "$pushkey_file")
                    curl -s --max-time 10 --get \
                        --data-urlencode "pushkey=${key}" \
                        --data-urlencode "text=测试通知" \
                        --data-urlencode "desp=PushDeer 工作正常" \
                        "https://api2.pushdeer.com/message/push" > /dev/null 2>&1
                    echo "📨 测试通知已发送！"
                fi
                read -r -p "按回车键继续..."
                ;;
            3)
                echo ""
                read -r -p "确认关闭 PushDeer 通知？(y/n): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    rm -f "$pushkey_file"
                    echo "🔕 PushDeer 通知已关闭。"
                    log "PushDeer 已关闭"
                else
                    echo "↩️ 已取消"
                fi
                read -r -p "按回车键继续..."
                ;;
            0) return ;;
            *) echo "⚠️ 无效选择"; sleep 1 ;;
        esac
    done
}

show_banner() {
    local current_time
    current_time=$(date +'%Y-%m-%d %H:%M:%S')
    clear
    echo ""
    echo "  ██╗   ██╗██╗  ██╗       ██╗    ██╗ █████╗ ██████╗ ██████╗ "
    echo "  ██║   ██║██║  ██║       ██║    ██║██╔══██╗██╔══██╗██╔══██╗"
    echo "  ██║   ██║███████║       ██║ █╗ ██║███████║██████╔╝██████╔╝"
    echo "  ╚██╗ ██╔╝██╔══██║       ██║███╗██║██╔══██║██╔══██╗██╔═══╝ "
    echo "   ╚████╔╝ ██║  ██║       ╚███╔███╔╝██║  ██║██║  ██║██║     "
    echo "    ╚═══╝  ╚═╝  ╚═╝        ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     "
    echo ""
    echo "  ─────────────────────────────────────────────────────────"
    echo "    ☁️  Cloudflare WARP 隐私保护 · 网络加速"
    echo "    📂 github.com/lazzman/vh-warp    🕐 $current_time"
    echo "    🔢 实例: ${INSTANCE_COUNT}  端口: ${BASE_PORT}-$((BASE_PORT + INSTANCE_COUNT - 1))  LB: ${LB_PORT}"
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
}

str_visual_width() {
    local str="$1"
    local chars=${#str}
    local bytes
    bytes=$(echo -n "$str" | wc -c)
    echo $(((chars + bytes) / 2))
}

show_menu() {
    show_banner
    local box_w=48

    menu_line() {
        local text="$1"
        local w
        w=$(str_visual_width "$text")
        local pad=$((box_w - 4 - w))
        local spaces
        spaces=$(printf '%*s' "$pad" '')
        echo "  |  ${text}${spaces} |"
    }

    draw_line() {
        local c="$1" l="$2" r="$3"
        local n=$((box_w - 3))
        local line
        line=$(printf '%*s' "$n" '' | tr ' ' "$c")
        echo "  ${l}${line}${r}"
    }

    draw_line "=" "+" "+"
    menu_line "vh-warp 配置工具"
    draw_line "=" "+" "+"
    menu_line "1)  WARP 免费版       MASQUE 协议，无需账号"
    menu_line "2)  Teams / Zero Trust  输入 Token URL"
    menu_line "3)  WARP+ (License Key)  输入 License Key"
    menu_line "4)  查看当前状态"
    menu_line "5)  重置并清理配置"
    menu_line "6)  PushDeer 断线通知"
    menu_line "0)  退出"
    draw_line "=" "+" "+"
    echo ""
}

main() {
    while true; do
        show_menu
        read -r -p "  请选择 [0-6]: " choice

        case $choice in
            1)
                select_instance || continue
                run_on_instances configure_free
                ;;
            2)
                select_instance || continue
                run_on_instances configure_teams
                ;;
            3)
                select_instance || continue
                run_on_instances configure_plus
                ;;
            4) show_status ;;
            5)
                select_instance || continue
                run_on_instances reset_config
                ;;
            6) pushdeer_menu ;;
            0)
                echo "👋 再见！"
                exit 0
                ;;
            *)
                echo "⚠️ 无效选择，请重新输入"
                sleep 1
                ;;
        esac
        read -r -p "按回车键继续..."
    done
}

main
