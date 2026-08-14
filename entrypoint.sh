#!/bin/bash

LOG_DIR="/var/log/warp-gost"
LOG_FILE="$LOG_DIR/entrypoint.log"

source /usr/local/bin/warp-common.sh

mkdir -p "$LOG_DIR" "$WARP_RUN_ROOT" "$WARP_LOCK_ROOT"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "🚀 vh-warp 容器启动中..."
log "   INSTANCE_COUNT=${INSTANCE_COUNT} BASE_PORT=${BASE_PORT} LB_PORT=${LB_PORT} LB_STRATEGY=${LB_STRATEGY} LB_ROTATE_INTERVAL=${LB_ROTATE_INTERVAL}"
if upstream_configured; then
    # 日志脱敏：去掉可能的密码
    _us_log="${UPSTREAM_SOCKS5}"
    _us_log="${_us_log//:*@/:***@}"
    log "   UPSTREAM_SOCKS5=${_us_log} udp=${UPSTREAM_SOCKS5_UDP} mtu=${UPSTREAM_MTU}"
else
    log "   UPSTREAM_SOCKS5=(未配置，WARP 直连出网)"
fi

if prefer_ipv6_enabled; then
    log "🌐 PREFER_IPV6=1，GOST 双栈出站优先 AAAA（纯 IPv4 仍通，不重启）"
fi

ln -sf /usr/local/bin/vhwarp.sh /usr/bin/vhwarp 2>/dev/null
ln -sf /usr/local/bin/gost-setup.sh /usr/bin/gost-setup 2>/dev/null
ln -sf /usr/local/bin/log-monitor.sh /usr/bin/log-monitor 2>/dev/null
ln -sf /usr/local/bin/health-check.sh /usr/bin/health-check 2>/dev/null
ln -sf /usr/local/bin/instance-ctl.sh /usr/bin/instance-ctl 2>/dev/null
ln -sf /usr/local/bin/lb-setup.sh /usr/bin/lb-setup 2>/dev/null
ln -sf /usr/local/bin/upstream-setup.sh /usr/bin/upstream-setup 2>/dev/null
ln -sf /usr/local/bin/rotate-restart.sh /usr/bin/rotate-restart 2>/dev/null

ensure_runtime_dirs

# TUN（单实例主机侧；多实例在各 netns 内再确保）
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 >> "$LOG_FILE" 2>&1 || true
fi
if [ -c /dev/net/tun ]; then
    chmod 600 /dev/net/tun
    log "🔌 TUN 设备已就绪"
else
    log "⚠️ TUN 设备不可用，WARP 无法建立隧道，代理将暂时使用直连"
fi

# 启动全部实例
log "⏳ 正在启动 ${INSTANCE_COUNT} 个实例..."
/usr/local/bin/instance-ctl.sh start-all >> "$LOG_FILE" 2>&1
log "✅ 实例启动流程完成"

# 负载均衡（先起 LB，再探针，避免只看直连）
if lb_should_enable; then
    log "⚖️ 启动负载均衡 :${LB_PORT} strategy=${LB_STRATEGY}"
    /usr/local/bin/lb-setup.sh start >> "$LOG_FILE" 2>&1 || log "⚠️ LB 启动失败"
else
    log "ℹ️ 负载均衡未启用（单实例或 LB_ENABLED=0）"
fi

log "📋 正在启动日志监控..."
/usr/local/bin/log-monitor.sh > /dev/null 2>&1 &

log "🩺 正在启动健康检测..."
# 健康检测仅在就绪状态变化时输出 stdout；转发到 Docker 控制台并保留在 entrypoint.log。
/usr/local/bin/health-check.sh > >(tee -a "$LOG_FILE") 2>&1 &

if rotate_restart_enabled; then
    log "🔄 正在启动定时滚动重启: interval=${ROTATE_RESTART_INTERVAL} drain=${ROTATE_RESTART_DRAIN_TIMEOUT} retries=${ROTATE_RESTART_RETRIES} probe=${ROTATE_RESTART_PROBE_TIMEOUT}s"
