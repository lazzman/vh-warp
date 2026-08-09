#!/bin/bash
# 上游 SOCKS5 TUN：容器/netns 默认出站 → hev-socks5-tunnel → SOCKS5 节点
# 供 WARP 注册/MASQUE 建连走节点；业务出口仍是 WARP。
#
# 环境变量:
#   UPSTREAM_SOCKS5=socks5://user:pass@host:port | host:port | user:pass@host:port
#   UPSTREAM_SOCKS5_UDP=udp|tcp   (默认 udp)
#   UPSTREAM_MTU=1280
#   UPSTREAM_TUN_PREFIX=ups       (接口名 ups0 / ups1 …)
#
# 用法（在目标 netns 内，或单实例主机网络）:
#   upstream-setup.sh start [id]
#   upstream-setup.sh stop  [id]
#   upstream-setup.sh pin   [id]   # WARP connect 后重钉路由，防环路
#   upstream-setup.sh status [id]
#   upstream-setup.sh enabled      # 配置了上游则 exit 0

set -uo pipefail

if [ -f /usr/local/bin/warp-common.sh ]; then
    # shellcheck source=/dev/null
    source /usr/local/bin/warp-common.sh
elif [ -f "$(dirname "$0")/warp-common.sh" ]; then
    # shellcheck source=/dev/null
    source "$(dirname "$0")/warp-common.sh"
fi

UPSTREAM_SOCKS5="${UPSTREAM_SOCKS5:-}"
UPSTREAM_SOCKS5_UDP="${UPSTREAM_SOCKS5_UDP:-udp}"
UPSTREAM_MTU="${UPSTREAM_MTU:-1280}"
UPSTREAM_TUN_PREFIX="${UPSTREAM_TUN_PREFIX:-ups}"

CMD="${1:-}"
INSTANCE_ID="${2:-${CURRENT_INSTANCE_ID:-0}}"

log() {
    local dir
    dir="$(instance_log_dir "$INSTANCE_ID" 2>/dev/null || echo /var/log/warp-gost)"
    mkdir -p "$dir" 2>/dev/null || true
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [upstream-${INSTANCE_ID}] $1" | tee -a "${dir}/upstream.log" 2>/dev/null || \
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [upstream-${INSTANCE_ID}] $1"
}

upstream_enabled() {
    [ -n "${UPSTREAM_SOCKS5// /}" ]
}

tun_name() {
    echo "${UPSTREAM_TUN_PREFIX}${INSTANCE_ID}"
}

meta_file() {
    echo "$(instance_run_dir "$INSTANCE_ID")/upstream.meta"
}

pid_file() {
    echo "$(instance_run_dir "$INSTANCE_ID")/upstream.pid"
}

cfg_file() {
    echo "$(instance_run_dir "$INSTANCE_ID")/upstream-hev.yml"
}

# 解析 → 设置 U_HOST U_PORT U_USER U_PASS
parse_upstream() {
    local raw="${UPSTREAM_SOCKS5}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    raw="${raw#socks5h://}"
    raw="${raw#socks5://}"
    raw="${raw#socks://}"

    U_USER=""; U_PASS=""; U_HOST=""; U_PORT=""

    if [[ "$raw" == *"@"* ]]; then
        local cred="${raw%%@*}"
        raw="${raw#*@}"
        U_USER="${cred%%:*}"
        if [[ "$cred" == *":"* ]]; then
            U_PASS="${cred#*:}"
        fi
    fi

    if [[ "$raw" == \[*\]:* ]]; then
        U_HOST="${raw%%]*}"
        U_HOST="${U_HOST#\[}"
        U_PORT="${raw##*:}"
    elif [[ "$raw" == *":"* ]]; then
        U_PORT="${raw##*:}"
        U_HOST="${raw%:*}"
    else
        log "❌ UPSTREAM_SOCKS5 格式错误（需 host:port）: $UPSTREAM_SOCKS5"
        return 1
    fi

    [[ "$U_PORT" =~ ^[0-9]+$ ]] || { log "❌ 非法端口: $U_PORT"; return 1; }
    [ -n "$U_HOST" ] || return 1
    return 0
}

resolve_host() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$host"; return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        local ip
        ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$host" 2>/dev/null
}

