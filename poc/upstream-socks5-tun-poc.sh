#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PoC: 验证 SOCKS5 是否适合「TUN → 节点」承载 WARP 建连
#
# 交互式（推荐）:
#   ./poc/upstream-socks5-tun-poc.sh
#
# 命令行一次性:
#   ./poc/upstream-socks5-tun-poc.sh 'socks5://user:pass@1.2.3.4:1080'
#   ./poc/upstream-socks5-tun-poc.sh --with-warp '1.2.3.4:1080'
#
# 默认只做 Phase 0（TCP + UDP，秒级、无需 root）。
# TUN 全链路 / WARP 为可选，交互里会再问。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SOCKS_URL=""
WITH_WARP=0
FORCE_DOCKER=0
DO_TUN=""          # 空=交互询问；0/1 强制
ONESHOT=0
TUN_NAME="pocs5"
TUN_IP="198.18.0.1"
TUN_MTU="1280"
HEV_VER="2.17.0"

SOCKS_USER=""; SOCKS_PASS=""; SOCKS_HOST=""; SOCKS_PORT=""; SOCKS_IP=""
PHASE0_TCP=0; PHASE0_UDP=0; PHASE0_NODE_IP=""

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ⚠ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  ✘ %s\033[0m\n' "$*"; }
die()  { fail "$*"; exit 1; }
info() { printf '  %s\n' "$*"; }

prompt() {
    # prompt "提示" 默认值 → 写入 REPLY
    local msg="$1" def="${2-}"
    if [ -n "$def" ]; then
        read -r -p "$msg [$def]: " REPLY || true
        REPLY="${REPLY:-$def}"
    else
        read -r -p "$msg: " REPLY || true
    fi
}

prompt_secret() {
    local msg="$1"
    read -r -s -p "$msg: " REPLY || true
    echo
}

yesno() {
    # yesno "问题" 默认 y|n → 返回 0=yes
    local msg="$1" def="${2:-n}" ans
    if [ "$def" = "y" ]; then
        read -r -p "$msg [Y/n]: " ans || true
        ans="${ans:-y}"
    else
        read -r -p "$msg [y/N]: " ans || true
        ans="${ans:-n}"
    fi
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

usage() {
    cat <<'EOF'
用法:
  ./poc/upstream-socks5-tun-poc.sh                  # 交互模式（可循环测多个）
  ./poc/upstream-socks5-tun-poc.sh <socks-url>      # 一次性测一个
  ./poc/upstream-socks5-tun-poc.sh --tun <url>      # 含 TUN 全链路
  ./poc/upstream-socks5-tun-poc.sh --with-warp <url>

SOCKS 格式:
  1.2.3.4:1080
  socks5://user:pass@1.2.3.4:1080
  user:pass@host:1080
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --with-warp) WITH_WARP=1; DO_TUN=1; shift ;;
        --tun) DO_TUN=1; shift ;;
        --no-tun) DO_TUN=0; shift ;;
        --docker) FORCE_DOCKER=1; shift ;;
        --mtu) TUN_MTU="${2:?}"; shift 2 ;;
        -*) die "未知参数: $1（--help 查看用法）" ;;
        *)
            [ -z "$SOCKS_URL" ] || die "多余参数: $1"
            SOCKS_URL="$1"; ONESHOT=1; shift
            ;;
    esac
done

# ── 解析 ──────────────────────────────────────────────────────────────────
parse_socks() {
    local raw="$1"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    raw="${raw#socks5h://}"
    raw="${raw#socks5://}"
    raw="${raw#socks://}"

    SOCKS_USER=""; SOCKS_PASS=""; SOCKS_HOST=""; SOCKS_PORT=""

    if [[ "$raw" == *"@"* ]]; then
        local cred="${raw%%@*}"
        raw="${raw#*@}"
        SOCKS_USER="${cred%%:*}"
        if [[ "$cred" == *":"* ]]; then
            SOCKS_PASS="${cred#*:}"
        fi
    fi

    if [[ "$raw" == \[*\]:* ]]; then
        SOCKS_HOST="${raw%%]*}"
        SOCKS_HOST="${SOCKS_HOST#\[}"
        SOCKS_PORT="${raw##*:}"
    elif [[ "$raw" == *":"* ]]; then
        SOCKS_PORT="${raw##*:}"
        SOCKS_HOST="${raw%:*}"
    else
        return 1
    fi

    [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || return 1
    [ -n "$SOCKS_HOST" ] || return 1
    return 0
}

resolve_host() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$host"; return 0
    fi
    if command -v dig >/dev/null 2>&1; then
        local ip
        ip="$(dig +short A "$host" 2>/dev/null | awk '/^[0-9]+\./ {print $1; exit}')"
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$host" 2>/dev/null
}

