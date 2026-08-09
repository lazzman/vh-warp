#!/bin/bash
# 多实例生命周期：网络命名空间隔离 + 每实例独立 warp-svc / gost / 数据目录

set -uo pipefail

source /usr/local/bin/warp-common.sh

log() {
    local id="${CURRENT_INSTANCE_ID:-?}"
    local dir
    dir="$(instance_log_dir "${CURRENT_INSTANCE_ID:-0}")"
    mkdir -p "$dir"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [instance-${id}] $1" | tee -a "$dir/instance.log" >> "${WARP_LOG_ROOT}/entrypoint.log" 2>/dev/null || \
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [instance-${id}] $1"
}

# ── 网络命名空间 ───────────────────────────────────────────────────────
setup_netns() {
    local id="$1"
    local ns veth_h veth_n host_ip ns_ip

    ns="$(instance_netns "$id")"
    veth_h="$(instance_veth_host "$id")"
    veth_n="$(instance_veth_ns "$id")"
    host_ip="$(instance_host_ip "$id")"
    ns_ip="$(instance_ns_ip "$id")"

    # 清理残留
    ip netns del "$ns" 2>/dev/null || true
    ip link del "$veth_h" 2>/dev/null || true

    ip netns add "$ns"
    ip link add "$veth_h" type veth peer name "$veth_n"
    ip link set "$veth_n" netns "$ns"

    ip addr add "${host_ip}/30" dev "$veth_h"
    ip link set "$veth_h" up

    ip netns exec "$ns" ip addr add "${ns_ip}/30" dev "$veth_n"
    ip netns exec "$ns" ip link set "$veth_n" up
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip route add default via "$host_ip"

    # 允许 netns 访问外网（WARP 注册 / 握手）
    if ! iptables -t nat -C POSTROUTING -s "${NETNS_PREFIX}.${id}.0/30" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "${NETNS_PREFIX}.${id}.0/30" -j MASQUERADE 2>/dev/null || \
        nft add rule ip nat postrouting ip saddr "${NETNS_PREFIX}.${id}.0/30" masquerade 2>/dev/null || true
    fi

    # 转发
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    log "网络命名空间 ${ns} 已就绪 (${host_ip} ↔ ${ns_ip})"
}

teardown_netns() {
    local id="$1"
    local ns veth_h
    ns="$(instance_netns "$id")"
    veth_h="$(instance_veth_host "$id")"
    ip netns del "$ns" 2>/dev/null || true
    ip link del "$veth_h" 2>/dev/null || true
}