find_hev() {
    if command -v hev-socks5-tunnel >/dev/null 2>&1; then
        command -v hev-socks5-tunnel
        return 0
    fi
    for p in /usr/local/bin/hev-socks5-tunnel /usr/bin/hev-socks5-tunnel; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

save_meta() {
    local node_ip="$1" gw="$2" ifc="$3"
    mkdir -p "$(dirname "$(meta_file)")"
    cat > "$(meta_file)" <<EOF
NODE_IP=${node_ip}
ORIG_GW=${gw}
ORIG_IF=${ifc}
SOCKS_HOST=${U_HOST}
SOCKS_PORT=${U_PORT}
TUN_NAME=$(tun_name)
EOF
}

load_meta() {
    # shellcheck disable=SC1090
    [ -f "$(meta_file)" ] && source "$(meta_file)" || true
}

# 捕获「真实」出网关（在改 default 到 TUN 之前调用）
capture_orig_route() {
    local line gw ifc
    line="$(ip -4 route show default 2>/dev/null | head -1)"
    gw="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
    ifc="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    # 已是我们的 TUN 则尝试从 meta 恢复
    if [ "$ifc" = "$(tun_name)" ] || [[ "$ifc" == "${UPSTREAM_TUN_PREFIX}"* ]]; then
        load_meta
        gw="${ORIG_GW:-}"
        ifc="${ORIG_IF:-}"
    fi
    # 仍空：多实例 netns 里应是 veth 对端
    if [ -z "$gw" ] || [ -z "$ifc" ]; then
        line="$(ip -4 route show default 2>/dev/null | head -1)"
        gw="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
        ifc="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    fi
    ORIG_GW="$gw"
    ORIG_IF="$ifc"
    if [ -z "$ORIG_GW" ] || [ -z "$ORIG_IF" ]; then
        log "❌ 无法确定原始默认网关"
        return 1
    fi
    return 0
}

pin_routes() {
    load_meta
    local node_ip="${NODE_IP:-}"
    local gw="${ORIG_GW:-}"
    local ifc="${ORIG_IF:-}"
    local tun
    tun="$(tun_name)"

    if [ -z "$node_ip" ] || [ -z "$gw" ] || [ -z "$ifc" ]; then
        log "⚠ pin: meta 不完整，跳过"
        return 1
    fi

    # 1) 节点 IP 必须直连原始网关（防 TUN→SOCKS 环路）
    ip route replace "${node_ip}/32" via "$gw" dev "$ifc" 2>/dev/null \
        || ip route add "${node_ip}/32" via "$gw" dev "$ifc" 2>/dev/null \
        || true

    # 2) 若 hev TUN 还在，保证有一条可回退的 default 候选
    #    WARP 连上后会自建更高优先级路由；这里不抢 WARP，只在无 WARP 默认时补 default→TUN
    if ip link show "$tun" >/dev/null 2>&1; then
        ip link set "$tun" up 2>/dev/null || true
        # 仅当当前 default 不是 CloudflareWARP / Cloudflare 相关时，维持 default→TUN
        local cur_dev
        cur_dev="$(ip -4 route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
        case "$cur_dev" in
            CloudflareWARP|Cloudflare*|warp*)
                # WARP 已接管，只保节点直连
                ;;
            "$tun")
                ;;
            *)
                # 无 WARP default：用 TUN
                if ! ip -4 route show default 2>/dev/null | grep -q "dev ${tun}"; then
                    ip route replace default dev "$tun" 2>/dev/null || true
                fi
                ;;
        esac
    fi

    log "📌 路由已钉住: ${node_ip}/32 via ${gw} dev ${ifc}"
    return 0
}

