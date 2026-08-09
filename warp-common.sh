#!/bin/bash

# ── 多实例 / 负载均衡默认配置 ──────────────────────────────────────────
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
BASE_PORT="${BASE_PORT:-1111}"
LB_PORT="${LB_PORT:-1110}"
LB_STRATEGY="${LB_STRATEGY:-round}"   # round | random | hash | sticky
LB_ENABLED="${LB_ENABLED:-auto}"      # auto | 1 | 0  (auto: count>1 时开启)

WARP_DATA_ROOT="${WARP_DATA_ROOT:-/var/lib/cloudflare-warp}"
WARP_LOG_ROOT="${WARP_LOG_ROOT:-/var/log/warp-gost}"
# 运行时状态放在数据卷下，避免多实例 unshare 后 remount /run 导致 pid 文件丢失
WARP_RUN_ROOT="${WARP_RUN_ROOT:-/var/lib/cloudflare-warp/.runtime}"
WARP_LOCK_ROOT="${WARP_LOCK_ROOT:-/var/lib/cloudflare-warp/.runtime/locks}"

# 实例 netns 网段：10.64.{id}.0/30  → host=.1  ns=.2
NETNS_PREFIX="${NETNS_PREFIX:-10.64}"
INSTANCE_GOST_PORT="${INSTANCE_GOST_PORT:-1080}"

# GOST 监听调优（偏内存友好；可用环境变量覆盖）
# 旧默认 backlog=4096 / idle=600s / buf≈64KB，多实例下空闲 RSS 偏高
GOST_BACKLOG="${GOST_BACKLOG:-1024}"
GOST_IDLE_TIMEOUT="${GOST_IDLE_TIMEOUT:-120s}"
GOST_READ_BUFFER="${GOST_READ_BUFFER:-32768}"
GOST_WRITE_BUFFER="${GOST_WRITE_BUFFER:-32768}"
GOST_KEEPALIVE_PERIOD="${GOST_KEEPALIVE_PERIOD:-60}"

# 实例内 / 单实例对外 GOST 完整查询串
gost_listen_query() {
    echo "udp=true&nodelay=true&backlog=${GOST_BACKLOG}&readTimeout=0&idleTimeout=${GOST_IDLE_TIMEOUT}&tcpKeepAlive=true&keepAlivePeriod=${GOST_KEEPALIVE_PERIOD}&readBufferSize=${GOST_READ_BUFFER}&writeBufferSize=${GOST_WRITE_BUFFER}"
}

# 主机侧端口转发 GOST（更轻：不设大 buffer）
gost_forward_query() {
    echo "udp=true&nodelay=true&idleTimeout=${GOST_IDLE_TIMEOUT}&tcpKeepAlive=true&keepAlivePeriod=${GOST_KEEPALIVE_PERIOD}"
}

WARP_CLI_TIMEOUT="${WARP_CLI_TIMEOUT:-60}"
WARP_REGISTRATION_TIMEOUT="${WARP_REGISTRATION_TIMEOUT:-60}"
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-180}"

# 上游 SOCKS5 TUN（可选）：WARP 建连/注册走节点；空=直连（默认）
# 例: socks5://user:pass@192.168.1.2:1086  或  192.168.1.2:1086
UPSTREAM_SOCKS5="${UPSTREAM_SOCKS5:-}"
UPSTREAM_SOCKS5_UDP="${UPSTREAM_SOCKS5_UDP:-udp}"   # udp | tcp
UPSTREAM_MTU="${UPSTREAM_MTU:-1280}"
UPSTREAM_TUN_PREFIX="${UPSTREAM_TUN_PREFIX:-ups}"

upstream_configured() {
    [ -n "${UPSTREAM_SOCKS5// /}" ]
}

# 在实例网络上下文启动/钉住上游（host 侧调用）
upstream_start_for() {
    local id="${1:-0}"
    upstream_configured || return 0
    if [ -x /usr/local/bin/upstream-setup.sh ]; then
        /usr/local/bin/upstream-setup.sh start-in "$id"
    fi
}