else
    log "ℹ️ 定时滚动重启待命（未启用：ENABLED=${ROTATE_RESTART_ENABLED} count=${INSTANCE_COUNT}）"
fi
/usr/local/bin/rotate-restart.sh daemon > >(tee -a "$LOG_FILE") 2>&1 &

# 等代理初步就绪后打印各实例真实状态。WARP 注册 / MASQUE 建连仍可能在后台进行。
log "🔎 并行探测各实例 WARP 就绪状态..."
sleep 3

# 打印访问信息 + 每实例出口
LAST_PORT=$((BASE_PORT + INSTANCE_COUNT - 1))
echo ""
echo "========================================"
echo "  🥝 vh-warp Cloudflare WARP"
echo "  实例数: ${INSTANCE_COUNT}"
echo ""
if lb_should_enable; then
    echo "  ⚖️  负载均衡入口: 主机IP:${LB_PORT}"
    echo "     策略: ${LB_STRATEGY} (round|random|hash|rotate)"
    if [ "${LB_STRATEGY,,}" = "rotate" ]; then
        echo "     定时轮换: 每 ${LB_ROTATE_INTERVAL} 切换到下一个健康实例"
    fi
    echo "     粘性: socks5h://{id}@主机IP:${LB_PORT}"
    echo "           同一 id 固定到同一后端实例"
    echo ""
fi
if [ "$INSTANCE_COUNT" -eq 1 ]; then
    echo "  🌐 实例直连: 主机IP:${BASE_PORT}  (SOCKS5/HTTP Mixed)"
else
    echo "  🌐 实例直连: 主机IP:${BASE_PORT}-${LAST_PORT}"
fi
echo ""
echo "  📡 各实例 WARP 就绪状态:"
echo "     ✅ 已就绪   ⏳ 建连中   ⚠️ 直连/探测失败   ❌ 服务未就绪"

# 每个实例的 trace 探测最多会访问两个端点；并行执行，避免 10+ 实例串行超时让横幅滞后。
status_tmp_dir="$(mktemp -d)"
declare -a status_probe_pids
for id in $(instance_id_list); do
    (
        instance_info_line "$id" > "${status_tmp_dir}/${id}" 2>&1 || \
            echo "instance-${id} readiness=probe_failed trace=failed error=status_command_failed"
    ) &
    status_probe_pids[$id]=$!
done

ready_count=0
waiting_count=0
direct_count=0
probe_failed_count=0
service_down_count=0
for id in $(instance_id_list); do
    wait "${status_probe_pids[$id]}" 2>/dev/null || true
    line="$(cat "${status_tmp_dir}/${id}" 2>/dev/null || echo "instance-${id} readiness=probe_failed trace=failed error=status_output_missing")"
    console_line="$(format_instance_info_line "$line")"
    echo "     ${console_line}"
    echo "     状态详情: ${line}" >> "$LOG_FILE"
    case "$line" in
        *"readiness=ready"*) ready_count=$((ready_count + 1)) ;;
        *"readiness=waiting"*) waiting_count=$((waiting_count + 1)) ;;
        *"readiness=direct"*) direct_count=$((direct_count + 1)) ;;
        *"readiness=service_down"*) service_down_count=$((service_down_count + 1)) ;;
        *) probe_failed_count=$((probe_failed_count + 1)) ;;
    esac
done
rm -rf "$status_tmp_dir"
echo ""
echo "  ✅ 就绪汇总: ready=${ready_count} waiting=${waiting_count} direct=${direct_count} probe_failed=${probe_failed_count} service_down=${service_down_count}"
echo "     仅 readiness=ready（warp=on/plus）代表已确认的 WARP 出口；健康检测会继续重试其它实例。"
echo ""
echo "  📝 查看/刷新出口:"
echo "     docker exec -it <容器> instance-ctl status"
echo "     docker exec -it <容器> vhwarp"
if [ "$INSTANCE_COUNT" -gt 1 ]; then
    echo "     docker exec -it <容器> vhwarp -i <实例ID>"
