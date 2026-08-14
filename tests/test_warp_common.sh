#!/bin/bash
# WARP 状态横幅与诊断探测的回归测试。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export INSTANCE_COUNT=1
export BASE_PORT=1111
export WARP_DATA_ROOT="$(mktemp -d)"
export WARP_RUN_ROOT="${WARP_DATA_ROOT}/.runtime"
export WARP_LOCK_ROOT="${WARP_RUN_ROOT}/locks"
source "${ROOT}/warp-common.sh"

pass_count=0
fail_count=0

pass() {
    printf 'ok - %s\n' "$1"
    pass_count=$((pass_count + 1))
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    fail_count=$((fail_count + 1))
}

assert_contains() {
    local name="$1" text="$2" expected="$3"
    if [[ "$text" == *"$expected"* ]]; then
        pass "$name"
    else
        fail "${name}（期望包含：${expected}；实际：${text}）"
    fi
}

assert_not_contains() {
    local name="$1" text="$2" unexpected="$3"
    if [[ "$text" != *"$unexpected"* ]]; then
        pass "$name"
    else
        fail "${name}（不应包含：${unexpected}；实际：${text}）"
    fi
}

assert_equals() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "${name}（期望：${expected}；实际：${actual}）"
    fi
}

# IPv4/IPv6 优先应写入 GOST resolver；两个开关同时开启时固定选择 IPv4。
PREFER_IPV4=1
PREFER_IPV6=0
gost_config="$(mktemp)"
write_gost_listen_config 1080 "$gost_config"
gost_config_text="$(cat "$gost_config")"
assert_equals "IPv4 优先应返回 ipv4" "$(gost_resolver_preference)" "ipv4"
assert_contains "IPv4 优先配置应使用 A 记录" "$gost_config_text" "prefer: ipv4"

PREFER_IPV6=1
assert_equals "双开关时 IPv4 应优先" "$(gost_resolver_preference)" "ipv4"

PREFER_IPV4=0
write_gost_listen_config 1080 "$gost_config"
gost_config_text="$(cat "$gost_config")"
assert_equals "IPv6 优先应保持兼容" "$(gost_resolver_preference)" "ipv6"
assert_contains "IPv6 优先配置应使用 AAAA 记录" "$gost_config_text" "prefer: ipv6"

PREFER_IPV6=0
assert_equals "未开启优先时不应选择 IP 版本" "$(gost_resolver_preference)" ""
rm -f "$gost_config"

# 横幅测试不依赖真实 WARP/GOST 进程。
pgrep() {
    return 0
}

get_account_type() {
    echo "Free"
}

# 验证详细探测会保留 curl 返回码和错误原因，而不是笼统显示 n/a。
CURL_MODE="fail"
curl() {
    if [ "$CURL_MODE" = "success" ]; then
        printf 'ip=104.28.1.2\nwarp=on\nloc=US\ncolo=LAX\nhttp=http/2\n'
        return 0
    fi
    printf 'curl: (28) Connection timed out\n' >&2
    return 28
}
detail="$(probe_instance_trace_detail 0 1)" || true
assert_contains "详细探测应显示 trace 失败" "$detail" "trace=failed"
assert_contains "详细探测应保留 curl 返回码" "$detail" "curl_rc=28"
assert_contains "详细探测应保留 curl 错误摘要" "$detail" "error=curl: (28) Connection timed out"

CURL_MODE="success"
detail="$(probe_instance_trace_detail 0 1)"
assert_contains "详细探测应解析成功状态" "$detail" "trace=ok"
assert_contains "详细探测应解析 WARP 标记" "$detail" "warp=on"
assert_contains "详细探测应记录实际端点" "$detail" "endpoint=www.cloudflare.com/cdn-cgi/trace"

# 后续横幅测试改用可控的状态源，不依赖真实网络。
MOCK_CLI_STATE=""
MOCK_PROBE=""
warp_connection_state() {
    echo "$MOCK_CLI_STATE"
}
probe_instance_trace_detail() {
    printf '%s\n' "$MOCK_PROBE"
    [[ "$MOCK_PROBE" == trace=ok* ]]
}

run_info_case() {
    local name="$1" expected="$4"
    MOCK_CLI_STATE="$2"
    MOCK_PROBE="$3"
    local line
    line="$(instance_info_line 0)"
    assert_contains "$name" "$line" "$expected"
}

run_info_case \
    "warp=on 的 trace 应标记为 ready" \
    "connected" \
    "trace=ok|endpoint=www.cloudflare.com/cdn-cgi/trace|curl_rc=0|error=none|ip=104.28.1.2|warp=on|loc=US|colo=LAX|http=http/2" \
    "readiness=ready"

run_info_case \
    "warp=off 的 trace 应标记为 direct" \
    "connected" \
    "trace=ok|endpoint=www.cloudflare.com/cdn-cgi/trace|curl_rc=0|error=none|ip=198.51.100.2|warp=off|loc=KR|colo=ICN|http=http/2" \
    "readiness=direct"

run_info_case \
    "连接中的 WARP 应标记为 waiting" \
    "connecting" \
    "trace=failed|endpoint=one.one.one.one/cdn-cgi/trace|curl_rc=7|error=curl:_connection_refused" \
    "readiness=waiting"

run_info_case \
    "CLI 已连接但 trace 失败应标记为 probe_failed" \
    "connected" \
    "trace=failed|endpoint=one.one.one.one/cdn-cgi/trace|curl_rc=28|error=curl:_timeout" \
    "readiness=probe_failed"

formatted="$(format_instance_info_line 'instance-2 port=1113 readiness=ready proc(warp=up,gost=up) account=Free cli=connected trace=ok endpoint=www.cloudflare.com/cdn-cgi/trace ip=2a09:bac5:624b:2da5::48c:2f warp=on loc=US colo=LAX')"
assert_contains "控制台格式应简洁显示已就绪" "$formatted" "✅"
assert_contains "控制台格式应显示 WARP 出口" "$formatted" "IP=2a09:bac5:624b:2da5::48c:2f"
assert_not_contains "控制台格式不应输出冗长机器字段" "$formatted" "account="

formatted="$(format_instance_info_line 'instance-6 port=1117 readiness=probe_failed proc(warp=up,gost=up) account=Unknown cli=unavailable trace=failed endpoint=one.one.one.one/cdn-cgi/trace curl_rc=97 error=curl:_socks')"
assert_contains "探测失败应翻译为简短原因" "$formatted" "原因=SOCKS5_未就绪"

rm -rf "$WARP_DATA_ROOT"

if [ "$fail_count" -gt 0 ]; then
    printf '%s 项测试失败，%s 项通过\n' "$fail_count" "$pass_count" >&2
    exit 1
fi
printf '全部 %s 项测试通过\n' "$pass_count"