# ── 交互录入 ──────────────────────────────────────────────────────────────
input_socks_interactive() {
    echo
    printf '\033[1m── 输入 SOCKS5 代理 ──\033[0m\n'
    info "可直接粘贴完整 URL，或分项填写"
    info "例: socks5://user:pass@1.2.3.4:1080   或  1.2.3.4:1080"
    echo

    prompt "完整地址（留空则分项填写）"
    local full="$REPLY"

    if [ -n "$full" ]; then
        parse_socks "$full" || { fail "地址格式无效"; return 1; }
    else
        prompt "主机 Host/IP"
        SOCKS_HOST="$REPLY"
        [ -n "$SOCKS_HOST" ] || { fail "主机不能为空"; return 1; }

        prompt "端口 Port" "1080"
        SOCKS_PORT="$REPLY"
        [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || { fail "端口无效"; return 1; }

        prompt "用户名（无认证直接回车）"
        SOCKS_USER="$REPLY"
        if [ -n "$SOCKS_USER" ]; then
            prompt_secret "密码"
            SOCKS_PASS="$REPLY"
        else
            SOCKS_PASS=""
        fi
    fi

    SOCKS_IP="$(resolve_host "$SOCKS_HOST" || true)"
    if [ -z "${SOCKS_IP:-}" ]; then
        fail "无法解析: $SOCKS_HOST"
        return 1
    fi

    echo
    log "目标: ${SOCKS_USER:+$SOCKS_USER@}${SOCKS_HOST}:${SOCKS_PORT}  →  IP ${SOCKS_IP}"
    return 0
}

apply_socks_url() {
    parse_socks "$1" || die "地址格式无效: $1"
    SOCKS_IP="$(resolve_host "$SOCKS_HOST" || true)"
    [ -n "${SOCKS_IP:-}" ] || die "无法解析: $SOCKS_HOST"
    log "目标: ${SOCKS_USER:+$SOCKS_USER@}${SOCKS_HOST}:${SOCKS_PORT}  →  IP ${SOCKS_IP}"
}

# ── Phase 0: TCP + UDP ────────────────────────────────────────────────────
phase0_socks_probe() {
    log "══ Phase 0: SOCKS5 直连（TCP + UDP）══"
    PHASE0_TCP=0; PHASE0_UDP=0; PHASE0_NODE_IP=""

    local auth=()
    if [ -n "$SOCKS_USER" ]; then
        auth=(--proxy-user "${SOCKS_USER}:${SOCKS_PASS}")
    fi

    local tcp_out rc=0
    tcp_out="$(curl -sS --max-time 15 \
        --socks5-hostname "${SOCKS_HOST}:${SOCKS_PORT}" \
        "${auth[@]}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>&1)" || rc=$?

    if [ "$rc" -eq 0 ] && echo "$tcp_out" | grep -q 'ip='; then
        ok "TCP 成功"
        echo "$tcp_out" | grep -E '^(ip|loc|colo|warp)=' | sed 's/^/    /'
        PHASE0_TCP=1
        PHASE0_NODE_IP="$(echo "$tcp_out" | awk -F= '/^ip=/{print $2; exit}')"
    else
        fail "TCP 失败 (rc=$rc)"
        echo "$tcp_out" | sed 's/^/    /' | tail -5
        PHASE0_TCP=0
    fi

    if python3 - "$SOCKS_HOST" "$SOCKS_PORT" "$SOCKS_USER" "$SOCKS_PASS" <<'PY'
import socket, struct, sys, select

host, port = sys.argv[1], int(sys.argv[2])
user, pwd = sys.argv[3], sys.argv[4]

def main():
    s = socket.create_connection((host, port), timeout=10)
    s.settimeout(10)
    if user:
        s.sendall(b"\x05\x02\x00\x02")
    else:
        s.sendall(b"\x05\x01\x00")
    resp = s.recv(2)
    if len(resp) < 2 or resp[0] != 5:
        raise RuntimeError(f"bad greeting: {resp!r}")
    method = resp[1]
    if method == 2:
        u, p = user.encode()[:255], pwd.encode()[:255]
        s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        auth = s.recv(2)
        if len(auth) < 2 or auth[1] != 0:
            raise RuntimeError("auth failed")
    elif method != 0:
        raise RuntimeError(f"unsupported method {method}")

    s.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("0.0.0.0") + b"\x00\x00")
    data = s.recv(256)
    if len(data) < 4 or data[0] != 5 or data[1] != 0:
        raise RuntimeError(f"UDP ASSOCIATE rejected: {data!r}")

    atyp = data[3]
    if atyp == 1:
        bnd_addr = socket.inet_ntoa(data[4:8])
        bnd_port = struct.unpack("!H", data[8:10])[0]
    elif atyp == 3:
        ln = data[4]
        bnd_addr = data[5:5+ln].decode()
        bnd_port = struct.unpack("!H", data[5+ln:7+ln])[0]
    elif atyp == 4:
        bnd_addr = socket.inet_ntop(socket.AF_INET6, data[4:20])
        bnd_port = struct.unpack("!H", data[20:22])[0]
    else:
        raise RuntimeError(f"bad atyp {atyp}")

    if bnd_addr in ("0.0.0.0", "::"):
        bnd_addr = host

    # DNS A example.com → 1.1.1.1:53
    dns = (b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
           b"\x07example\x03com\x00\x00\x01\x00\x01")
    udp_hdr = b"\x00\x00\x00\x01" + socket.inet_aton("1.1.1.1") + struct.pack("!H", 53)
    us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    us.settimeout(8)
    try:
        dest = (bnd_addr, bnd_port)
        us.sendto(udp_hdr + dns, dest)
    except Exception:
        us.sendto(udp_hdr + dns, (socket.gethostbyname(bnd_addr), bnd_port))
    ready, _, _ = select.select([us], [], [], 8)
    if not ready:
        raise RuntimeError("UDP response timeout")
    resp, _ = us.recvfrom(4096)
    if len(resp) < 10:
        raise RuntimeError("short udp resp")
    print(f"bnd={bnd_addr}:{bnd_port} resp_len={len(resp)}")
    s.close(); us.close()

