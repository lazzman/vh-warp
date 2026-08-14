#!/bin/bash
# 健康检测就绪状态事件流的回归测试。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export INSTANCE_COUNT=1
export BASE_PORT=1111
export WARP_DATA_ROOT="${TEST_ROOT}/data"
export WARP_RUN_ROOT="${WARP_DATA_ROOT}/.runtime"
export WARP_LOCK_ROOT="${WARP_RUN_ROOT}/locks"
export WARP_LOG_ROOT="${TEST_ROOT}/logs"
export HEALTH_CHECK_LIB_ONLY=1
export STATUS_EVENT_LOG=1
source "${ROOT}/health-check.sh"

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

assert_empty() {
    local name="$1" text="$2"
    if [ -z "$text" ]; then
        pass "$name"
    else
        fail "${name}（期望为空；实际：${text}）"
    fi
}

waiting_line='instance-0 port=1111 readiness=waiting proc(warp=up,gost=up) account=Free cli=connecting trace=failed endpoint=one.one.one.one/cdn-cgi/trace curl_rc=7 error=connection_refused'
ready_line='instance-0 port=1111 readiness=ready proc(warp=up,gost=up) account=Free cli=connected trace=ok endpoint=www.cloudflare.com/cdn-cgi/trace ip=104.28.1.2 warp=on loc=US colo=LAX'
new_egress_line='instance-0 port=1111 readiness=ready proc(warp=up,gost=up) account=Free cli=connected trace=ok endpoint=www.cloudflare.com/cdn-cgi/trace ip=104.28.2.3 warp=on loc=US colo=SJC'

signature="$(readiness_signature_from_line "$ready_line")"
assert_contains "状态签名应读取 trace 的 warp 字段而非进程字段" "$signature" "ready|104.28.1.2|on|LAX"

out="$(report_readiness_transition 0 "$waiting_line")"
assert_empty "首次探测不应与启动横幅重复输出" "$out"
if grep -q '初始就绪状态: waiting|n/a|n/a|n/a' "$LOG_FILE"; then
    pass "首次探测仍应写入详细基线日志"
else
    fail "首次探测仍应写入详细基线日志"
fi

out="$(report_readiness_transition 0 "$waiting_line")"
assert_empty "未变化的状态不应重复输出" "$out"

out="$(report_readiness_transition 0 "$ready_line")"
assert_empty "状态变化应等待本轮状态表统一输出" "$out"
if grep -q 'waiting|n/a|n/a|n/a → ready|104.28.1.2|on|LAX' "$LOG_FILE"; then
    pass "恢复为 ready 应保留详细变化日志"
else
    fail "恢复为 ready 应保留详细变化日志"
fi

out="$(report_readiness_transition 0 "$new_egress_line")"
assert_empty "出口变化应等待本轮状态表统一输出" "$out"
if grep -q 'ready|104.28.1.2|on|LAX → ready|104.28.2.3|on|SJC' "$LOG_FILE"; then
    pass "WARP 出口变化应保留详细变化日志"
else
    fail "WARP 出口变化应保留详细变化日志"
fi

# 健康检测应与控制台横幅共用 readiness=ready 的健康判定。
MOCK_STATUS_LINE="$ready_line"
instance_info_line() {
    printf '%s\n' "$MOCK_STATUS_LINE"
}
rm -f "$(readiness_signature_file 0)"
begin_health_round
if check_proxy_instance 0 > "${TEST_ROOT}/check.out"; then
    pass "readiness=ready 应通过健康检测"
else
    fail "readiness=ready 应通过健康检测"
fi
out="$(cat "${TEST_ROOT}/check.out")"
assert_empty "健康检测首次状态不应重复输出" "$out"
table="$(emit_health_status_table)"
assert_contains "首轮状态表应标记首次观测" "$table" "🆕"
assert_contains "首轮状态表应显示全部实例状态" "$table" "✅"

MOCK_STATUS_LINE='instance-0 port=1111 readiness=direct proc(warp=up,gost=up) account=Free cli=connected trace=ok endpoint=www.cloudflare.com/cdn-cgi/trace ip=203.0.113.2 warp=off loc=KR colo=ICN'
begin_health_round
if check_proxy_instance 0 > "${TEST_ROOT}/check.out"; then
    fail "readiness=direct 不应通过健康检测"
else
    pass "readiness=direct 不应通过健康检测"
fi
out="$(cat "${TEST_ROOT}/check.out")"
assert_empty "实例检查不应单独输出，避免打乱状态表" "$out"
table="$(emit_health_status_table)"
assert_contains "变化实例应使用特别图标标记" "$table" "🔄"
assert_contains "状态表应显示直连状态" "$table" "直连中"

STATUS_EVENT_LOG=0
begin_health_round
record_health_round_line 0 "$ready_line" "unchanged"
out="$(emit_health_status_table)"
assert_empty "关闭控制台状态表后不应输出 stdout" "$out"
if grep -q 'WARP 健康状态第' "$LOG_FILE"; then
    pass "关闭控制台状态表后仍应写入健康检测日志"
else
    fail "关闭控制台状态表后仍应写入健康检测日志"
fi

rm -rf "$TEST_ROOT"

if [ "$fail_count" -gt 0 ]; then
    printf '%s 项测试失败，%s 项通过\n' "$fail_count" "$pass_count" >&2
    exit 1
fi
printf '全部 %s 项测试通过\n' "$pass_count"