# 在 netns 内准备 mount 隔离的数据/运行目录，再启动进程
# 通过一个常驻 "supervisor" 脚本在 netns+mount 中运行
instance_supervisor_script() {
    local id="$1"
    local data_dir run_dir log_dir ns_ip
    data_dir="$(instance_data_dir "$id")"
    run_dir="$(instance_run_dir "$id")"
    log_dir="$(instance_log_dir "$id")"
    ns_ip="$(instance_ns_ip "$id")"

    cat <<EOF
#!/bin/bash
set -e
DATA_DIR="${data_dir}"
RUN_DIR="${run_dir}"
LOG_DIR="${log_dir}"
NS_IP="${ns_ip}"
GOST_PORT="${INSTANCE_GOST_PORT}"
GOST_OPTS="$(gost_listen_query)"

mkdir -p "\$LOG_DIR" "\$RUN_DIR" "\$DATA_DIR"

# 先把宿主 RUN_DIR bind 到稳定路径，后续 remount /run 或数据目录也不丢失
mkdir -p /host-instance-run
mount --bind "\$RUN_DIR" /host-instance-run

# 私有 /run，避免多实例 dbus / warp socket 互相踩踏
mount -t tmpfs tmpfs /run
mkdir -p /run/cloudflare-warp /run/dbus /run/lock

# 数据目录隔离（WARP 状态）；不影响 /host-instance-run 绑定
mkdir -p /var/lib/cloudflare-warp
mount --bind "\$DATA_DIR" /var/lib/cloudflare-warp

# 每实例独立 system dbus
dbus-daemon --system --fork 2>>"\$LOG_DIR/dbus.log" || true
sleep 1

# TUN（字符设备跨 netns 复用，open 后 iface 属于当前 netns）
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
fi

echo \$\$ > /host-instance-run/supervisor.pid

# 可选：上游 SOCKS5 TUN（WARP 建连走节点）
export UPSTREAM_SOCKS5="${UPSTREAM_SOCKS5:-}"
export UPSTREAM_SOCKS5_UDP="${UPSTREAM_SOCKS5_UDP:-udp}"
export UPSTREAM_MTU="${UPSTREAM_MTU:-1280}"
export UPSTREAM_TUN_PREFIX="${UPSTREAM_TUN_PREFIX:-ups}"
export INSTANCE_COUNT="${INSTANCE_COUNT}"
export CURRENT_INSTANCE_ID="${id}"
if [ -n "\${UPSTREAM_SOCKS5}" ] && [ -x /usr/local/bin/upstream-setup.sh ]; then
    /usr/local/bin/upstream-setup.sh start ${id} >>"\$LOG_DIR/upstream.log" 2>&1 || \
        echo "[supervisor] upstream start failed" >>"\$LOG_DIR/upstream.log"
fi

# 启动 warp-svc
warp-svc >>"\$LOG_DIR/warp-svc.log" 2>&1 &
echo \$! > /host-instance-run/warp-svc.pid

# 等待 warp-cli
for i in \$(seq 1 90); do
    if warp-cli --accept-tos status >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# 自动注册 Free（若无注册）
if ! warp-cli --accept-tos registration show 2>/dev/null | grep -q "Device ID"; then
    warp-cli --accept-tos tunnel protocol set MASQUE >>"\$LOG_DIR/warp-svc.log" 2>&1 || true
    warp-cli --accept-tos registration new >>"\$LOG_DIR/warp-svc.log" 2>&1 || true
    for i in \$(seq 1 30); do
        warp-cli --accept-tos registration show 2>/dev/null | grep -q "Device ID" && break
        sleep 2
    done
fi

if warp-cli --accept-tos registration show 2>/dev/null | grep -q "Device ID"; then
    warp-cli --accept-tos mode warp+doh >>"\$LOG_DIR/warp-svc.log" 2>&1 || true
    warp-cli --accept-tos connect >>"\$LOG_DIR/warp-svc.log" 2>&1 || true
    # WARP 改路由后重钉节点直连，避免环路
    if [ -n "\${UPSTREAM_SOCKS5}" ] && [ -x /usr/local/bin/upstream-setup.sh ]; then
        /usr/local/bin/upstream-setup.sh pin ${id} >>"\$LOG_DIR/upstream.log" 2>&1 || true
    fi
fi

# 启动实例内 GOST（监听 netns 内全接口）
gost -L "mixed://0.0.0.0:\${GOST_PORT}?\${GOST_OPTS}" >>"\$LOG_DIR/gost.log" 2>&1 &
echo \$! > /host-instance-run/gost.pid

# 保活
while true; do
    if [ -f /host-instance-run/warp-svc.pid ]; then
        wpid=\$(cat /host-instance-run/warp-svc.pid)
        if ! kill -0 "\$wpid" 2>/dev/null; then
            warp-svc >>"\$LOG_DIR/warp-svc.log" 2>&1 &
            echo \$! > /host-instance-run/warp-svc.pid
        fi
    fi
    if [ -f /host-instance-run/gost.pid ]; then
        gpid=\$(cat /host-instance-run/gost.pid)
        if ! kill -0 "\$gpid" 2>/dev/null; then
            gost -L "mixed://0.0.0.0:\${GOST_PORT}?\${GOST_OPTS}" >>"\$LOG_DIR/gost.log" 2>&1 &
            echo \$! > /host-instance-run/gost.pid
        fi
    fi
    # 上游 hev 保活 + 周期 pin
    if [ -n "\${UPSTREAM_SOCKS5}" ] && [ -x /usr/local/bin/upstream-setup.sh ]; then
        /usr/local/bin/upstream-setup.sh pin ${id} >>"\$LOG_DIR/upstream.log" 2>&1 || true
    fi
    sleep 5
done
EOF
}

