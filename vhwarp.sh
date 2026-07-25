#!/bin/bash

LOG_FILE="/var/log/warp-gost/vhwarp.log"
mkdir -p /var/log/warp-gost

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

check_warp_svc() {
    if ! pgrep -x "warp-svc" > /dev/null; then
        echo "错误: warp-svc 未运行"
        return 1
    fi
    return 0
}

wait_for_connected() {
    local max_attempts=${1:-60}
    local count=0
    while [ $count -lt $max_attempts ]; do
        local status
        status=$(warp-cli --accept-tos status 2>/dev/null)
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

clean_config() {
    log "清理旧配置..."
    warp-cli --accept-tos disconnect > /dev/null 2>&1 || true
    warp-cli --accept-tos registration delete > /dev/null 2>&1 || true
    sleep 1
}

configure_free() {
    echo ""
    echo "正在配置 WARP 免费版..."
    echo "协议: MASQUE"

    if ! check_warp_svc; then
        return 1
    fi

    clean_config
    log "开始配置 WARP Free"

    warp-cli --accept-tos registration new > /dev/null 2>&1
    sleep 2

    warp-cli --accept-tos tunnel protocol set MASQUE > /dev/null 2>&1
    sleep 1

    warp-cli --accept-tos connect > /dev/null 2>&1
    echo -n "正在连接（最长等待 3 分钟）..."
    if wait_for_connected 60; then
        echo ""
        echo "WARP 免费版连接成功 (MASQUE)"
        log "WARP Free 配置成功"
        show_status

        echo ""
        echo "正在启动 GOST 代理..."
        if /usr/local/bin/gost-setup.sh start; then
            echo "GOST 代理已启动，端口: 1111"
        else
            echo "GOST 代理启动失败"
        fi
    else
        echo ""
        echo "WARP 连接失败"
        log "WARP Free 连接失败"
        return 1
    fi
}

configure_teams() {
    echo ""
    echo "正在配置 Teams / Zero Trust..."
    echo "从 https://<团队名>.cloudflareaccess.com/warp 获取 Token URL"

    if ! check_warp_svc; then
        return 1
    fi

    read -p "请输入 Teams Token URL: " token_url

    if [ -z "$token_url" ]; then
        echo "Token URL 不能为空"
        return 1
    fi

    clean_config
    log "开始配置 Teams"

    echo "正在注册 Teams Token..."
    warp-cli --accept-tos registration token "$token_url" > /dev/null 2>&1
    sleep 3

    warp-cli --accept-tos connect > /dev/null 2>&1
    echo -n "正在连接（最长等待 5 分钟）..."
    if wait_for_connected 100; then
        echo ""
        echo "Teams 连接成功"
        log "Teams 配置成功"
        show_status

        echo ""
        echo "正在启动 GOST 代理..."
        if /usr/local/bin/gost-setup.sh start; then
            echo "GOST 代理已启动，端口: 1111"
        else
            echo "GOST 代理启动失败"
        fi
    else
        echo ""
        echo "Teams 连接失败"
        echo ""
        echo "当前状态:"
        warp-cli --accept-tos status
        echo ""
        echo "日志: $LOG_FILE"
        log "Teams 连接失败"
        return 1
    fi
}

configure_plus() {
    echo ""
    echo "正在配置 WARP+..."

    if ! check_warp_svc; then
        return 1
    fi

    read -p "请输入 WARP+ License Key: " license_key

    if [ -z "$license_key" ]; then
        echo "License Key 不能为空"
        return 1
    fi

    clean_config
    log "开始配置 WARP+: $license_key"

    warp-cli --accept-tos registration new > /dev/null 2>&1
    sleep 2

    warp-cli --accept-tos registration license "$license_key"
    sleep 2

    warp-cli --accept-tos connect > /dev/null 2>&1
    echo -n "正在连接（最长等待 3 分钟）..."
    if wait_for_connected 60; then
        echo ""
        echo "WARP+ 连接成功"
        log "WARP+ 配置成功"
        show_status

        echo ""
        echo "正在启动 GOST 代理..."
        if /usr/local/bin/gost-setup.sh start; then
            echo "GOST 代理已启动，端口: 1111"
        else
            echo "GOST 代理启动失败"
        fi
    else
        echo ""
        echo "WARP+ 连接失败"
        log "WARP+ 连接失败"
        return 1
    fi
}

show_status() {
    echo ""
    echo "========================================"
    echo "  当前状态"
    echo "========================================"
    warp-cli --accept-tos status
    echo ""
    local reg_info
    reg_info=$(warp-cli --accept-tos registration show 2>/dev/null)
    if echo "$reg_info" | grep -q "Organization"; then
        echo "账户类型: Teams (Zero Trust)"
    elif echo "$reg_info" | grep -q "Premium"; then
        echo "账户类型: WARP+"
    elif echo "$reg_info" | grep -q "Device ID"; then
        echo "账户类型: WARP 免费版"
    else
        echo "账户类型: 未配置"
    fi
    echo ""
    if pgrep -x "gost" > /dev/null; then
        echo "GOST 代理: 运行中（端口 1111）"
    else
        echo "GOST 代理: 已停止"
    fi
    echo "========================================"
    echo ""
}

reset_config() {
    echo "正在重置配置..."

    if ! check_warp_svc; then
        return 1
    fi

    read -p "确认重置？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消"
        return 0
    fi

    log "重置配置"
    warp-cli --accept-tos disconnect > /dev/null 2>&1 || true
    sleep 2
    warp-cli --accept-tos registration delete > /dev/null 2>&1 || true
    sleep 2

    pkill gost 2>/dev/null || true

    echo "配置已重置"
}

update_cli() {
    echo ""
    echo "正在更新 Cloudflare WARP CLI..."

    echo "当前版本:"
    warp-cli --version 2>/dev/null || echo "未知"

    echo ""
    read -p "检查更新并安装？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消"
        return 0
    fi

    log "更新 cloudflare-warp..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
    apt update 2>/dev/null
    apt install --only-upgrade cloudflare-warp -y 2>&1 | tee -a "$LOG_FILE"

    echo ""
    echo "更新后版本:"
    warp-cli --version 2>/dev/null || echo "未知"

    echo ""
    if pgrep -x "warp-svc" > /dev/null; then
        echo "正在重启 warp-svc..."
        pkill warp-svc 2>/dev/null || true
        sleep 2
        warp-svc >> /var/log/warp-gost/warp-svc.log 2>&1 &
        sleep 3
        if pgrep -x "warp-svc" > /dev/null; then
            echo "warp-svc 已重启"
        else
            echo "warp-svc 重启失败"
        fi
    fi

    log "cloudflare-warp 更新完成"
}

pushdeer_menu() {
    local pushkey_file="/var/lib/cloudflare-warp/pushdeer.key"

    while true; do
        clear
        echo ""
        echo "========================================"
        echo "       PushDeer 断线通知"
        echo "========================================"
        echo ""
        local current_key=""
        if [ -f "$pushkey_file" ]; then
            current_key=$(cat "$pushkey_file" 2>/dev/null)
            echo "  状态: 已启用"
            echo "  Key:  ${current_key:0:8}..."
        else
            echo "  状态: 未启用"
        fi
        echo ""
        echo "1) 设置 / 更新 PushKey"
        echo "2) 测试推送通知"
        echo "3) 关闭通知"
        echo "0) 返回主菜单"
        echo ""
        echo "========================================"
        read -p "请选择 [0-3]: " choice

        case $choice in
            1)
                echo ""
                read -p "请输入 PushDeer PushKey: " new_key
                if [ -n "$new_key" ]; then
                    echo "$new_key" > "$pushkey_file"
                    echo "PushKey 已保存。"
                    echo "正在发送测试通知..."
                    local encoded_title
                    encoded_title=$(echo -n "vh-warp 已就绪" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo "vh-warp")
                    local encoded_body
                    encoded_body=$(echo -n "PushDeer 通知已成功配置！$'\n'从现在开始，WARP 每次断线、重连、急救我都会第一时间告诉你！$'\n'$'\n'祝你网络永不断线！" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo "configured")
                    curl -s --max-time 10 "https://api2.pushdeer.com/message/push?pushkey=${new_key}&text=${encoded_title}&desp=${encoded_body}" > /dev/null 2>&1
                    echo "测试通知已发送！"
                    log "PushDeer 已配置"
                fi
                read -p "按回车键继续..."
                ;;
            2)
                if [ ! -f "$pushkey_file" ]; then
                    echo ""
                    echo "尚未配置 PushKey，请先设置。"
                else
                    echo ""
                    echo "正在发送测试通知..."
                    local key
                    key=$(cat "$pushkey_file")
                    local test_title
                    test_title=$(echo -n "测试通知" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo "test")
                    local test_body
                    test_body=$(echo -n "如果你收到这条消息，说明 PushDeer 工作正常！$'\n'$'\n'vh-warp 断线监控一切就绪！" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo "test ok")
                    curl -s --max-time 10 "https://api2.pushdeer.com/message/push?pushkey=${key}&text=${test_title}&desp=${test_body}" > /dev/null 2>&1
                    echo "测试通知已发送！"
                fi
                read -p "按回车键继续..."
                ;;
            3)
                echo ""
                read -p "确认关闭 PushDeer 通知？(y/n): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    rm -f "$pushkey_file"
                    echo "PushDeer 通知已关闭。"
                    log "PushDeer 已关闭"
                else
                    echo "已取消"
                fi
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择，请重新输入"
                sleep 1
                ;;
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
    echo "    📂 github.com/uxiaohan/vh-warp    🕐 $current_time"
    echo "  ─────────────────────────────────────────────────────────"
    echo ""
    echo "  👋 欢迎使用 vh-warp！隐私保护 + 网络加速一步到位"
    echo "     基于 Cloudflare WARP，支持 Free / Plus / Teams"
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
    menu_line "6)  更新 WARP CLI"
    menu_line "7)  PushDeer 断线通知"
    menu_line "0)  退出"
    draw_line "=" "+" "+"
    echo ""
}

main() {
    while true; do
        show_menu
        read -p "  请选择 [0-7]: " choice

        case $choice in
            1) configure_free ;;
            2) configure_teams ;;
            3) configure_plus ;;
            4) show_status ;;
            5) reset_config ;;
            6) update_cli ;;
            7) pushdeer_menu ;;
            0)
                echo "再见！"
                exit 0
                ;;
            *)
                echo "无效选择，请重新输入"
                sleep 1
                ;;
        esac
        read -p "按回车键继续..."
    done
}

main