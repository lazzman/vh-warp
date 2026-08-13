#!/usr/bin/env bash
# 本地验证定时滚动重启：启用门槛、串行门闩、失败跳过、叠轮忽略
# 用法:
#   ./poc/rotate-restart-local-test.sh
#   docker run --rm -v "$PWD":/src -w /src debian:bookworm-slim bash poc/rotate-restart-local-test.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
SANDBOX=""

ok() { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }

assert_eq() {
    local got="$1" want="$2" name="$3"
    if [ "$got" = "$want" ]; then
        ok "$name"
    else
        bad "$name (got='$got' want='$want')"
    fi
}

assert_file_has() {
    local file="$1" pat="$2" name="$3"
    if grep -qE "$pat" "$file" 2>/dev/null; then
        ok "$name"
    else
        bad "$name (pattern '$pat' not in $file)"
        echo "---- $file ----"
        tail -n 40 "$file" 2>/dev/null || true
        echo "---------------"
    fi
}

check_serial_restarts() {
    local file="$1" line ts ev cmd id last_end=-1 expect=0
    while read -r ts ev cmd id; do
        [ "$cmd" = restart ] || continue
        if [ "$ev" = BEGIN ]; then
            [ "$id" = "$expect" ] || return 1
            [ "$ts" -ge "$last_end" ] || return 1
        elif [ "$ev" = END ]; then
            [ "$id" = "$expect" ] || return 1
            last_end=$ts
            expect=$((expect + 1))
        fi
    done < "$file"
    [ "$expect" -eq 4 ]
}

check_lb_down_then_up() {
    local file="$1" n="$2" i first second
    i=0
    while [ "$i" -lt "$n" ]; do
        first=$(awk -v id="$i" '$2==id {print $3; exit}' "$file")
        second=$(awk -v id="$i" '$2==id {c+=1; if(c==2){print $3; exit}}' "$file")
        [ "$first" = down ] && [ "$second" = up ] || return 1
        i=$((i + 1))
    done
    return 0
}

check_lb_fail_stays_down() {
    local file="$1" last0 last1 last2 last3
    last0=$(awk '$2==0 {s=$3} END{print s}' "$file")
    last1=$(awk '$2==1 {s=$3} END{print s}' "$file")
    last2=$(awk '$2==2 {s=$3} END{print s}' "$file")
    last3=$(awk '$2==3 {s=$3} END{print s}' "$file")
    [ "$last0" = up ] && [ "$last1" = down ] && [ "$last2" = up ] && [ "$last3" = up ]
}

assert_file_not() {
    local file="$1" pat="$2" name="$3"
    if grep -qE "$pat" "$file" 2>/dev/null; then
        bad "$name (unexpected '$pat')"
        tail -n 40 "$file" 2>/dev/null || true
    else
        ok "$name"
    fi
}

cleanup() {
    if [ -n "${ONCE_PID:-}" ]; then
        kill "$ONCE_PID" 2>/dev/null || true
        wait "$ONCE_PID" 2>/dev/null || true
    fi
    if [ -n "${DAEMON_PID:-}" ]; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
}
trap cleanup EXIT