start_instance_multi() {
    local id="$1"
    set_instance_context "$id"
    local run_dir log_dir script_path ns
    run_dir="$(instance_run_dir "$id")"
    log_dir="$(instance_log_dir "$id")"
    ns="$(instance_netns "$id")"
    script_path="${run_dir}/supervisor.sh"

    mkdir -p "$run_dir" "$log_dir" "$(instance_data_dir "$id")"
    setup_netns "$id"

    instance_supervisor_script "$id" > "$script_path"
    chmod +x "$script_path"

    # unshare --mount 进入独立 mount ns，再在目标 netns 中运行
    # 顺序：先 netns，再 unshare mount
    ip netns exec "$ns" unshare --mount --propagation private /bin/bash "$script_path" \
        >>"$log_dir/supervisor.out" 2>&1 &
    echo $! > "${run_dir}/outer.pid"

    log "多实例模式已启动 (netns=${ns}, data=$(instance_data_dir "$id"), port=$(instance_port "$id"))"

    # 等待内部 GOST 就绪
    local ip
    ip="$(instance_ns_ip "$id")"
    local i
    for i in $(seq 1 30); do
        if ip netns exec "$ns" bash -c "ss -lnt 2>/dev/null | grep -q ':${INSTANCE_GOST_PORT} '" 2>/dev/null; then
            log "实例内 GOST 已监听 :${INSTANCE_GOST_PORT}"
            break
        fi
        sleep 1
    done

    # 主机侧端口转发：BASE_PORT+id → ns_ip:1080 （TCP+UDP mixed 由 gost 转发更稳）
    start_port_forward "$id"
}

start_port_forward() {
    local id="$1"
    local port ns_ip run_dir log_dir
    port="$(instance_port "$id")"
    ns_ip="$(instance_ns_ip "$id")"
    run_dir="$(instance_run_dir "$id")"
    log_dir="$(instance_log_dir "$id")"

    # 停旧转发
    if [ -f "${run_dir}/forward.pid" ]; then
        kill "$(cat "${run_dir}/forward.pid")" 2>/dev/null || true
        rm -f "${run_dir}/forward.pid"
    fi

    # 用 gost 做 mixed 端口转发（支持 TCP；UDP 关联走链路）
    gost -L "mixed://0.0.0.0:${port}?$(gost_forward_query)" \
         -F "mixed://${ns_ip}:${INSTANCE_GOST_PORT}" \
         >>"${log_dir}/forward.log" 2>&1 &
    echo $! > "${run_dir}/forward.pid"
    log "端口转发 0.0.0.0:${port} → ${ns_ip}:${INSTANCE_GOST_PORT}"
}

stop_port_forward() {
    local id="$1"
    local run_dir
    run_dir="$(instance_run_dir "$id")"
    if [ -f "${run_dir}/forward.pid" ]; then
        kill "$(cat "${run_dir}/forward.pid")" 2>/dev/null || true
        rm -f "${run_dir}/forward.pid"
    fi
}

stop_instance_multi() {
    local id="$1"
    set_instance_context "$id"
    local run_dir
    run_dir="$(instance_run_dir "$id")"

    stop_port_forward "$id"
    # supervisor 退出时会清 hev；此处再兜底
    upstream_stop_for "$id" 2>/dev/null || true

    if [ -f "${run_dir}/outer.pid" ]; then
        local opid
        opid=$(cat "${run_dir}/outer.pid")
        # 杀掉整个进程树
        kill "$opid" 2>/dev/null || true
        # netns 内进程
        local ns
        ns="$(instance_netns "$id")"
        ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
        sleep 1
        ip netns pids "$ns" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
        rm -f "${run_dir}/outer.pid"
    fi
    teardown_netns "$id"
    log "实例已停止"
}