start_upstream() {
    if ! upstream_enabled; then
        log "未配置 UPSTREAM_SOCKS5，跳过"
        return 0
    fi

    local hev
    if ! hev="$(find_hev)"; then
        log "❌ 未找到 hev-socks5-tunnel 二进制"
        return 1
    fi

    parse_upstream || return 1

    local node_ip
    node_ip="$(resolve_host "$U_HOST" || true)"
    if [ -z "$node_ip" ]; then
        log "❌ 无法解析 SOCKS 主机: $U_HOST"
        return 1
    fi

    ensure_runtime_dirs 2>/dev/null || mkdir -p "$(instance_run_dir "$INSTANCE_ID")"

    # 已在跑则只 pin
    if [ -f "$(pid_file)" ] && kill -0 "$(cat "$(pid_file)")" 2>/dev/null; then
        log "hev 已在运行 (pid=$(cat "$(pid_file)"))，执行 pin"
        pin_routes
        return 0
    fi

    capture_orig_route || return 1
    save_meta "$node_ip" "$ORIG_GW" "$ORIG_IF"

    local tun
    tun="$(tun_name)"
    # 清理残留接口
    ip link del "$tun" 2>/dev/null || true

    local udp_mode="$UPSTREAM_SOCKS5_UDP"
    case "$udp_mode" in
        udp|UDP) udp_mode=udp ;;
        tcp|TCP) udp_mode=tcp ;;
        *) udp_mode=udp ;;
    esac

    mkdir -p "$(dirname "$(cfg_file)")"
    cat > "$(cfg_file)" <<EOF
tunnel:
  name: ${tun}
  mtu: ${UPSTREAM_MTU}
  ipv4: 198.18.${INSTANCE_ID}.1
socks5:
  port: ${U_PORT}
  address: ${node_ip}
  udp: '${udp_mode}'
EOF
    if [ -n "$U_USER" ]; then
        # YAML 单引号内原样
        local yu yp
        yu="${U_USER//\'/\'\'}"
        yp="${U_PASS//\'/\'\'}"
        cat >> "$(cfg_file)" <<EOF
  username: '${yu}'
  password: '${yp}'
EOF
    fi

    log "启动 hev → ${U_USER:+$U_USER@}${U_HOST}:${U_PORT} (ip=${node_ip}, udp=${udp_mode}, tun=${tun})"
    local logf
    logf="$(instance_log_dir "$INSTANCE_ID")/upstream-hev.log"
    mkdir -p "$(dirname "$logf")"
    "$hev" "$(cfg_file)" >>"$logf" 2>&1 &
    echo $! > "$(pid_file)"
    sleep 1

    if ! kill -0 "$(cat "$(pid_file)")" 2>/dev/null; then
        log "❌ hev 启动失败，见 ${logf}"
        tail -20 "$logf" 2>/dev/null | while read -r l; do log "  hev: $l"; done
        return 1
    fi

    local i
    for i in $(seq 1 30); do
        ip link show "$tun" >/dev/null 2>&1 && break
        sleep 0.2
    done
    if ! ip link show "$tun" >/dev/null 2>&1; then
        log "❌ TUN ${tun} 未出现"
        return 1
    fi
    ip link set "$tun" up 2>/dev/null || true

    # 节点直连 + default → TUN
    ip route replace "${node_ip}/32" via "$ORIG_GW" dev "$ORIG_IF" 2>/dev/null || true
    ip route replace default dev "$tun" 2>/dev/null \
        || ip route add default dev "$tun" 2>/dev/null \
        || { log "❌ 设置 default→${tun} 失败"; return 1; }

    log "✅ 上游 SOCKS5 TUN 已就绪 (default → ${tun}, node ${node_ip}/32 via ${ORIG_GW})"
    return 0
}