setup_sandbox() {
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/vh-rotate.XXXXXX")"
    mkdir -p "$SANDBOX/usr/local/bin" "$SANDBOX/log" "$SANDBOX/run" "$SANDBOX/data" "$SANDBOX/locks"
    # 把硬编码 /usr/local/bin 指到沙箱
    sed "s|/usr/local/bin|$SANDBOX/usr/local/bin|g" "$ROOT/warp-common.sh" > "$SANDBOX/usr/local/bin/warp-common.sh"
    sed "s|/usr/local/bin|$SANDBOX/usr/local/bin|g" "$ROOT/rotate-restart.sh" > "$SANDBOX/usr/local/bin/rotate-restart.sh"
    # 测试加速：只改沙箱副本
    tmp="$SANDBOX/usr/local/bin/rotate-restart.sh"
    sed -i.bak \
        -e 's/MIN_INTERVAL_SECONDS=60/MIN_INTERVAL_SECONDS=2/' \
        -e 's/\[ "\$t" -lt 15 \]/[ "$t" -lt 1 ]/' \
        -e 's/sleep 3/sleep 0.2/' \
        -e 's/sleep 1/sleep 0.05/' \
        -e 's/sleep 2/sleep 0.05/' \
        "$tmp"
    rm -f "${tmp}.bak"

    cat >> "$SANDBOX/usr/local/bin/warp-common.sh" <<EOF

# ── 测试替身 ──────────────────────────────────────────
acquire_warp_lock() { return 0; }
release_warp_lock() { return 0; }

probe_instance_trace() {
    local id="\${1:-0}"
    local f="$SANDBOX/probe-fail-\${id}"
    local n=0
    if [ -f "\$f" ]; then
        n="\$(cat "\$f")"
    fi
    echo "probe id=\$id remain=\$n" >> "$SANDBOX/probe.log"
    if [ "\$n" -gt 0 ] 2>/dev/null; then
        echo \$((n - 1)) > "\$f"
        echo "ip=203.0.113.1|warp=off|loc=XX|colo=XXX|http=http/1.1"
        return 1
    fi
    echo "ip=203.0.113.10|warp=on|loc=HK|colo=HKG|http=http/2"
    return 0
}

_orig_update_backend_health() { :; }
update_backend_health() {
    local id="\$1" status="\$2"
    echo "\$(date +%s) \${id} \${status}" >> "$SANDBOX/lb.log"
}
EOF

    cat > "$SANDBOX/usr/local/bin/instance-ctl.sh" <<EOF
#!/usr/bin/env bash
set -u
cmd="\${1:-}"
id="\${2:-0}"
delay="\${INSTANCE_CTL_DELAY:-0.15}"
echo "\$(date +%s) BEGIN \${cmd} \${id}" >> "$SANDBOX/ctl.log"
if [ -f "$SANDBOX/ctl-fail-\${id}" ]; then
    echo "\$(date +%s) FAIL \${cmd} \${id}" >> "$SANDBOX/ctl.log"
    exit 1
fi
sleep "\$delay"
echo "\$(date +%s) END \${cmd} \${id}" >> "$SANDBOX/ctl.log"
exit 0
EOF
    chmod +x "$SANDBOX/usr/local/bin/rotate-restart.sh" "$SANDBOX/usr/local/bin/instance-ctl.sh"

    export WARP_LOG_ROOT="$SANDBOX/log"
    export WARP_RUN_ROOT="$SANDBOX/run"
    export WARP_DATA_ROOT="$SANDBOX/data"
    export WARP_LOCK_ROOT="$SANDBOX/locks"
    export ROTATE_RESTART_PROBE_TIMEOUT=2
    export ROTATE_RESTART_RETRIES=2
    export ROTATE_RESTART_INTERVAL=6h
    unset INSTANCE_CTL_DELAY
}

run_once() {
    "$SANDBOX/usr/local/bin/rotate-restart.sh" once "$@"
}

# ── 1. 纯函数 ──────────────────────────────────────────
echo "== 1. warp-common 纯函数 =="
# shellcheck disable=SC1091
source "$ROOT/warp-common.sh"
assert_eq "$(parse_duration_seconds 6h)" "21600" "parse 6h"
assert_eq "$(parse_duration_seconds 30m)" "1800" "parse 30m"
assert_eq "$(parse_duration_seconds 90s)" "90" "parse 90s"
assert_eq "$(parse_duration_seconds 1d)" "86400" "parse 1d"
assert_eq "$(parse_duration_seconds 21600)" "21600" "parse 纯秒"
assert_eq "$(parse_duration_seconds 2H)" "7200" "parse 2H"
if parse_duration_seconds bad >/dev/null; then
    bad "parse 非法值应失败"
else
    ok "parse 非法值应失败"
fi

INSTANCE_COUNT=3
ROTATE_RESTART_ENABLED=auto
if rotate_restart_enabled; then bad "count=3 auto 不应启用"; else ok "count=3 auto 不启用"; fi
INSTANCE_COUNT=4
if rotate_restart_enabled; then ok "count=4 auto 启用"; else bad "count=4 auto 应启用"; fi
ROTATE_RESTART_ENABLED=0
INSTANCE_COUNT=8
if rotate_restart_enabled; then bad "ENABLED=0 应关闭"; else ok "ENABLED=0 强制关闭"; fi
ROTATE_RESTART_ENABLED=1
INSTANCE_COUNT=2
if rotate_restart_enabled; then ok "ENABLED=1 强制开启"; else bad "ENABLED=1 应开启"; fi

# ── 2. 实例数不足拒绝 once ────────────────────────────
echo "== 2. 未达门槛拒绝 once =="
setup_sandbox
export INSTANCE_COUNT=3
export ROTATE_RESTART_ENABLED=auto
if run_once >/dev/null 2>&1; then
    bad "count=3 的 once 应失败"
else
    ok "count=3 的 once 被拒绝"
fi
assert_file_has "$SANDBOX/log/rotate-restart.log" "未启用定时滚动重启" "拒绝原因写入日志"
if [ -f "$SANDBOX/ctl.log" ]; then
    bad "count=3 不应调用 instance-ctl"
else
    ok "count=3 未调用 instance-ctl"
fi

# ── 3. 串行 + 摘流 + 探针成功 ─────────────────────────
echo "== 3. 四实例串行硬重启（探针一次成功） =="
setup_sandbox
export INSTANCE_COUNT=4
export ROTATE_RESTART_ENABLED=1
run_once --force >/dev/null
assert_file_has "$SANDBOX/log/rotate-restart.log" "本轮开始: instances=4" "轮次开始"
assert_file_has "$SANDBOX/log/rotate-restart.log" "success=4/4 skipped=0" "四台全部成功"
assert_eq "$(grep -c 'BEGIN restart' "$SANDBOX/ctl.log")" "4" "恰好 4 次 restart"

