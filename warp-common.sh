#!/bin/bash

WARP_LOCK_DIR="${WARP_LOCK_DIR:-/run/lock/vh-warp-registration.lock}"

warp_cli_ready() {
    warp-cli --accept-tos status > /dev/null 2>&1
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
    warp-cli --accept-tos registration show 2>/dev/null
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
    warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"
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

    mkdir -p "$(dirname "$WARP_LOCK_DIR")"
    while ! mkdir "$WARP_LOCK_DIR" 2>/dev/null; do
        owner=$(cat "$WARP_LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$WARP_LOCK_DIR"
            continue
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "$$" > "$WARP_LOCK_DIR/pid"
    return 0
}

release_warp_lock() {
    local owner
    owner=$(cat "$WARP_LOCK_DIR/pid" 2>/dev/null)
    if [ "$owner" = "$$" ]; then
        rm -rf "$WARP_LOCK_DIR"
    fi
}