stop_upstream() {
    local tun pid
    tun="$(tun_name)"
    load_meta

    if [ -f "$(pid_file)" ]; then
        pid="$(cat "$(pid_file)")"
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$(pid_file)"
    fi
    # 兜底按配置杀
    pkill -f "hev-socks5-tunnel.*$(cfg_file)" 2>/dev/null || true
    ip link del "$tun" 2>/dev/null || true

    # 尝试恢复 default 到原始网关
    if [ -n "${ORIG_GW:-}" ] && [ -n "${ORIG_IF:-}" ]; then
        ip route replace default via "$ORIG_GW" dev "$ORIG_IF" 2>/dev/null || true
    fi
    if [ -n "${NODE_IP:-}" ]; then
        ip route del "${NODE_IP}/32" 2>/dev/null || true
    fi
    log "上游已停止"
    return 0
}

status_upstream() {
    if ! upstream_enabled; then
        echo "upstream: disabled"
        return 1
    fi
    load_meta
    local tun pid_st="down"
    tun="$(tun_name)"
    if [ -f "$(pid_file)" ] && kill -0 "$(cat "$(pid_file)")" 2>/dev/null; then
        pid_st="up"
    fi
    local link_st="missing"
    ip link show "$tun" >/dev/null 2>&1 && link_st="up"
    echo "upstream: configured"
    echo "  socks: ${SOCKS_HOST:-?}:${SOCKS_PORT:-?} node_ip=${NODE_IP:-?}"
    echo "  hev: ${pid_st}  tun: ${tun} (${link_st})"
    echo "  orig: via ${ORIG_GW:-?} dev ${ORIG_IF:-?}"
    ip -4 route show default 2>/dev/null | sed 's/^/  route: /'
    [ "$pid_st" = "up" ]
}

# 在指定实例的网络命名空间执行（供 host 侧 health-check 调用）
# 多实例: ip netns exec + 本脚本
# 单实例: 直接执行
run_in_instance_net() {
    local id="$1" subcmd="$2"
    if [ "${INSTANCE_COUNT:-1}" -gt 1 ]; then
        local ns
        ns="$(instance_netns "$id")"
        ip netns exec "$ns" env \
            UPSTREAM_SOCKS5="$UPSTREAM_SOCKS5" \
            UPSTREAM_SOCKS5_UDP="$UPSTREAM_SOCKS5_UDP" \
            UPSTREAM_MTU="$UPSTREAM_MTU" \
            UPSTREAM_TUN_PREFIX="$UPSTREAM_TUN_PREFIX" \
            INSTANCE_COUNT="$INSTANCE_COUNT" \
            CURRENT_INSTANCE_ID="$id" \
            /usr/local/bin/upstream-setup.sh "$subcmd" "$id"
    else
        CURRENT_INSTANCE_ID="$id" /usr/local/bin/upstream-setup.sh "$subcmd" "$id"
    fi
}

case "$CMD" in
    enabled)
        upstream_enabled
        ;;
    start)
        start_upstream
        ;;
    stop)
        stop_upstream
        ;;
    pin|ensure)
        # hev 挂了则拉起
        if upstream_enabled; then
            if [ ! -f "$(pid_file)" ] || ! kill -0 "$(cat "$(pid_file)")" 2>/dev/null; then
                start_upstream
            else
                pin_routes
            fi
        fi
        ;;
    status)
        status_upstream
        ;;
    start-in)
        run_in_instance_net "$INSTANCE_ID" start
        ;;
    pin-in)
        run_in_instance_net "$INSTANCE_ID" pin
        ;;
    stop-in)
        run_in_instance_net "$INSTANCE_ID" stop
        ;;
    status-in)
        run_in_instance_net "$INSTANCE_ID" status
        ;;
    *)
        echo "用法: $0 {enabled|start|stop|pin|status|start-in|pin-in|stop-in|status-in} [instance_id]"
        exit 1
        ;;
esac