fi
if rotate_restart_enabled; then
    echo "  🔄 定时滚动重启: 每 ${ROTATE_RESTART_INTERVAL} 串行硬重启（排空最多 ${ROTATE_RESTART_DRAIN_TIMEOUT}；探针成功后下一台）"
    echo "     docker exec -it <容器> rotate-restart status"
fi
echo "========================================"
echo ""

# 再打一份完整 status 到日志
/usr/local/bin/instance-ctl.sh status >> "$LOG_FILE" 2>&1 || true

log "✅ 日志监控已启动"
log "✅ 健康检测已启动"
if rotate_restart_enabled; then
    log "✅ 定时滚动重启已启动"
fi

# 保持前台：优先跟随单实例 warp-svc；多实例跟随 instance outer 进程
cleanup() {
    log "🛑 收到退出信号，清理..."
    /usr/local/bin/lb-setup.sh stop >/dev/null 2>&1 || true
    /usr/local/bin/instance-ctl.sh stop-all >/dev/null 2>&1 || true
    exit 0
}
trap cleanup SIGTERM SIGINT

if [ "$INSTANCE_COUNT" -eq 1 ]; then
    # 等待 warp-svc
    WARP_PID_FILE="$(instance_run_dir 0)/warp-svc.pid"
    for _ in $(seq 1 30); do
        [ -f "$WARP_PID_FILE" ] && break
        sleep 1
    done
    if [ -f "$WARP_PID_FILE" ]; then
        WARP_PID=$(cat "$WARP_PID_FILE")
        while kill -0 "$WARP_PID" 2>/dev/null; do
            sleep 5
            # warp-svc 被杀时尝试拉起
            if ! kill -0 "$WARP_PID" 2>/dev/null; then
                if instance_rotate_in_progress 0; then
                    continue
                fi
                log "⚠️ warp-svc 退出，尝试重启单实例..."
                /usr/local/bin/instance-ctl.sh start 0 >> "$LOG_FILE" 2>&1 || true
                [ -f "$WARP_PID_FILE" ] && WARP_PID=$(cat "$WARP_PID_FILE")
            fi
        done
    fi
    # 兜底前台
    while true; do sleep 3600; done
else
    # 多实例：监控 outer pid，挂了则重启对应实例
    while true; do
        for id in $(instance_id_list); do
            opid_file="$(instance_run_dir "$id")/outer.pid"
            if instance_rotate_in_progress "$id"; then
                continue
            fi
            if [ -f "$opid_file" ]; then
                if ! kill -0 "$(cat "$opid_file")" 2>/dev/null; then
                    log "⚠️ 实例 ${id} supervisor 退出，正在重启..."
                    /usr/local/bin/instance-ctl.sh start "$id" >> "$LOG_FILE" 2>&1 || true
                fi
            fi
            fpid_file="$(instance_run_dir "$id")/forward.pid"
            if [ -f "$fpid_file" ]; then
                if ! kill -0 "$(cat "$fpid_file")" 2>/dev/null; then
                    log "⚠️ 实例 ${id} 端口转发退出，正在拉起..."
                    # 复用 instance-ctl 的 start 会重建 netns，过重；仅重启 forward
                    ns_ip="$(instance_ns_ip "$id")"
                    port="$(instance_port "$id")"
                    log_dir="$(instance_log_dir "$id")"
                    gost -L "mixed://0.0.0.0:${port}?$(gost_forward_query)" \
                         -F "mixed://${ns_ip}:${INSTANCE_GOST_PORT}" \
                         >>"${log_dir}/forward.log" 2>&1 &
                    echo $! > "$fpid_file"
                fi
            fi
        done
        # LB 保活
        if lb_should_enable; then
            lb_pid_file="${WARP_RUN_ROOT}/lb.pid"
            if [ ! -f "$lb_pid_file" ] || ! kill -0 "$(cat "$lb_pid_file")" 2>/dev/null; then
                log "⚠️ LB 未运行，尝试重启..."
                /usr/local/bin/lb-setup.sh start >> "$LOG_FILE" 2>&1 || true
            fi
        fi
        sleep 10
    done
fi