upstream_pin_for() {
    local id="${1:-0}"
    upstream_configured || return 0
    if [ -x /usr/local/bin/upstream-setup.sh ]; then
        /usr/local/bin/upstream-setup.sh pin-in "$id"
    fi
}

upstream_stop_for() {
    local id="${1:-0}"
    upstream_configured || return 0
    if [ -x /usr/local/bin/upstream-setup.sh ]; then
        /usr/local/bin/upstream-setup.sh stop-in "$id" 2>/dev/null || true
    fi
}

# 规范化实例数
if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || [ "$INSTANCE_COUNT" -lt 1 ]; then
    INSTANCE_COUNT=1
fi
if [ "$INSTANCE_COUNT" -gt 32 ]; then
    INSTANCE_COUNT=32
fi

lb_should_enable() {
    case "$LB_ENABLED" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
        *) [ "$INSTANCE_COUNT" -gt 1 ] ;;
    esac
}

instance_id_list() {
    local i
    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        echo "$i"
    done
}

instance_port() {
    local id="${1:-0}"
    echo $((BASE_PORT + id))
}

instance_netns() {
    local id="${1:-0}"
    echo "vhwarp${id}"
}

instance_veth_host() {
    local id="${1:-0}"
    echo "vwh${id}"
}

instance_veth_ns() {
    local id="${1:-0}"
    echo "vwn${id}"
}

instance_host_ip() {
    local id="${1:-0}"
    echo "${NETNS_PREFIX}.${id}.1"
}

instance_ns_ip() {
    local id="${1:-0}"
    echo "${NETNS_PREFIX}.${id}.2"
}

# 数据目录：单实例兼容旧 volume 根目录；多实例使用 instances/<id>
instance_data_dir() {
    local id="${1:-0}"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        echo "$WARP_DATA_ROOT"
    else
        echo "$WARP_DATA_ROOT/instances/${id}"
    fi
}

instance_log_dir() {
    local id="${1:-0}"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        echo "$WARP_LOG_ROOT"
    else
        echo "$WARP_LOG_ROOT/instance-${id}"
    fi
}

instance_run_dir() {
    local id="${1:-0}"
    echo "${WARP_RUN_ROOT}/instance-${id}"
}

# 后端列表（LB / 健康检查共享）
backends_file() {
    echo "${WARP_RUN_ROOT}/backends.txt"
}

backends_meta_file() {
    echo "${WARP_RUN_ROOT}/backends.meta"
}

# 写入当前健康后端：每行 host:port
write_backends_file() {
    local out tmp id ip
    out="$(backends_file)"
    tmp="${out}.tmp"
    mkdir -p "$(dirname "$out")"
    : > "$tmp"
    for id in $(instance_id_list); do
        if [ "$INSTANCE_COUNT" -eq 1 ]; then
            echo "127.0.0.1:$(instance_port "$id")" >> "$tmp"
        else
            ip="$(instance_ns_ip "$id")"
            echo "${ip}:${INSTANCE_GOST_PORT}" >> "$tmp"
        fi
    done
    mv -f "$tmp" "$out"
}

# 按实例更新健康标记：id status(up/down)
update_backend_health() {
    local id="$1" status="$2"
    local meta tmp line
    meta="$(backends_meta_file)"
    tmp="${meta}.tmp"
    mkdir -p "$(dirname "$meta")"
    touch "$meta"
    grep -v "^${id}=" "$meta" > "$tmp" 2>/dev/null || true
    echo "${id}=${status}" >> "$tmp"
    mv -f "$tmp" "$meta"
    rebuild_healthy_backends
}

