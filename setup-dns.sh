#!/bin/bash

time_dns() {
    local dns="$1"
    local start end
    start=$(date +%s%3N)
    curl -s --max-time 3 --dns-servers "$dns" -o /dev/null -w '' 2>/dev/null http://www.google.com || \
    nslookup google.com "$dns" > /dev/null 2>&1
    end=$(date +%s%3N)
    echo $((end - start))
}

select_dns() {
    local fastest_dns="1.1.1.1"
    local fastest_time=9999

    local dns_list=(
        "1.1.1.1#Cloudflare"
        "8.8.8.8#Google"
        "223.5.5.5#AliDNS"
    )

    for entry in "${dns_list[@]}"; do
        local dns="${entry%%#*}"
        local name="${entry##*#}"
        local latency
        latency=$(time_dns "$dns" 2>/dev/null)
        if [ -n "$latency" ] && [ "$latency" -lt "$fastest_time" ]; then
            fastest_time="$latency"
            fastest_dns="$dns"
        fi
    done

    echo "${fastest_dns} ${fastest_time}"
}

read DNS FASTEST_TIME <<< $(select_dns)
echo "🌐 首选 DNS: $DNS (延迟: ${FASTEST_TIME}ms)"

echo "nameserver $DNS" > /etc/resolv.conf
echo "nameserver 127.0.0.11" >> /etc/resolv.conf