try:
    main()
except Exception as e:
    print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(2)
PY
    then
        ok "UDP ASSOCIATE 成功（节点支持 SOCKS5 UDP）"
        PHASE0_UDP=1
    else
        fail "UDP ASSOCIATE 失败 → 官方 WARP MASQUE 基本走不通"
        PHASE0_UDP=0
    fi

    echo
    printf '\033[1m  ── 小结 ──\033[0m\n'
    info "TCP:  $( [ "$PHASE0_TCP" -eq 1 ] && echo OK || echo FAIL )   出口 IP: ${PHASE0_NODE_IP:-—}"
    info "UDP:  $( [ "$PHASE0_UDP" -eq 1 ] && echo OK || echo FAIL )"
    if [ "$PHASE0_TCP" -eq 1 ] && [ "$PHASE0_UDP" -eq 1 ]; then
        ok "该节点具备 TUN→SOCKS 承载 WARP 建连的基础条件"
        info "（最终业务 IP 仍会是 Cloudflare WARP，不是节点 IP）"
        return 0
    elif [ "$PHASE0_TCP" -eq 1 ]; then
        warn "仅 TCP 可用，不建议用于 WARP 隧道"
        return 2
    else
        fail "TCP 不可用，换节点/检查账号"
        return 3
    fi
}