rebuild_healthy_backends() {
    local out tmp id ip status meta
    out="$(backends_file)"
    tmp="${out}.tmp"
    meta="$(backends_meta_file)"
    mkdir -p "$(dirname "$out")"
    : > "$tmp"
    for id in $(instance_id_list); do
        status=$(grep "^${id}=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2)
        [ -n "$status" ] || status="up"
        if [ "$status" = "up" ]; then
            if [ "$INSTANCE_COUNT" -eq 1 ]; then
                echo "127.0.0.1:$(instance_port "$id")" >> "$tmp"
            else
                ip="$(instance_ns_ip "$id")"
                echo "${ip}:${INSTANCE_GOST_PORT}" >> "$tmp"
            fi
        fi
    done
    # 全部不健康时回退到全部后端，避免 LB 完全不可用
    if [ ! -s "$tmp" ]; then
        for id in $(instance_id_list); do
            if [ "$INSTANCE_COUNT" -eq 1 ]; then
                echo "127.0.0.1:$(instance_port "$id")" >> "$tmp"
            else
                ip="$(instance_ns_ip "$id")"
                echo "${ip}:${INSTANCE_GOST_PORT}" >> "$tmp"
            fi
        done
    fi
    mv -f "$tmp" "$out"
}

# ── WARP CLI 封装（支持实例上下文）──────────────────────────────────────
# 设置当前 shell 的实例上下文：影响锁、数据路径提示；实际 warp-cli
# 在多实例下必须通过 instance_exec 进入对应 netns/mount。

CURRENT_INSTANCE_ID="${CURRENT_INSTANCE_ID:-0}"

set_instance_context() {
    CURRENT_INSTANCE_ID="${1:-0}"
    export CURRENT_INSTANCE_ID
    WARP_LOCK_DIR="${WARP_LOCK_ROOT}/registration-${CURRENT_INSTANCE_ID}.lock"
    export WARP_LOCK_DIR
}

# 在实例环境中执行命令
# 单实例：直接执行；多实例：ip netns exec + 必要时已在 mount 命名空间内
instance_exec() {
    local id="${CURRENT_INSTANCE_ID:-0}"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        "$@"
    else
        ip netns exec "$(instance_netns "$id")" "$@"
    fi
}

warp_cli_cmd() {
    instance_exec warp-cli --accept-tos "$@"
}

warp_cli_ready() {
    warp_cli_cmd status > /dev/null 2>&1
}

wait_for_warp_cli() {
    local timeout="${1:-60}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if warp_cli_ready; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

registration_info() {
    warp_cli_cmd registration show 2>/dev/null
}

has_registration() {
    registration_info | grep -q "Device ID"
}

wait_for_registration() {
    local timeout="${1:-60}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if has_registration; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

wait_for_registration_deleted() {
    local timeout="${1:-30}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if ! has_registration; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

is_warp_connected() {
    warp_cli_cmd status 2>/dev/null | grep -q "Connected"
}

wait_for_connected() {
    local timeout="${1:-180}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if is_warp_connected; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

get_account_type() {
    local info
    info=$(registration_info)
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

acquire_warp_lock() {
    local timeout="${1:-30}"
    local elapsed=0
    local owner
    local lock_dir="${WARP_LOCK_DIR:-${WARP_LOCK_ROOT}/registration-${CURRENT_INSTANCE_ID:-0}.lock}"

    mkdir -p "$(dirname "$lock_dir")"
    while ! mkdir "$lock_dir" 2>/dev/null; do
        owner=$(cat "$lock_dir/pid" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$lock_dir"
            continue
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "$$" > "$lock_dir/pid"
    WARP_LOCK_DIR="$lock_dir"
    return 0
}

release_warp_lock() {
    local owner
    local lock_dir="${WARP_LOCK_DIR:-${WARP_LOCK_ROOT}/registration-${CURRENT_INSTANCE_ID:-0}.lock}"
    owner=$(cat "$lock_dir/pid" 2>/dev/null)
    if [ "$owner" = "$$" ]; then
        rm -rf "$lock_dir"
    fi
}

# 代理探针目标（实例对外端口或内部地址）
instance_proxy_addr() {
    local id="${1:-0}"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        echo "127.0.0.1:$(instance_port "$id")"
    else
        # 多实例：对外直连端口在宿主机侧转发后监听 BASE_PORT+id
        echo "127.0.0.1:$(instance_port "$id")"
    fi
}

# 经实例代理拉 cdn-cgi/trace，解析出口信息
# 输出: ip=...|warp=...|loc=...|colo=...|http=...
probe_instance_trace() {
    local id="${1:-0}"
    local timeout="${2:-10}"
    local addr trace
    addr="$(instance_proxy_addr "$id")"
    trace="$(curl -4 -sS --max-time "$timeout" --socks5-hostname "$addr" \
        "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null \
        || curl -4 -sS --max-time "$timeout" --socks5-hostname "$addr" \
        "https://one.one.one.one/cdn-cgi/trace" 2>/dev/null \
        || true)"
    if [ -z "$trace" ] || ! echo "$trace" | grep -q '^ip='; then
        echo ""
        return 1
    fi
    local ip warp loc colo http
    ip="$(echo "$trace" | awk -F= '/^ip=/{print $2; exit}')"
    warp="$(echo "$trace" | awk -F= '/^warp=/{print $2; exit}')"
    loc="$(echo "$trace" | awk -F= '/^loc=/{print $2; exit}')"
    colo="$(echo "$trace" | awk -F= '/^colo=/{print $2; exit}')"
    http="$(echo "$trace" | awk -F= '/^http=/{print $2; exit}')"
    echo "ip=${ip}|warp=${warp:-?}|loc=${loc:-?}|colo=${colo:-?}|http=${http:-?}"
    return 0
}

# 单行实例摘要（含 WARP 出口 IP）；供 status / 启动横幅使用
instance_info_line() {
    local id="${1:-0}"
    local port warp_st gost_st acct info egress_ip warp_flag loc colo ns t
    port="$(instance_port "$id")"
    set_instance_context "$id"

    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        pgrep -x warp-svc >/dev/null 2>&1 && warp_st="up" || warp_st="down"
        pgrep -x gost >/dev/null 2>&1 && gost_st="up" || gost_st="down"
    else
        ns="$(instance_netns "$id")"
        command ip netns exec "$ns" pgrep -x warp-svc >/dev/null 2>&1 && warp_st="up" || warp_st="down"
        command ip netns exec "$ns" pgrep -x gost >/dev/null 2>&1 && gost_st="up" || gost_st="down"
    fi

    # 账户类型：多实例下经 instance 上下文执行 warp-cli
    acct="$(get_account_type 2>/dev/null || echo "?")"

    # 刚启动时代理可能未就绪，轻量重试
    info=""
    for t in 1 2 3; do
        if info="$(probe_instance_trace "$id" 8)"; then
            break
        fi
        sleep 1
    done

    if [ -n "$info" ]; then
        egress_ip="${info#*ip=}"; egress_ip="${egress_ip%%|*}"
        warp_flag="${info#*warp=}"; warp_flag="${warp_flag%%|*}"
        loc="${info#*loc=}"; loc="${loc%%|*}"
        colo="${info#*colo=}"; colo="${colo%%|*}"
        printf 'instance-%s port=%s proc(warp=%s,gost=%s) account=%s ip=%s warp=%s loc=%s colo=%s\n' \
            "$id" "$port" "$warp_st" "$gost_st" "$acct" "$egress_ip" "$warp_flag" "$loc" "$colo"
    else
        printf 'instance-%s port=%s proc(warp=%s,gost=%s) account=%s ip=n/a warp=n/a loc=n/a colo=n/a\n' \
            "$id" "$port" "$warp_st" "$gost_st" "$acct"
    fi
}

ensure_runtime_dirs() {
    mkdir -p "$WARP_DATA_ROOT" "$WARP_LOG_ROOT" "$WARP_RUN_ROOT" "$WARP_LOCK_ROOT"
    local id
    for id in $(instance_id_list); do
        mkdir -p "$(instance_data_dir "$id")" "$(instance_log_dir "$id")" "$(instance_run_dir "$id")"
    done
}
