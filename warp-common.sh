#!/bin/bash

# ── 多实例 / 负载均衡默认配置 ──────────────────────────────────────────
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
BASE_PORT="${BASE_PORT:-1111}"
LB_PORT="${LB_PORT:-1110}"
LB_STRATEGY="${LB_STRATEGY:-round}"   # round | random | hash | rotate
LB_ROTATE_INTERVAL="${LB_ROTATE_INTERVAL:-5m}"  # rotate 策略切换间隔；裸数字按分钟
LB_ENABLED="${LB_ENABLED:-auto}"      # auto | 1 | 0  (auto: count>1 时开启)

# 定时滚动硬重启：auto 时 INSTANCE_COUNT>=4 启用；1/0 强制
ROTATE_RESTART_ENABLED="${ROTATE_RESTART_ENABLED:-auto}"
ROTATE_RESTART_INTERVAL="${ROTATE_RESTART_INTERVAL:-6h}"
ROTATE_RESTART_PROBE_TIMEOUT="${ROTATE_RESTART_PROBE_TIMEOUT:-90}"
ROTATE_RESTART_RETRIES="${ROTATE_RESTART_RETRIES:-2}"
ROTATE_RESTART_DRAIN_TIMEOUT="${ROTATE_RESTART_DRAIN_TIMEOUT:-120}"
ROTATE_RESTART_MIN_COUNT="${ROTATE_RESTART_MIN_COUNT:-4}"

WARP_DATA_ROOT="${WARP_DATA_ROOT:-/var/lib/cloudflare-warp}"
WARP_LOG_ROOT="${WARP_LOG_ROOT:-/var/log/warp-gost}"
# 运行时状态放在数据卷下，避免多实例 unshare 后 remount /run 导致 pid 文件丢失
WARP_RUN_ROOT="${WARP_RUN_ROOT:-/var/lib/cloudflare-warp/.runtime}"
WARP_LOCK_ROOT="${WARP_LOCK_ROOT:-/var/lib/cloudflare-warp/.runtime/locks}"

# 实例 netns 网段：10.64.{id}.0/30  → host=.1  ns=.2
NETNS_PREFIX="${NETNS_PREFIX:-10.64}"
INSTANCE_GOST_PORT="${INSTANCE_GOST_PORT:-1080}"

# GOST 启动调优（偏内存友好；可用环境变量覆盖）
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

# IP 版本优先：GOST 3 YAML 的 handler 必须是 auto（mixed 会直接 fatal 退出）。
# nameserver 必须带 udp://，否则解析器不可用。
write_gost_listen_config() {
    local port="$1" out="$2" preference
    preference="$(gost_resolver_preference)"
    if [ -z "$preference" ]; then
        echo "未配置 IP 版本优先，拒绝生成 GOST resolver 配置" >&2
        return 1
    fi
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<EOF
services:
- name: mixed-tcp
  addr: ":${port}"
  resolver: resolver-preferred
  handler:
    type: auto
    metadata:
      udp: true
      nodelay: true
      backlog: ${GOST_BACKLOG}
      readTimeout: 0
      idleTimeout: ${GOST_IDLE_TIMEOUT}
      tcpKeepAlive: true
      keepAlivePeriod: ${GOST_KEEPALIVE_PERIOD}
      readBufferSize: ${GOST_READ_BUFFER}
      writeBufferSize: ${GOST_WRITE_BUFFER}
  listener:
    type: tcp
    metadata:
      backlog: ${GOST_BACKLOG}
      keepalive: true
- name: mixed-udp
  addr: ":${port}"
  resolver: resolver-preferred
  handler:
    type: auto
    metadata:
      ttl: 30s
  listener:
    type: udp
resolvers:
- name: resolver-preferred
  nameservers:
  - addr: udp://1.1.1.1:53
    prefer: ${preference}
    timeout: 3s
    ttl: 30s
  - addr: udp://1.0.0.1:53
    prefer: ${preference}
    timeout: 3s
    ttl: 30s
EOF
}

# 启动真正出站的 GOST（解析目标地址的那一层）。stdout=pid
gost_start_listen() {
    local port="$1" cfg="$2" logf="$3"
    if gost_ip_preference_enabled; then
        write_gost_listen_config "$port" "$cfg"
        gost -C "$cfg" >>"$logf" 2>&1 &
    else
        rm -f "$cfg"
        gost -L "mixed://0.0.0.0:${port}?$(gost_listen_query)" >>"$logf" 2>&1 &
    fi
    echo $!
}

# 主机侧端口转发 GOST（更轻：不设大 buffer）
gost_forward_query() {
    echo "udp=true&nodelay=true&idleTimeout=${GOST_IDLE_TIMEOUT}&tcpKeepAlive=true&keepAlivePeriod=${GOST_KEEPALIVE_PERIOD}"
}