# ── 单实例（兼容模式，无 netns）────────────────────────────────────────
start_instance_single() {
    local id=0
    set_instance_context "$id"
    local log_dir
    log_dir="$(instance_log_dir 0)"
    mkdir -p "$log_dir" /run/cloudflare-warp

    if [ ! -e /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
    fi
    if [ -c /dev/net/tun ]; then
        chmod 600 /dev/net/tun
    fi

    if ! pgrep -x "dbus-daemon" > /dev/null 2>&1; then
        mkdir -p /var/run/dbus
        dbus-daemon --system --fork 2>/dev/null || true
        sleep 1
    fi

    # 上游 SOCKS5 TUN（在 warp 之前）
    if upstream_configured; then
        log "启用上游 SOCKS5 TUN..."
        if /usr/local/bin/upstream-setup.sh start 0; then
            log "上游 SOCKS5 TUN 已启动"
        else
            log "⚠️ 上游 SOCKS5 TUN 启动失败，WARP 将尝试直连"
        fi
    fi

    if ! pgrep -x "warp-svc" > /dev/null 2>&1; then
        log "启动 warp-svc..."
        warp-svc >>"${log_dir}/warp-svc.log" 2>&1 &
        echo $! > "$(instance_run_dir 0)/warp-svc.pid"
        local attempt=1
        while [ $attempt -le 5 ]; do
            sleep 5
            if kill -0 "$(cat "$(instance_run_dir 0)/warp-svc.pid")" 2>/dev/null; then
                log "warp-svc 启动成功"
                break
            fi
            warp-svc >>"${log_dir}/warp-svc.log" 2>&1 &
            echo $! > "$(instance_run_dir 0)/warp-svc.pid"
            attempt=$((attempt + 1))
        done
    fi

    if wait_for_warp_cli "${WARP_CLI_TIMEOUT}"; then
        log "warp-cli 已就绪"
        if ! is_warp_connected; then
            if acquire_warp_lock 30; then
                if ! has_registration; then
                    log "自动注册 Free..."
                    warp_cli_cmd tunnel protocol set MASQUE >>"${log_dir}/warp-svc.log" 2>&1 || true
                    warp_cli_cmd registration new >>"${log_dir}/warp-svc.log" 2>&1 || true
                    wait_for_registration "${WARP_REGISTRATION_TIMEOUT}" || log "注册超时"
                fi
                if has_registration; then
                    warp_cli_cmd mode warp+doh >>"${log_dir}/warp-svc.log" 2>&1 || true
                    local a
                    for a in 1 2 3; do
                        warp_cli_cmd connect >>"${log_dir}/warp-svc.log" 2>&1 || true
                        if wait_for_connected 60; then
                            log "WARP 已连接"
                            upstream_configured && /usr/local/bin/upstream-setup.sh pin 0 || true
                            break
                        fi
                        warp_cli_cmd disconnect >>"${log_dir}/warp-svc.log" 2>&1 || true
                        sleep $((a * 5))
                    done
                fi
                release_warp_lock
            fi
        else
            log "WARP 已连接"
            upstream_configured && /usr/local/bin/upstream-setup.sh pin 0 || true
        fi
    else
        log "warp-cli 未就绪，稍后由健康检查重试"
    fi

    /usr/local/bin/gost-setup.sh start 0
}

stop_instance_single() {
    set_instance_context 0
    /usr/local/bin/gost-setup.sh stop 0
    if [ -f "$(instance_run_dir 0)/warp-svc.pid" ]; then
        kill "$(cat "$(instance_run_dir 0)/warp-svc.pid")" 2>/dev/null || true
    fi
    pkill -x warp-svc 2>/dev/null || true
    upstream_stop_for 0
}

# ── 对外接口 ──────────────────────────────────────────────────────────
start_instance() {
    local id="${1:-0}"
    ensure_runtime_dirs
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        start_instance_single
    else
        start_instance_multi "$id"
    fi
}

stop_instance() {
    local id="${1:-0}"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        stop_instance_single
    else
        stop_instance_multi "$id"
    fi
}

start_all() {
    ensure_runtime_dirs
    local id
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        start_instance 0
    else
        # 依赖 iptables
        if ! command -v iptables >/dev/null 2>&1; then
            log "警告: 未找到 iptables，尝试仅用 nft"
        fi
        for id in $(instance_id_list); do
            start_instance_multi "$id" || log "实例 ${id} 启动失败"
        done
    fi
    write_backends_file
    # 初始化健康标记
    for id in $(instance_id_list); do
        update_backend_health "$id" "up"
    done
}

stop_all() {
    local id
    for id in $(instance_id_list); do
        stop_instance "$id" || true
    done
}

status_all() {
    local id detail="${1:-}"
    echo "INSTANCE_COUNT=${INSTANCE_COUNT} BASE_PORT=${BASE_PORT} LB_PORT=${LB_PORT} LB_STRATEGY=${LB_STRATEGY}"
    if upstream_configured 2>/dev/null; then
        local _us="${UPSTREAM_SOCKS5//:*@/:***@}"
        echo "UPSTREAM_SOCKS5=${_us}"
    fi
    echo "──── 实例一览（含 WARP 出口）────"
    for id in $(instance_id_list); do
        # 默认输出出口 IP 等；STATUS_QUICK=1 时只看进程
        if [ "${STATUS_QUICK:-0}" = "1" ] && [ "$detail" != "full" ]; then
            local port warp_st gost_st ns
            port="$(instance_port "$id")"
            if [ "$INSTANCE_COUNT" -eq 1 ]; then
                pgrep -x warp-svc >/dev/null 2>&1 && warp_st="up" || warp_st="down"
                pgrep -x gost >/dev/null 2>&1 && gost_st="up" || gost_st="down"
            else
                ns="$(instance_netns "$id")"
                ip netns exec "$ns" pgrep -x warp-svc >/dev/null 2>&1 && warp_st="up" || warp_st="down"
                ip netns exec "$ns" pgrep -x gost >/dev/null 2>&1 && gost_st="up" || gost_st="down"
            fi
            echo "  instance-${id}: port=${port} warp=${warp_st} gost=${gost_st} data=$(instance_data_dir "$id")"
        else
            echo -n "  "
            instance_info_line "$id"
        fi
    done
}

# 在指定实例执行 warp-cli / 任意命令（供 vhwarp / health-check 使用）
# 多实例下进入 netns；注意 mount 隔离后 /var/lib/cloudflare-warp 在 supervisor 的 mount ns 内
# warp-cli 通过 unix socket 通信，socket 在 /run/cloudflare-warp —— 需进入同一 mount ns
# 简化：多实例下 warp-cli 经 ns 执行，并把 RUN_DIR 链到标准路径
exec_in_instance() {
    local id="$1"
    shift
    set_instance_context "$id"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        "$@"
    else
        local ns run_dir
        ns="$(instance_netns "$id")"
        run_dir="$(instance_run_dir "$id")"
        # supervisor 把 RUN_DIR bind 到 netns 内 /run/cloudflare-warp
        # 但那是 unshare --mount 的私有 mount；父 netns 仍看到原 /run
        # 因此通过 nsenter 进入 supervisor 的 mount+net ns
        local spid
        spid=$(cat "${run_dir}/supervisor.pid" 2>/dev/null || true)
        if [ -n "$spid" ] && [ -d "/proc/$spid" ]; then
            nsenter --target "$spid" --mount --net "$@"
        else
            # 回退：仅 netns，并设置可能的 socket 路径
            ip netns exec "$ns" env \
                CLOUDFLARE_WARP_DIR="$(instance_data_dir "$id")" \
                "$@"
        fi
    fi
}

usage() {
    echo "用法: $0 {start|stop|restart|status|start-all|stop-all|exec} [instance_id] [cmd...]"
}

cmd="${1:-}"
shift || true
case "$cmd" in
    start) start_instance "${1:-0}" ;;
    stop) stop_instance "${1:-0}" ;;
    restart)
        stop_instance "${1:-0}"
        sleep 1
        start_instance "${1:-0}"
        ;;
    start-all) start_all ;;
    stop-all) stop_all ;;
    status) status_all ;;
    exec)
        id="${1:-0}"
        shift || true
        exec_in_instance "$id" "$@"
        ;;
    *) usage; exit 1 ;;
esac