# ── TUN 全链路（Docker / Linux）───────────────────────────────────────────
make_inner_script() {
    cat <<'INNER'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
log()  { printf '\033[1;36m[inner %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ⚠ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  ✘ %s\033[0m\n' "$*"; }

SOCKS_HOST="${SOCKS_HOST:?}"; SOCKS_PORT="${SOCKS_PORT:?}"
SOCKS_USER="${SOCKS_USER:-}"; SOCKS_PASS="${SOCKS_PASS:-}"
SOCKS_IP="${SOCKS_IP:?}"
TUN_NAME="${TUN_NAME:-pocs5}"; TUN_IP="${TUN_IP:-198.18.0.1}"
TUN_MTU="${TUN_MTU:-1280}"; HEV_VER="${HEV_VER:-2.7.4}"
HEV_ARCH="${HEV_ARCH:-x86_64}"; WITH_WARP="${WITH_WARP:-0}"
RESULT_TCP=0; RESULT_UDP=0; RESULT_QUIC=0; RESULT_WARP=0; TUN_EXIT_IP=""

cleanup() {
    [ -f /tmp/hev.pid ] && kill "$(cat /tmp/hev.pid)" 2>/dev/null || true
    pkill -f hev-socks5-tunnel 2>/dev/null || true
    ip link del "$TUN_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# 跨发行版装依赖：Debian/Ubuntu=apt，RHEL/CentOS/Rocky=dnf|yum
ensure_deps() {
    local need=() c
    for c in curl ip python3; do
        command -v "$c" >/dev/null 2>&1 || need+=("$c")
    done
    # ip 来自 iproute / iproute2
    command -v ip >/dev/null 2>&1 || need+=(ip)
    if [ ${#need[@]} -eq 0 ]; then
        ok "依赖已就绪 (curl/ip/python3)"
        return 0
    fi
    log "安装缺失依赖: ${need[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/tmp/pkg.log 2>&1 || true
        apt-get install -y -qq curl ca-certificates iproute2 procps python3 >/tmp/pkg.log 2>&1 \
            || { fail "apt 安装失败"; tail -20 /tmp/pkg.log; return 1; }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q curl ca-certificates iproute procps-ng python3 >/tmp/pkg.log 2>&1 \
            || { fail "dnf 安装失败"; tail -20 /tmp/pkg.log; return 1; }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q curl ca-certificates iproute procps-ng python3 >/tmp/pkg.log 2>&1 \
            || { fail "yum 安装失败"; tail -20 /tmp/pkg.log; return 1; }
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl iproute2 python3 ca-certificates >/tmp/pkg.log 2>&1 \
            || { fail "apk 安装失败"; tail -20 /tmp/pkg.log; return 1; }
    else
        fail "无法识别包管理器，请先手动安装: curl iproute python3"
        return 1
    fi
    command -v curl >/dev/null && command -v ip >/dev/null && command -v python3 >/dev/null \
        || { fail "依赖仍不完整"; return 1; }
}

ensure_deps || exit 1

log "下载 hev-socks5-tunnel ${HEV_VER} (${HEV_ARCH})..."
HEV_URL="https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_VER}/hev-socks5-tunnel-linux-${HEV_ARCH}"
# 优先已有二进制
if ! command -v hev-socks5-tunnel >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/hev-socks5-tunnel "$HEV_URL" \
      || curl -fsSL -o /usr/local/bin/hev-socks5-tunnel "https://ghfast.top/${HEV_URL}" \
      || curl -fsSL -o /usr/local/bin/hev-socks5-tunnel "https://ghproxy.net/${HEV_URL}" \
      || { fail "下载 hev 失败（可手动放到 /usr/local/bin/hev-socks5-tunnel）"; exit 1; }
    chmod +x /usr/local/bin/hev-socks5-tunnel
fi
# PATH 里可能没有 /usr/local/bin
HEV_BIN="$(command -v hev-socks5-tunnel || echo /usr/local/bin/hev-socks5-tunnel)"

ORIG_GW="$(ip -4 route show default | awk '{print $3; exit}')"
ORIG_IF="$(ip -4 route show default | awk '{print $5; exit}')"
ip route replace "${SOCKS_IP}/32" via "$ORIG_GW" dev "$ORIG_IF"
ok "节点直连 ${SOCKS_IP}/32 via ${ORIG_GW}"

cat > /tmp/hev.yml <<EOF
tunnel:
  name: ${TUN_NAME}
  mtu: ${TUN_MTU}
  ipv4: ${TUN_IP}
socks5:
  port: ${SOCKS_PORT}
  address: ${SOCKS_IP}
  udp: 'udp'
EOF
[ -n "$SOCKS_USER" ] && cat >> /tmp/hev.yml <<EOF
  username: '${SOCKS_USER}'
  password: '${SOCKS_PASS}'
EOF

"$HEV_BIN" /tmp/hev.yml >/tmp/hev.log 2>&1 &
echo $! > /tmp/hev.pid
sleep 1
kill -0 "$(cat /tmp/hev.pid)" 2>/dev/null || { fail "hev 启动失败"; cat /tmp/hev.log; exit 1; }
for i in $(seq 1 20); do ip link show "$TUN_NAME" >/dev/null 2>&1 && break; sleep 0.2; done
ip link set "$TUN_NAME" up
ip addr show dev "$TUN_NAME" | grep -q "$TUN_IP" || ip addr add "${TUN_IP}/32" dev "$TUN_NAME" 2>/dev/null || true
ip route replace default dev "$TUN_NAME"
ok "default → ${TUN_NAME}"

log "TCP via TUN..."
TCP_OUT="$(curl -4 -sS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace 2>&1)" && RESULT_TCP=1 || RESULT_TCP=0
if [ "$RESULT_TCP" -eq 1 ] && echo "$TCP_OUT" | grep -q '^ip='; then
    ok "TCP OK"; echo "$TCP_OUT" | grep -E '^(ip|loc|colo|warp)=' | sed 's/^/    /'
    TUN_EXIT_IP="$(echo "$TCP_OUT" | awk -F= '/^ip=/{print $2; exit}')"
else
    fail "TCP FAIL"; echo "$TCP_OUT" | tail -5 | sed 's/^/    /'; tail -15 /tmp/hev.log | sed 's/^/    hev: /'
fi

log "UDP DNS via TUN..."
if python3 - <<'PY'
import socket, struct
q = b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x0acloudflare\x03com\x00\x00\x01\x00\x01"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(8)
s.sendto(q, ("1.1.1.1", 53)); data,_ = s.recvfrom(4096)
assert len(data) >= 12 and struct.unpack("!H", data[6:8])[0] >= 1
print("dns_ok")
PY
then ok "UDP OK"; RESULT_UDP=1
else fail "UDP FAIL"; RESULT_UDP=0; tail -20 /tmp/hev.log | sed 's/^/    hev: /' || true
fi

log "HTTP/3 粗测..."
if curl -V 2>&1 | grep -qi http3; then
    Q="$(curl -4 -sS --max-time 20 --http3-only https://cloudflare.com/cdn-cgi/trace 2>&1)" && RESULT_QUIC=1 || RESULT_QUIC=0
    [ "$RESULT_QUIC" -eq 1 ] && echo "$Q" | grep -q '^ip=' && ok "HTTP/3 OK" || { fail "HTTP/3 FAIL"; RESULT_QUIC=0; }
else
    warn "curl 无 HTTP/3，跳过"
fi

if [ "$WITH_WARP" = "1" ]; then
    log "尝试 WARP 实测..."
    if ! command -v warp-cli >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y -qq curl gnupg >/dev/null 2>&1 || true
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg 2>/dev/null \
              | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
            . /etc/os-release || true
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME:-bookworm} main" \
              > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -qq >/tmp/warp-apt.log 2>&1 || true
            apt-get install -y -qq cloudflare-warp dbus >/tmp/warp-apt.log 2>&1 || true
        else
            warn "非 Debian 系：请先自行安装 cloudflare-warp / 使用已有 warp-cli"
            warn "CentOS/RHEL 本 PoC 不自动装 RPM"
        fi
    fi
    if command -v warp-cli >/dev/null 2>&1; then
        mkdir -p /run/dbus /dev/net
        [ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200
        command -v dbus-daemon >/dev/null 2>&1 && dbus-daemon --system --fork 2>/dev/null || true
        pgrep -x warp-svc >/dev/null 2>&1 || warp-svc >/tmp/warp-svc.log 2>&1 &
        sleep 3
        warp-cli --accept-tos registration new >/tmp/warp-reg.log 2>&1 || true
        warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 || true
        warp-cli --accept-tos mode warp+doh >/dev/null 2>&1 || true
        ip route replace "${SOCKS_IP}/32" via "$ORIG_GW" dev "$ORIG_IF"
        warp-cli --accept-tos connect >/tmp/warp-conn.log 2>&1 || true
        for i in $(seq 1 30); do
            warp-cli --accept-tos status 2>/dev/null | grep -qi connected && RESULT_WARP=1 && break
            sleep 2
        done
        if [ "$RESULT_WARP" -eq 1 ]; then
            ok "WARP Connected"
            curl -4 -sS --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
              | grep -E '^(ip|warp|loc)=' | sed 's/^/    /' || true
        else
            fail "WARP 未连通"; tail -15 /tmp/warp-svc.log 2>/dev/null | sed 's/^/    /' || true
        fi
    else
        warn "未找到 warp-cli，跳过 WARP 段"
    fi
fi

echo
log "════════ TUN 汇总 ════════"
echo "  TCP:  $( [ $RESULT_TCP -eq 1 ] && echo OK || echo FAIL ) ${TUN_EXIT_IP}"
echo "  UDP:  $( [ $RESULT_UDP -eq 1 ] && echo OK || echo FAIL )"
echo "  QUIC: $( [ $RESULT_QUIC -eq 1 ] && echo OK || echo FAIL/SKIP )"
echo "  WARP: $( [ $RESULT_WARP -eq 1 ] && echo OK || echo FAIL/SKIP )"
if [ "$RESULT_TCP" -eq 1 ] && [ "$RESULT_UDP" -eq 1 ]; then exit 0
elif [ "$RESULT_TCP" -eq 1 ]; then exit 2
else exit 3; fi
INNER
}

run_tun_poc() {
    local OS ARCH HEV_ARCH DOCKER_PLATFORM
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) HEV_ARCH="x86_64"; DOCKER_PLATFORM="linux/amd64" ;;
        aarch64|arm64) HEV_ARCH="arm64"; DOCKER_PLATFORM="linux/arm64" ;;
        *) die "不支持架构: $ARCH" ;;
    esac

    local inner rc
    inner="$(mktemp)"
    make_inner_script > "$inner"

    export SOCKS_HOST SOCKS_PORT SOCKS_USER SOCKS_PASS SOCKS_IP
    export TUN_NAME TUN_IP TUN_MTU HEV_VER HEV_ARCH WITH_WARP

    set +e
    if [ "$FORCE_DOCKER" -eq 1 ] || [ "$OS" != "Linux" ]; then
        command -v docker >/dev/null 2>&1 || { rm -f "$inner"; die "需要 docker"; }
        log "Docker 跑 TUN PoC (${DOCKER_PLATFORM})..."
        docker run --rm -i \
            --platform "$DOCKER_PLATFORM" \
            --privileged --device=/dev/net/tun \
            --sysctl net.ipv4.conf.all.src_valid_mark=1 \
            --sysctl net.ipv4.ip_forward=1 \
            -e SOCKS_HOST -e SOCKS_PORT -e SOCKS_USER -e SOCKS_PASS -e SOCKS_IP \
            -e TUN_NAME -e TUN_IP -e TUN_MTU -e HEV_VER -e HEV_ARCH -e WITH_WARP \
            debian:bookworm-slim bash -s < "$inner"
        rc=$?
    else
        [ "$(id -u)" -eq 0 ] || { rm -f "$inner"; die "本机 TUN 需要 root: sudo $0"; }
        log "本机 Linux 跑 TUN PoC..."
        bash "$inner"
        rc=$?
    fi
    set -e
    rm -f "$inner"
    return "$rc"
}