WARP_CLI_TIMEOUT="${WARP_CLI_TIMEOUT:-60}"
WARP_REGISTRATION_TIMEOUT="${WARP_REGISTRATION_TIMEOUT:-60}"
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-180}"

# 双栈出站 IP 版本优先；不检测、不因出口 IP 版本变化重启。
# 两者同时开启时 PREFER_IPV4 优先，避免被宿主 resolver 的地址排序影响。
PREFER_IPV4="${PREFER_IPV4:-0}"                   # 0 | 1
PREFER_IPV6="${PREFER_IPV6:-0}"                   # 0 | 1

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

# 解析 30s / 15m / 6h / 1d / 纯秒 → 秒；失败返回 1
parse_duration_seconds() {
    local raw="${1:-}" n unit
    raw="${raw// /}"
    [ -n "$raw" ] || return 1
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "$raw"
        return 0
    fi
    if [[ "$raw" =~ ^([0-9]+)([smhdSMHD])$ ]]; then
        n="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        unit="$(echo "$unit" | tr '[:upper:]' '[:lower:]')"
        case "$unit" in
            s) echo "$n" ;;
            m) echo $((n * 60)) ;;
            h) echo $((n * 3600)) ;;
            d) echo $((n * 86400)) ;;
            *) return 1 ;;
        esac
        return 0
    fi
    return 1
}

rotate_restart_enabled() {
    local min_count="${ROTATE_RESTART_MIN_COUNT:-4}"
    if ! [[ "$min_count" =~ ^[0-9]+$ ]] || [ "$min_count" -lt 1 ]; then
        min_count=4
    fi
    case "${ROTATE_RESTART_ENABLED:-auto}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
        *) [ "$INSTANCE_COUNT" -ge "$min_count" ] ;;
    esac
}

rotate_mark_file() {
    echo "$(instance_run_dir "${1:-0}")/rotate-restarting"
}

mark_instance_rotating() {
    local id="${1:-0}" pid="${2:-$$}"
    mkdir -p "$(instance_run_dir "$id")"
    echo "$pid" > "$(rotate_mark_file "$id")"
}

unmark_instance_rotating() {
    rm -f "$(rotate_mark_file "${1:-0}")"
}

instance_rotate_in_progress() {
    local id="${1:-0}" f pid
    f="$(rotate_mark_file "$id")"
    [ -f "$f" ] || return 1
    pid="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    rm -f "$f"
    return 1
}

env_flag_on() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

prefer_ipv6_enabled() {
    env_flag_on "${PREFER_IPV6:-0}"
}

prefer_ipv4_enabled() {
    env_flag_on "${PREFER_IPV4:-0}"
}

# 返回 GOST resolver 所用的 prefer 值；同时开启时 IPv4 优先。
gost_resolver_preference() {
    if prefer_ipv4_enabled; then
        echo "ipv4"
    elif prefer_ipv6_enabled; then
        echo "ipv6"
    fi
}

gost_ip_preference_enabled() {
    [ -n "$(gost_resolver_preference)" ]
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

lb_connection_state_file() {
    echo "${WARP_RUN_ROOT}/lb-connections.txt"
}

lb_pid_file() {
    echo "${WARP_RUN_ROOT}/lb.pid"
}

instance_backend_addr() {
    local id="${1:-0}"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        echo "127.0.0.1:$(instance_port "$id")"
    else
        echo "$(instance_ns_ip "$id"):${INSTANCE_GOST_PORT}"
    fi
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
    local meta tmp
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
# 单实例：直接执行；多实例：进入 supervisor 所在的 mount + net 命名空间，
# 这样 warp-cli 才能访问该实例私有 /run 中的 D-Bus 与 WARP socket。
instance_exec() {
    local id="${CURRENT_INSTANCE_ID:-0}"
    if [ "$INSTANCE_COUNT" -eq 1 ]; then
        "$@"
    else
        local run_dir spid
        run_dir="$(instance_run_dir "$id")"
        spid="$(cat "${run_dir}/supervisor.pid" 2>/dev/null || true)"
        if [ -n "$spid" ] && [ -d "/proc/$spid" ]; then
            nsenter --target "$spid" --mount --net "$@"
        else
            # supervisor 尚未写入 PID 时保留原有回退路径，方便启动阶段诊断。
            ip netns exec "$(instance_netns "$id")" "$@"
        fi
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
# 状态探测固定走 IPv4 目的地址，避免无 IPv6 路由时每个实例卡 8s 显示 n/a
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
    ip="$(echo "$trace" | awk -F= '/^ip=/{print $2; exit}' | tr -d '\r')"
    warp="$(echo "$trace" | awk -F= '/^warp=/{print $2; exit}' | tr -d '\r')"
    loc="$(echo "$trace" | awk -F= '/^loc=/{print $2; exit}' | tr -d '\r')"
    colo="$(echo "$trace" | awk -F= '/^colo=/{print $2; exit}' | tr -d '\r')"
    http="$(echo "$trace" | awk -F= '/^http=/{print $2; exit}' | tr -d '\r')"
    echo "ip=${ip}|warp=${warp:-?}|loc=${loc:-?}|colo=${colo:-?}|http=${http:-?}"
    return 0
}

# 将诊断字段压缩为单行安全值，便于写入控制台与日志。
status_field_value() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | tr '\r\n|' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
    value="${value:0:160}"
    printf '%s' "${value:-none}"
}

# 从 instance_info_line 的机器可读单行记录中取字段。字段值不能含空格。
instance_info_field() {
    local line="$1" key="$2" token
    for token in $line; do
        case "$token" in
            "${key}="*)
                echo "${token#*=}"
                return 0
                ;;
        esac
    done
    echo "n/a"
}