if check_serial_restarts "$SANDBOX/ctl.log"; then
    ok "restart 严格串行 0→1→2→3"
else
    bad "restart 顺序/重叠不正确"
    cat "$SANDBOX/ctl.log"
fi
if check_lb_down_then_up "$SANDBOX/lb.log" 4; then
    ok "每台 LB 先 down 再 up"
else
    bad "LB 摘流/加回顺序不对"
    cat "$SANDBOX/lb.log"
fi

# ── 4. 失败重试 2 次后跳过，并继续下一台 ──────────────
echo "== 4. 单台探针失败：重试 2 次后跳过 =="
setup_sandbox
export INSTANCE_COUNT=4
export ROTATE_RESTART_ENABLED=1
# 实例 1 永远探针失败
echo 999 > "$SANDBOX/probe-fail-1"
run_once --force >/dev/null
assert_file_has "$SANDBOX/log/rotate-restart.log" "success=3/4 skipped=1" "三成功一跳过"
assert_eq "$(grep -c 'BEGIN restart 1' "$SANDBOX/ctl.log")" "3" "失败台 restart 1+2 次"
assert_eq "$(grep -c 'BEGIN restart 2' "$SANDBOX/ctl.log")" "1" "跳过后仍重启下一台"
assert_file_has "$SANDBOX/log/rotate-restart.log" "\\[实例1\\] 重试耗尽，跳过并继续下一台" "失败台有跳过日志"
assert_file_has "$SANDBOX/log/rotate-restart.log" "\\[实例2\\] 滚动重启成功" "后续实例不受影响"
if check_lb_fail_stays_down "$SANDBOX/lb.log"; then
    ok "失败台保持摘流，成功台加回"
else
    bad "失败台 LB 状态不对"
    cat "$SANDBOX/lb.log"
fi

# ── 5. 叠轮忽略 ───────────────────────────────────────
echo "== 5. 上一轮未完成则忽略下一轮 once =="
setup_sandbox
export INSTANCE_COUNT=4
export ROTATE_RESTART_ENABLED=1
export INSTANCE_CTL_DELAY=2
run_once --force >/dev/null &
ONCE_PID=$!
# 等锁建好
for _ in $(seq 1 30); do
    [ -d "$SANDBOX/run/rotate-restart.lock" ] && break
    sleep 0.1
done
run_once --force >/dev/null
wait "$ONCE_PID"
ONCE_PID=""
assert_file_has "$SANDBOX/log/rotate-restart.log" "已有一轮在进行" "第二轮 once 被忽略"
assert_file_has "$SANDBOX/log/rotate-restart.log" "success=4/4 skipped=0" "第一轮仍跑完"
# ctl 只有一轮 4 次，不应变成 8
assert_eq "$(grep -c 'BEGIN restart' "$SANDBOX/ctl.log")" "4" "叠轮没有多重启"

# ── 6. 健康检查互斥标记 ───────────────────────────────
echo "== 6. 滚动标记：health-check / entrypoint 可探测 =="
setup_sandbox
export INSTANCE_COUNT=4
# shellcheck disable=SC1091
source "$SANDBOX/usr/local/bin/warp-common.sh"
if instance_rotate_in_progress 1; then bad "无标记时应为否"; else ok "无标记 instance_rotate_in_progress=否"; fi
mark_instance_rotating 1 "$$"
if instance_rotate_in_progress 1; then ok "活 pid 标记为进行中"; else bad "活 pid 应判定进行中"; fi
if instance_rotate_in_progress 2; then bad "其它实例不应被标记"; else ok "未标记实例不受影响"; fi
unmark_instance_rotating 1
if instance_rotate_in_progress 1; then bad "清除后仍判定进行中"; else ok "unmark 后恢复"; fi
echo "1" > "$(rotate_mark_file 0)"
if instance_rotate_in_progress 0; then bad "死 pid 应被清理"; else ok "死 pid 标记被当作过期清理"; fi

# ── 7. status 子命令 ──────────────────────────────────
echo "== 7. rotate-restart status =="
setup_sandbox
export INSTANCE_COUNT=4
export ROTATE_RESTART_ENABLED=auto
status_out="$("$SANDBOX/usr/local/bin/rotate-restart.sh" status)"
echo "$status_out" | grep -q 'active=yes' && ok "status active=yes (count=4)" || bad "status 未显示启用"
echo "$status_out" | grep -q 'lock=idle' && ok "status lock=idle" || bad "status 锁状态不对"

# ── 汇总 ──────────────────────────────────────────────
echo
echo "======== 结果: ${PASS} passed, ${FAIL} failed ========"
[ "$FAIL" -eq 0 ]