# ── 测一轮 ────────────────────────────────────────────────────────────────
run_one_round() {
    local p0_rc=0 tun_rc=0
    set +e
    phase0_socks_probe
    p0_rc=$?
    set -e

    local want_tun="$DO_TUN"
    if [ -z "$want_tun" ]; then
        if [ "$p0_rc" -eq 0 ]; then
            if [ -t 0 ] && yesno "继续做 TUN 全链路测试？(较慢，需 Docker/root)" "n"; then
                want_tun=1
            else
                want_tun=0
            fi
        else
            want_tun=0
            [ "$p0_rc" -eq 2 ] && info "UDP 已失败，跳过 TUN"
        fi
    fi

    if [ "$want_tun" = "1" ]; then
        if [ -z "$DO_TUN" ] && [ -t 0 ] && [ "$WITH_WARP" -eq 0 ]; then
            yesno "TUN 测试时顺便装 WARP 实测？" "n" && WITH_WARP=1
        fi
        set +e
        run_tun_poc
        tun_rc=$?
        set -e
    fi

    return "$p0_rc"
}

# ── 主流程 ────────────────────────────────────────────────────────────────
main() {
    printf '\n'
    printf '  \033[1mSOCKS5 → TUN / WARP 可行性检测\033[0m\n'
    printf '  默认 Phase0: TCP + UDP（快速）\n'
    printf '  可选: TUN 全链路、WARP 建连\n'
    printf '\n'

    if [ "$ONESHOT" -eq 1 ]; then
        apply_socks_url "$SOCKS_URL"
        run_one_round
        exit $?
    fi

    # 交互循环
    local n=0 last_rc=0
    if [ ! -t 0 ]; then
        die "非 TTY 且未给 SOCKS 地址。用法: $0 'host:port'  或在终端直接运行进入交互"
    fi

    while true; do
        n=$((n + 1))
        printf '\n\033[1m════════ 第 %d 个代理 ════════\033[0m\n' "$n"

        if ! input_socks_interactive; then
            warn "输入无效，重试"
            continue
        fi

        set +e
        run_one_round
        last_rc=$?
        set -e

        echo
        if ! yesno "再测另一个 SOCKS 代理？" "y"; then
            break
        fi
        # 下一轮重置可选 TUN 询问
        [ -n "${DO_TUN}" ] || true
        WITH_WARP=0
    done

    echo
    log "结束（最后一次 Phase0 exit=$last_rc）"
    exit "$last_rc"
}

main