# 将 curl 返回码翻译成简短的控制台诊断；完整错误仍保留在机器记录和 health-check.log。
instance_probe_reason() {
    local line="$1" rc
    rc="$(instance_info_field "$line" "curl_rc")"
    case "$rc" in
        97) echo "SOCKS5_未就绪" ;;
        28) echo "探测超时" ;;
        7) echo "代理连接失败" ;;
        6) echo "DNS_解析失败" ;;
        35|56) echo "TLS_连接失败" ;;
        n/a|0) echo "trace_无有效响应" ;;
        *) echo "curl=${rc}" ;;
    esac
}

# 启动横幅使用的简短展示行；完整机器记录继续写入 entrypoint.log / status 命令。
format_instance_info_line() {
    local line="$1" first id port readiness cli ip warp colo warp_proc gost_proc reason
    first="${line%% *}"
    id="${first#instance-}"
    port="$(instance_info_field "$line" "port")"
    readiness="$(instance_info_field "$line" "readiness")"
    cli="$(instance_info_field "$line" "cli")"
    ip="$(instance_info_field "$line" "ip")"
    warp="$(instance_info_field "$line" "warp")"
    colo="$(instance_info_field "$line" "colo")"
    warp_proc="$(printf '%s' "$line" | sed -n 's/.*proc(warp=\([^,)]*\).*/\1/p')"
    gost_proc="$(printf '%s' "$line" | sed -n 's/.*gost=\([^)]*\)).*/\1/p')"

    case "$readiness" in
        ready)
            printf '✅ 实例%-2s :%-5s 已就绪  IP=%-39s WARP=%-4s %s' \
                "$id" "$port" "$ip" "$warp" "$colo"
            ;;
        waiting)
            printf '⏳ 实例%-2s :%-5s 建连中  CLI=%s' "$id" "$port" "$cli"
            ;;
        direct)
            printf '⚠️  实例%-2s :%-5s 直连中  IP=%-39s WARP=%s' \
                "$id" "$port" "$ip" "$warp"
            ;;
        service_down)
            printf '❌ 实例%-2s :%-5s 服务未就绪  warp-svc=%s gost=%s' \
                "$id" "$port" "${warp_proc:-?}" "${gost_proc:-?}"
            ;;
        *)
            reason="$(instance_probe_reason "$line")"
            printf '⚠️  实例%-2s :%-5s 探测失败  CLI=%-12s 原因=%s' \
                "$id" "$port" "$cli" "$reason"
            ;;
    esac
}

# 经实例代理探测 trace，并保留失败端点、curl 返回码与错误摘要。
# 输出: trace=ok|endpoint=...|curl_rc=0|error=none|ip=...|warp=...|loc=...|colo=...|http=...
# 失败时仍输出诊断字段并返回 1，供启动横幅区分“建连中”和“探测失败”。
probe_instance_trace_detail() {
    local id="${1:-0}"
    local timeout="${2:-10}"
    local addr endpoint endpoint_name trace err_file err rc
    local last_endpoint="none" last_rc="?" last_err="none"
    addr="$(instance_proxy_addr "$id")"

    for endpoint in \
        "https://www.cloudflare.com/cdn-cgi/trace" \
        "https://one.one.one.one/cdn-cgi/trace"; do
        endpoint_name="${endpoint#https://}"
        err_file="$(mktemp)"
        trace="$(curl -4 -sS --max-time "$timeout" --socks5-hostname "$addr" \
            "$endpoint" 2>"$err_file")"
        rc=$?
        err="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"

        if [ "$rc" -eq 0 ] && [ -n "$trace" ] && echo "$trace" | grep -q '^ip='; then
            local ip warp loc colo http
            ip="$(echo "$trace" | awk -F= '/^ip=/{print $2; exit}' | tr -d '\r')"
            warp="$(echo "$trace" | awk -F= '/^warp=/{print $2; exit}' | tr -d '\r')"
            loc="$(echo "$trace" | awk -F= '/^loc=/{print $2; exit}' | tr -d '\r')"
            colo="$(echo "$trace" | awk -F= '/^colo=/{print $2; exit}' | tr -d '\r')"
            http="$(echo "$trace" | awk -F= '/^http=/{print $2; exit}' | tr -d '\r')"
            printf 'trace=ok|endpoint=%s|curl_rc=0|error=none|ip=%s|warp=%s|loc=%s|colo=%s|http=%s\n' \
                "$endpoint_name" "$ip" "${warp:-?}" "${loc:-?}" "${colo:-?}" "${http:-?}"
            return 0
        fi

        last_endpoint="$endpoint_name"
        last_rc="$rc"
        if [ "$rc" -eq 0 ]; then
            last_err="trace_response_missing_ip"
        else
            last_err="$(status_field_value "$err")"
        fi
    done

    printf 'trace=failed|endpoint=%s|curl_rc=%s|error=%s\n' \
        "$last_endpoint" "$last_rc" "$last_err"
    return 1
}

# 将 warp-cli 的实际连接状态归一化。多实例时必须进入 supervisor 的 mount 命名空间。
# 输出: connected | connecting | disconnected | unknown | unavailable
warp_connection_state() {
    local status rc
    status="$(warp_cli_cmd status 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "unavailable"
    elif echo "$status" | grep -q "Connected"; then
        echo "connected"
    elif echo "$status" | grep -qi "Connecting"; then
        echo "connecting"
    elif echo "$status" | grep -qi "Disconnected"; then
        echo "disconnected"
    else
        echo "unknown"
    fi
}

# 单行实例摘要（含 WARP 出口 IP）；供 status / 启动横幅使用
instance_info_line() {
    local id="${1:-0}"
    local probe_timeout="${2:-8}"
    local port warp_st gost_st acct cli_state info egress_ip warp_flag loc colo ns
    local readiness trace_state endpoint curl_rc probe_error
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
    cli_state="$(warp_connection_state 2>/dev/null || echo "unavailable")"

    # 启动横幅只做一次、带错误信息的快照；持续重试交给健康检测守护进程。
    info="$(probe_instance_trace_detail "$id" "$probe_timeout")" || true
    trace_state="${info#trace=}"
    trace_state="${trace_state%%|*}"
    endpoint="${info#*endpoint=}"
    endpoint="${endpoint%%|*}"
    curl_rc="${info#*curl_rc=}"
    curl_rc="${curl_rc%%|*}"
    probe_error="${info#*error=}"
    probe_error="${probe_error%%|*}"

    if [ "$trace_state" = "ok" ]; then
        egress_ip="${info#*ip=}"; egress_ip="${egress_ip%%|*}"
        warp_flag="${info#*warp=}"; warp_flag="${warp_flag%%|*}"
        loc="${info#*loc=}"; loc="${loc%%|*}"
        colo="${info#*colo=}"; colo="${colo%%|*}"
        case "$warp_flag" in
            on|plus) readiness="ready" ;;
            *) readiness="direct" ;;
        esac
        printf 'instance-%s port=%s readiness=%s proc(warp=%s,gost=%s) account=%s cli=%s trace=ok endpoint=%s ip=%s warp=%s loc=%s colo=%s\n' \
            "$id" "$port" "$readiness" "$warp_st" "$gost_st" "$acct" "$cli_state" "$endpoint" "$egress_ip" "$warp_flag" "$loc" "$colo"
    else
        if [ "$warp_st" != "up" ] || [ "$gost_st" != "up" ]; then
            readiness="service_down"
        elif [ "$cli_state" = "connecting" ] || [ "$cli_state" = "disconnected" ]; then
            readiness="waiting"
        else
            readiness="probe_failed"
        fi
        printf 'instance-%s port=%s readiness=%s proc(warp=%s,gost=%s) account=%s cli=%s trace=failed endpoint=%s curl_rc=%s error=%s\n' \
            "$id" "$port" "$readiness" "$warp_st" "$gost_st" "$acct" "$cli_state" "$endpoint" "$curl_rc" "$probe_error"
    fi
}

ensure_runtime_dirs() {
    mkdir -p "$WARP_DATA_ROOT" "$WARP_LOG_ROOT" "$WARP_RUN_ROOT" "$WARP_LOCK_ROOT"
    local id
    for id in $(instance_id_list); do
        mkdir -p "$(instance_data_dir "$id")" "$(instance_log_dir "$id")" "$(instance_run_dir "$id")"
    done
}
