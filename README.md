# 🥝 vh-warp

> Lightweight Docker image powered by Cloudflare WARP. One-click deploy privacy protection + network acceleration. Supports Free / Plus / Teams accounts.

[![GHCR](https://img.shields.io/badge/GHCR-lazzman%2Fvh--warp-blue)](https://github.com/lazzman/vh-warp/pkgs/container/vh-warp) [中文文档](#中文文档)

## ✨ Features

- 🚀 **One-click Deploy** — Docker Compose single command startup, auto-registers free tier on first run, truly zero-config
- 🔒 **Privacy Protection** — Cloudflare WARP encrypted tunnel, hides real IP, prevents tracking
- ⚡ **Network Acceleration** — WARP global edge network, lower latency, better connection experience
- 🔄 **Dual-Protocol Proxy** — Mixed SOCKS5 + HTTP on single port 1111, auto-detects protocol
- 👤 **Multi-Account** — WARP Free / WARP+ (License Key) / Teams (Zero Trust)
- 💓 **Self-Healing** — Built-in heartbeat monitoring, 4-level progressive auto-recovery, GOST process auto-restart
- 🔔 **Instant Notifications** — Optional PushDeer push for disconnection, recovery, and emergency events
- 🎮 **Interactive Menu** — `vhwarp` config tool, full menu-driven, beginner-friendly
- 🖥️ **Multi-Arch** — amd64 / arm64, works on servers, routers, and Raspberry Pi
- 📏 **Log Control** — Auto-rotated, keeps latest 3MB, ideal for low-memory environments
- 🩺 **Docker Health Check** — Built-in HEALTHCHECK reports proxy status; recovery is handled by the in-container watchdog
- 🚅 **GOST Optimized** — UDP proxy, Nagle disabled, 32KB read/write buffers, 120s idle timeout, TCP keepalive (memory-friendly multi-instance defaults)
- 🧩 **Multi-Instance** — `INSTANCE_COUNT` spawns N isolated WARP+GOST stacks (netns), ports auto-increment
- ⚖️ **Load Balancer** — Unified port `1110` with round / random / hash / rotate strategies; route by id via `socks5h://{id}@host:1110`
- 🔄 **Rolling Restart** — When `INSTANCE_COUNT>=4`, hard-restarts instances one by one every 6h; waits for `warp=on` before the next; overlapping rounds are skipped
- 🌐 **IP Version Preference** — `PREFER_IPV4=1` or `PREFER_IPV6=1` makes GOST select A or AAAA for dual-stack hosts

## 🚀 Quick Start

### 🐳 Pull from GHCR (Recommended)

```bash
# Download docker-compose.yml
wget https://raw.githubusercontent.com/lazzman/vh-warp/main/docker-compose.yml
# Start
docker compose up -d
```

### 🔨 Build Locally

```bash
git clone https://github.com/lazzman/vh-warp.git
cd vh-warp
docker compose -f docker-compose.build.yml build
docker compose -f docker-compose.build.yml up -d
```

> 💡 **Docker Desktop users on Mac should use [OrbStack](https://orbstack.dev/) or [Colima](https://github.com/abiosoft/colima)**. Docker Desktop does not support `/dev/net/tun`, which prevents WARP from starting.

## ⚙️ Configuration

The container auto-registers WARP Free tier on first startup. To switch to WARP+ or Teams, use `vhwarp`:

```bash
docker exec -it vh-warp vhwarp
```

```
  ██╗   ██╗██╗  ██╗       ██╗    ██╗ █████╗ ██████╗ ██████╗
  ██║   ██║██║  ██║       ██║    ██║██╔══██╗██╔══██╗██╔══██╗
  ██║   ██║███████║       ██║ █╗ ██║███████║██████╔╝██████╔╝
  ╚██╗ ██╔╝██╔══██║       ██║███╗██║██╔══██║██╔══██╗██╔═══╝
   ╚████╔╝ ██║  ██║       ╚███╔███╔╝██║  ██║██║  ██║██║
    ╚═══╝  ╚═╝  ╚═╝        ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝
  ─────────────────────────────────────────────────────────
    ☁️  Cloudflare WARP Privacy · Network Acceleration
  ─────────────────────────────────────────────────────────

  +==============================================+
  |           vh-warp Config Tool               |
  +==============================================+
  |  1)  WARP Free          MASQUE, no account   |
  |  2)  Teams / Zero Trust  Enter Token URL     |
  |  3)  WARP+ (License Key) Enter License Key   |
  |  4)  View Status                             |
  |  5)  Reset & Clean                           |
  |  6)  PushDeer Notification                   |
  |  0)  Exit                                    |
  +==============================================+

  Select [0-6]:
```

![proxy](proxy.png)

## 🌐 Proxy Usage

### Single instance (default)

```
SOCKS5:  192.168.x.x:1111
HTTP:    192.168.x.x:1111
```

> Port 1111 is Mixed mode — same port supports both HTTP and SOCKS5. UDP proxy is enabled.

### Multi-instance + load balancing

```bash
# .env or compose environment
INSTANCE_COUNT=3
BASE_PORT=1111
LB_PORT=1110
LB_STRATEGY=round   # round | random | hash | rotate
```

| Access | Address | Notes |
|------|------|------|
| Load balancer | `host:1110` | Distributes across all healthy instances |
| Instance 0 | `host:1111` | Direct to instance 0 |
| Instance 1 | `host:1112` | Direct to instance 1 |
| Instance N | `host:1111+N` | Direct to instance N |

**ID 路由**（同一 id → 同一后端）：

```bash
# SOCKS5: username is the routing id (password ignored)
socks5h://session-alice@192.168.x.x:1110
socks5h://42@192.168.x.x:1110

# HTTP proxy with basic user
http://session-alice@192.168.x.x:1110
```

When a username/id is present, traffic uses Rendezvous hashing for a stable backend in `round` / `random` / `hash`. `rotate` ignores the username for backend selection so that every new connection uses the same backend during a time window.

**Data isolation**: each instance stores WARP registration under `/var/lib/cloudflare-warp/instances/<id>/` (single-instance mode still uses the volume root for backward compatibility).

```bash
# Configure a specific instance
docker exec -it vh-warp vhwarp -i 1
```

### Verify WARP exit IP

After the proxy is up, confirm traffic actually goes through Cloudflare WARP:

```bash
# Primary check (same probe used by health-check)
curl -s --socks5-hostname 127.0.0.1:1111 https://www.cloudflare.com/cdn-cgi/trace

# Alternate endpoint
curl -s --socks5-hostname 127.0.0.1:1111 https://one.one.one.one/cdn-cgi/trace

# HTTP proxy form
curl -s -x http://127.0.0.1:1111 https://www.cloudflare.com/cdn-cgi/trace

# Compare direct vs WARP exit IP
curl -s https://ifconfig.me; echo
curl -s --socks5-hostname 127.0.0.1:1111 https://ifconfig.me; echo

# Multi-instance / load balancer
curl -s --socks5-hostname 127.0.0.1:1110 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
curl -s --socks5-hostname 127.0.0.1:1112 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
```

Key fields in the trace output:

| Field | Meaning |
|------|------|
| `ip=...` | WARP egress IP |
| `warp=on` | Free WARP tunnel active |
| `warp=plus` | WARP+ active |
| `warp=off` | Not through WARP (likely host direct) |
| `colo=...` | Cloudflare PoP |

Healthy result: `warp=on` or `warp=plus`, and the proxy exit IP differs from the host direct IP.

## 💓 Health Check & Auto-Recovery

The container runs a built-in self-healing daemon that continuously monitors `warp=on` and automates recovery for the entire chain:

| 🔁 Consecutive Failures | 🛠️ Action | 📢 PushDeer Notification |
|:---:|------|------|
| 1 | 📝 Log, check GOST process | 🟡 "WARP check failed..." |
| 2 | 🔧 Auto-restart GOST | — |
| 3 | 🔄 Soft reconnect `disconnect → connect` | 🔧 "WARP soft reconnect" |
| Unavailable for 10 min | 💥 Verify direct Internet, retry current registration, then fall back to Free | ✅ "WARP recovered as Free" |

When proxy checks fail, the watchdog first verifies GOST and tries two independent WARP trace endpoints. It preserves the current registration during transient failures and soft reconnects. Before falling back, it disconnects WARP and verifies that the host's direct Internet works, then makes one final attempt with the original registration.

If WARP remains unavailable for 10 minutes while direct Internet is healthy, the watchdog falls back to Free to restore service. WARP+/Teams credentials are not stored and are not automatically restored. If Free registration is temporarily unavailable, GOST remains available through the host's direct connection and registration retries use backoff. Traffic may therefore expose the host egress IP during recovery. Set `HEALTH_FALLBACK_AFTER` to adjust the fallback delay.

Cloudflare One Client 2026.6 and later requires outbound HTTPS access to `api.devices.cloudflare.com` for registration and settings. MASQUE also requires working UDP/HTTP3 connectivity.

## 🔄 Scheduled Rolling Restart

When `INSTANCE_COUNT >= 4` (or `ROTATE_RESTART_ENABLED=1`), a daemon hard-restarts instances **one at a time** on a fixed interval (default `6h`):

1. Mark the backend `down` so the load balancer drains it
2. Wait for LB-tracked connections to close (default max `120s`), then continue even on timeout
3. Full `instance-ctl restart` (netns + warp-svc + gost), **keeping the current WARP registration**
4. Probe the instance direct port until `warp=on` / `warp=plus` (default 90s)
5. Only then restart the next instance
6. A failed instance is retried twice, then skipped; the round continues
7. If the previous round is still running when the next tick fires, that tick is **dropped** (not queued)

The first round waits one full interval after container start. Health checks skip the instance currently being rotated.

```bash
docker exec -it vh-warp rotate-restart status
docker exec -it vh-warp tail -f /var/log/warp-gost/rotate-restart.log
# Manual one-shot (respects the single-flight lock)
docker exec -it vh-warp rotate-restart once
```

## 🔔 PushDeer Notifications

Enter the config menu **6) PushDeer Notification** to set your PushKey:

1. 📲 Install the [PushDeer App](https://www.pushdeer.com/)
2. 🔑 Get your PushKey from the App
3. 📝 Enter the PushKey in vhwarp — a test notification confirms the setup

Once configured, all disconnect, reconnect, emergency, and recovery events are pushed to your phone in real time 📱

## 📋 Logs

Logs are stored in `/var/log/warp-gost/`, capped at 3MB per file with auto-rotation:

| 📄 File | 📝 Content |
|------|------|
| `warp-svc.log` | Cloudflare WARP service log |
| `gost.log` | GOST proxy service log |
| `health-check.log` | 💓 Health check log |
| `rotate-restart.log` | 🔄 Scheduled rolling restart log |
| `vhwarp.log` | ⚙️ Config tool operation log |
| `entrypoint.log` | 🚀 Container startup log |
```bash
# View health check logs in real time
docker exec -it vh-warp tail -f /var/log/warp-gost/health-check.log
```

## 📦 Docker Run

```bash
# Single instance
docker run -d \
  --name vh-warp \
  --restart=always \
  --memory=4g \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --device=/dev/net/tun \
  -p 1111:1111 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -v warp-data:/var/lib/cloudflare-warp \
  ghcr.io/lazzman/vh-warp:latest

# 3 instances + load balancer
docker run -d \
  --name vh-warp \
  --restart=always \
  --memory=4g \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --cap-add=SYS_ADMIN \
  --device=/dev/net/tun \
  -p 1110-1113:1110-1113 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv4.ip_forward=1 \
  -e INSTANCE_COUNT=3 \
  -e BASE_PORT=1111 \
  -e LB_PORT=1110 \
  -e LB_STRATEGY=round \
  -v warp-data:/var/lib/cloudflare-warp \
  ghcr.io/lazzman/vh-warp:latest
```

> Default timezone is `Asia/Shanghai`. Override with `-e TZ=Europe/London`. After WARP connects, all DNS traffic goes through the tunnel — no extra system DNS config needed.

### Environment variables

| Variable | Default | Description |
|------|------|------|
| `INSTANCE_COUNT` | `1` | Number of instances (1–32) |
| `BASE_PORT` | `1111` | Direct port for instance 0 (then +1 each) |
| `LB_PORT` | `1110` | Load balancer listen port |
| `LB_STRATEGY` | `round` | `round` / `random` / `hash` / `rotate` |
| `LB_ROTATE_INTERVAL` | `5m` | `rotate` 切换间隔；裸数字按分钟，支持 `5m` / `300s` / `1h` |
| `LB_ENABLED` | `auto` | `auto` enables LB when count>1; `1`/`0` forces |
| `HEALTH_CHECK_INTERVAL` | `60` | Health check interval (seconds) |
| `HEALTH_SOFT_FAILURES` | `3` | Failures before soft reconnect |
| `HEALTH_FALLBACK_AFTER` | `600` | Seconds before Free fallback |
| `STATUS_EVENT_LOG` | `1` | 每轮健康检测输出完整状态表到 `docker logs`；本轮变化实例标记 `🔄`，`0` 时仅写入健康检测日志 |
| `ROTATE_RESTART_ENABLED` | `auto` | `auto` enables when count≥4; `1`/`0` forces |
| `ROTATE_RESTART_INTERVAL` | `6h` | Whole-round interval (`30m` / `6h` / `12h` / seconds) |
| `ROTATE_RESTART_PROBE_TIMEOUT` | `90` | Seconds to wait for `warp=on` after each restart |
| `ROTATE_RESTART_RETRIES` | `2` | Extra hard-restart attempts per instance before skip |
| `ROTATE_RESTART_DRAIN_TIMEOUT` | `120` | LB 摘流后等待已有连接结束的最长时间；`0` 关闭等待 |
| `UPSTREAM_SOCKS5` | _(empty)_ | Optional upstream SOCKS5 for WARP dial (`socks5://user:pass@host:port`) |
| `UPSTREAM_SOCKS5_UDP` | `udp` | `udp` or `tcp`; MASQUE needs real UDP |
| `UPSTREAM_MTU` | `1280` | TUN MTU for hev-socks5-tunnel |
| `GOST_IDLE_TIMEOUT` | `120s` | GOST idle connection timeout |
| `GOST_READ_BUFFER` | `32768` | GOST per-conn read buffer (bytes) |
| `GOST_WRITE_BUFFER` | `32768` | GOST per-conn write buffer (bytes) |
| `GOST_BACKLOG` | `1024` | GOST listen backlog |
| `LB_IDLE_TIMEOUT` | `120` | LB relay idle timeout (seconds) |
| `PREFER_IPV4` | `0` | `1` selects IPv4 (A) for dual-stack destinations |
| `PREFER_IPV6` | `0` | `1` selects IPv6 (AAAA) for dual-stack destinations |

Set at most one of `PREFER_IPV4` and `PREFER_IPV6`. If both are `1`, IPv4 takes precedence. For a dual-stack destination, a failed TCP connection does not automatically retry the other address family.

### Memory sizing

Each instance runs a full `warp-svc` + dual `gost` (in-netns + host forward). Memory is mostly **baseline**, not live connections.

| `INSTANCE_COUNT` | Typical RSS (after traffic) | Suggested `--memory` / `mem_limit` |
|------------------|-----------------------------|-----------------------------------|
| 1 | 0.3–0.6 GB | `1g` |
| 3 | 1.0–1.5 GB | `2g` |
| 5 | 1.5–2.5 GB | `3g` |
| 10 | 2.5–3.5 GB | `4g` (compose default) |
| 16+ | ≈ 0.3 GB × N | `6g+` |

> Compose default `mem_limit: 4g` is a **cap**, not a reservation. Raise it if `docker stats` approaches the limit; lower instance count is the main way to save RAM. `warp-svc` RSS rarely shrinks without process restart.

### Upstream SOCKS5 (WARP dial via node)

Optional: build the WARP tunnel **through** a SOCKS5 node (`TUN → hev → SOCKS5`).

```bash
# .env
UPSTREAM_SOCKS5=socks5://user:pass@192.168.1.2:1086
```

Final app exit IP remains **Cloudflare WARP**, not the node IP. Node must support SOCKS5 UDP. Verify with `poc/upstream-socks5-tun-poc.sh`.

```bash
docker exec vh-warp upstream-setup status
```

## 🩺 Troubleshooting

```bash
# Check WARP connection status
docker exec -it vh-warp warp-cli status

# View health check history
docker exec -it vh-warp cat /var/log/warp-gost/health-check.log

# View Docker health status
docker inspect --format='{{.State.Health.Status}}' vh-warp

# Collect official Cloudflare diagnostics
docker exec -it vh-warp warp-diag

# Reset everything and start over
docker exec -it vh-warp vhwarp
# → Select "5) Reset & Clean"
```

---

## 中文文档

## ✨ 特性

- 🚀 **一键部署** — Docker Compose 一行命令启动，首次自动注册免费版，真正零配置
- 🔒 **隐私保护** — Cloudflare WARP 加密隧道，隐藏真实 IP，防止追踪
- ⚡ **网络加速** — WARP 全球边缘网络，降低延迟，提升连接体验
- 🔄 **双协议代理** — Mixed SOCKS5 + HTTP，单端口 1111 自动识别协议
- 👤 **多账号支持** — WARP Free / WARP+ (License Key) / Teams (Zero Trust)
- 💓 **断线自愈** — 内置心跳检测，四级渐进式自动恢复链路，GOST 进程自动重启
- 🔔 **即时通知** — 可选 PushDeer 推送，断线、恢复、急救实时报信
- 🎮 **交互菜单** — `vhwarp` 配置工具，全菜单操作，新手友好
- 🖥️ **多架构适配** — amd64 / arm64，服务器、软路由、树莓派均可运行
- 📏 **日志可控** — 自动轮转保留最新 3MB，适合低内存环境
- 🩺 **Docker 健康检查** — 内置 HEALTHCHECK 上报代理状态，容器内守护进程负责恢复
- 🚅 **GOST 优化** — UDP 代理、Nagle 禁用、读写缓冲 32KB、空闲 120s 回收、TCP keepalive（多实例内存友好默认）
- 🧩 **多实例** — `INSTANCE_COUNT` 启动 N 套隔离的 WARP+GOST（netns），端口自动递增
- ⚖️ **负载均衡** — 统一入口 `1110`，支持逐请求轮询/随机/哈希/粘性/定时统一轮换；`socks5h://{id}@host:1110` 固定后端
- 🔄 **定时滚动重启** — `INSTANCE_COUNT>=4` 时每 6 小时逐台硬重启；探针 `warp=on` 后才动下一台；叠轮直接忽略
- 🌐 **IP 版本优先** — `PREFER_IPV4=1` 或 `PREFER_IPV6=1` 时，GOST 对双栈域名选用 A 或 AAAA

## 🚀 快速开始

### 🐳 直接拉取 GHCR（推荐）

```bash
# 下载 docker-compose.yml
wget https://raw.githubusercontent.com/lazzman/vh-warp/main/docker-compose.yml
# 启动
docker compose up -d
```

### 🔨 本地构建

```bash
git clone https://github.com/lazzman/vh-warp.git
cd vh-warp
docker compose -f docker-compose.build.yml build
docker compose -f docker-compose.build.yml up -d
```

> 💡 **Mac 上的 Docker Desktop 用户建议使用 [OrbStack](https://orbstack.dev/) 或 [Colima](https://github.com/abiosoft/colima)**，Docker Desktop 不支持 `/dev/net/tun`，会导致 WARP 无法正常启动。

## ⚙️ 配置

容器首次启动时自动注册 WARP 免费版，开箱即用。如需切换 WARP+ 或 Teams，使用 `vhwarp`：

```bash
docker exec -it vh-warp vhwarp
```

```
  ██╗   ██╗██╗  ██╗       ██╗    ██╗ █████╗ ██████╗ ██████╗
  ██║   ██║██║  ██║       ██║    ██║██╔══██╗██╔══██╗██╔══██╗
  ██║   ██║███████║       ██║ █╗ ██║███████║██████╔╝██████╔╝
  ╚██╗ ██╔╝██╔══██║       ██║███╗██║██╔══██║██╔══██╗██╔═══╝
   ╚████╔╝ ██║  ██║       ╚███╔███╔╝██║  ██║██║  ██║██║
    ╚═══╝  ╚═╝  ╚═╝        ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝
  ─────────────────────────────────────────────────────────
    ☁️  Cloudflare WARP 隐私保护 · 网络加速
  ─────────────────────────────────────────────────────────

  +==============================================+
  |              vh-warp 配置工具                |
  +==============================================+
  |  1)  WARP 免费版       MASQUE 协议，无需账号  |
  |  2)  Teams / Zero Trust  输入 Token URL       |
  |  3)  WARP+ (License Key)  输入 License Key    |
  |  4)  查看当前状态                             |
  |  5)  重置并清理配置                           |
  |  6)  PushDeer 断线通知                        |
  |  0)  退出                                    |
  +==============================================+

  请选择 [0-6]:
```

![proxy](proxy.png)

## 🌐 使用代理

### 单实例（默认）

```
SOCKS5:  192.168.x.x:1111
HTTP:    192.168.x.x:1111
```

> 端口 1111 为 Mixed 模式，同一端口同时支持 HTTP 和 SOCKS5。已启用 UDP 代理。

### 多实例 + 负载均衡

```bash
# .env 或 compose environment
INSTANCE_COUNT=3
BASE_PORT=1111
LB_PORT=1110
LB_STRATEGY=round   # round | random | hash | rotate
```

| 访问方式 | 地址 | 说明 |
|------|------|------|
| 负载均衡入口 | `主机:1110` | 在健康实例间分发 |
| 实例 0 直连 | `主机:1111` | 固定走实例 0 |
| 实例 1 直连 | `主机:1112` | 固定走实例 1 |
| 实例 N 直连 | `主机:1111+N` | 固定走实例 N |

**粘性代理**（同一 id → 同一后端）：

```bash
# SOCKS5：用户名即粘性 id（密码任意/可空）
socks5h://session-alice@192.168.x.x:1110
socks5h://42@192.168.x.x:1110

# HTTP 代理
http://session-alice@192.168.x.x:1110
```

除 `rotate` 外，只要带了用户名/id，就会按 id 的 **Rendezvous（最高随机权重）哈希**固定到后端，与 `LB_STRATEGY` 无关；不带用户名时按 round/random/hash（客户端 IP）调度。该算法使大量离散 id 在等权实例间趋于均匀，并在实例增减时只迁移必要会话，避免哈希取模造成的大面积重映射。

#### 策略特性表

所有策略只影响通过负载均衡入口建立的**新 TCP 代理连接**；已建立连接不会被中途迁移，直连实例端口不会经过负载均衡。

| 策略 | 未提供用户名/id | 提供用户名/id | 路由依据 | id 数量分布 | 实例增减时的迁移 | 适用场景 |
|------|----------------|---------------|----------|-------------|------------------|----------|
| `round`（默认） | 按新连接依次选择下一个健康实例 | 按 id 的 Rendezvous 哈希 | 有 id 按 id；无 id 不保持会话 | 有 id 时趋于均匀；无 id 时新连接数轮询均分 | 有 id 时仅迁移必要 id；无 id 无会话迁移概念 | 通用默认场景 |
| `random` | 每个新连接随机选择健康实例 | 按 id 的 Rendezvous 哈希 | 有 id 按 id；无 id 不保持会话 | 有 id 时趋于均匀；无 id 大量连接下概率趋于均匀 | 有 id 时仅迁移必要 id；无 id 无会话迁移概念 | 无状态请求的随机分散 |
| `hash` | 按客户端 IP 的 Rendezvous 哈希 | 按 id 的 Rendezvous 哈希 | 有 id 优先按 id；无 id 按客户端 IP | 大量不同 id/IP 时趋于均匀 | 仅迁移原目标下线或应落到新增实例的 id/IP | 同一来源 IP 或 id 需要稳定出口 |
| `rotate` | 当前时间窗口内统一走同一个健康实例 | 忽略 id，仍统一走当前窗口实例 | 全局时间窗口 | 不追求同一时刻的实例间均衡；按时间轮换 | 当前目标摘流时故障转移；恢复后当前窗口不回跳 | 所有新请求每 N 分钟统一切换出口 |

**均衡含义**：`round` 均衡的是新连接数量；`random` 均衡的是大量连接的概率分布；`hash` 和带 id 的 `round` / `random` 均衡的是大量离散 id（或 IP）的数量，而不考虑单个 id 的业务流量；`rotate` 刻意让一个时间窗口内的新连接集中到同一实例。

**id 路由优先级**：除 `rotate` 外，只要 SOCKS5 用户名或 HTTP Basic Auth 用户名携带 id，就优先使用 id 的 Rendezvous 哈希。该算法在健康实例集合不变时保持稳定；新增实例时，发生迁移的 id 只会迁移到新增实例；移除实例时，仅原本落在被移除实例上的 id 会迁移。

**滚动重启**：所有策略都使用同一套摘流与排空流程。实例重启前先从 LB 候选中移除，等待该实例已有的 LB 连接自然结束（由 `ROTATE_RESTART_DRAIN_TIMEOUT` 控制，默认 `120` 秒），随后才重启；绕过 LB 的实例直连流量无法被该排空机制统计。

**定时统一轮换**：将策略设置为 `rotate` 后，负载均衡从启动时开始计时，每个时间窗口内所有**新建连接**都固定走同一个健康实例；窗口到期后，所有新建连接统一切到下一个健康实例。默认间隔为 5 分钟：

```bash
LB_STRATEGY=rotate
LB_ROTATE_INTERVAL=5m
```

`LB_ROTATE_INTERVAL` 支持 `5m`、`300s`、`1h` 等时长；不带单位的数字按分钟处理，例如 `5` 等同于 `5m`。已建立的 TCP 连接不会中途迁移或断开，下一次新建连接才会按当前窗口选择后端。`rotate` 为保证同一窗口内统一出口，会忽略 SOCKS5/HTTP 用户名的粘性映射。定时滚动重启只会将正在重启的实例临时摘流：如果它正好是当前轮换目标，才会故障转移到下一个健康实例；实例恢复后不会在当前时间窗口内回跳，轮换计时也不会重置。

**数据隔离**：多实例注册数据位于 `/var/lib/cloudflare-warp/instances/<id>/`（单实例仍使用 volume 根目录，兼容旧数据）。

```bash
# 配置指定实例
docker exec -it vh-warp vhwarp -i 1

# 三实例示例
INSTANCE_COUNT=3 docker compose up -d
```

> 多实例依赖网络命名空间（`CAP_SYS_ADMIN` + `ip_forward`）。若 netns 创建失败，可在 compose 中临时加 `privileged: true` 排查。

### 验证 WARP 出口 IP

代理启动后，可用以下命令确认流量已经走 Cloudflare WARP：

```bash
# 主推荐（与容器内健康检测相同）
curl -s --socks5-hostname 127.0.0.1:1111 https://www.cloudflare.com/cdn-cgi/trace

# 备用端点
curl -s --socks5-hostname 127.0.0.1:1111 https://one.one.one.one/cdn-cgi/trace

# HTTP 代理写法
curl -s -x http://127.0.0.1:1111 https://www.cloudflare.com/cdn-cgi/trace

# 对比直连与 WARP 出口 IP
curl -s https://ifconfig.me; echo
curl -s --socks5-hostname 127.0.0.1:1111 https://ifconfig.me; echo

# 多实例 / 负载均衡
curl -s --socks5-hostname 127.0.0.1:1110 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
curl -s --socks5-hostname 127.0.0.1:1112 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
```

trace 输出关键字段：

| 字段 | 含义 |
|------|------|
| `ip=...` | WARP 出口 IP |
| `warp=on` | Free WARP 隧道已生效 |
| `warp=plus` | WARP+ 已生效 |
| `warp=off` | 未走 WARP（可能是主机直连） |
| `colo=...` | Cloudflare 机房 |

正常判定：`warp=on` 或 `warp=plus`，且代理出口 IP 与本机直连 IP 不同。

### 启动横幅的就绪状态

容器启动时会对所有实例**并行**输出一份真实状态快照，而不是将探测失败统一显示为 `n/a`。示例：

```text
✅ 实例0  :1111  已就绪  IP=104.28.x.x                              WARP=on   LAX
⏳ 实例1  :1112  建连中  CLI=connecting
⚠️  实例2  :1113  直连中  IP=203.0.113.x                             WARP=off
```

| `readiness` | 含义与处理 |
|---|---|
| `ready` | 代理 trace 已确认 `warp=on` 或 `warp=plus`；这是唯一已验证可承载 WARP 流量的状态。 |
| `waiting` | `warp-svc`/GOST 已启动，但 WARP 尚在连接或未连接；首次注册、多实例并发启动时常见，健康检测会继续重试。 |
| `direct` | trace 请求成功但 `warp=off`，当前流量未走 WARP；不要将它当作 WARP 出口。 |
| `probe_failed` | CLI 看起来已连接或无法确认，但两个 trace 端点都失败；查看输出中的 `endpoint`、`curl_rc`、`error` 定位网络、代理或端点问题。 |
| `service_down` | `warp-svc` 或 GOST 进程未运行，应查看实例日志。 |

启动末尾还会输出汇总。`account` 与 `cli` 来自同一实例私有命名空间中的 `warp-cli`，`trace=ok` 则是经该实例代理完成的实际流量验证。完整机器记录（端点、curl 返回码和原始错误）写入 `entrypoint.log`，也可通过 `instance-ctl status` 查询。

健康检测会继续监控状态。每轮检查完成后会输出一张完整、简短的状态表；状态发生变化的实例会标记为 `🔄`，首次观测标记为 `🆕`，定时滚动重启而跳过检测的实例标记为 `⏸️`。完整机器记录仍保留在健康检测日志中。

```text
[2026-08-14 15:06:12] 📊 WARP 健康状态第 2 轮（🔄 本轮变化 · 未变化 🆕 首次 ⏸️ 跳过）
  ·  ✅ 实例0  :1111  已就绪  IP=104.28.x.x                              WARP=on   LAX
  🔄 ⚠️  实例6  :1117  探测失败  CLI=connected    原因=探测超时
  汇总：ready=8 waiting=1 direct=0 probe_failed=1 service_down=0 skipped=0
```

默认 `STATUS_EVENT_LOG=1`，每轮都会输出状态表；若只希望保留文件日志，可设置 `STATUS_EVENT_LOG=0`。

```bash
docker logs -f vh-warp
```

## 💓 心跳检测与自愈

容器内置断线自愈守护进程，后台持续检测 `warp=on`，自动化恢复整条链路：

| 🔁 连续失败 | 🛠️ 动作 | 📢 PushDeer 通知 |
|:---:|------|------|
| 1 | 📝 记录日志，检测 GOST 进程存活 | 🟡 "WARP 检测异常..." |
| GOST 异常 | 🔧 自动重启 GOST | — |
| 3 | 🔄 软重连 `disconnect → connect` | 🔧 "WARP 软重连" |
| 持续不可用 10 分钟 | 💥 验证直连、最后重试原注册，再回退 Free | ✅ "WARP 已恢复为 Free" |

代理检测失败时先检查 GOST，并使用两个独立 WARP trace 端点复核。短暂异常只执行保留注册的软重连。回退前会断开 WARP 验证宿主直连网络，再使用原注册做最后一次连接尝试；宿主网络本身异常时不会删除注册。

当 WARP 持续不可用 10 分钟、宿主直连正常且原注册最后重连仍失败时，系统才回退到 Free。WARP+/Teams 凭据不会保存，也不会自动恢复。Free 注册 API 暂时不可用时，GOST 保持宿主直连并使用退避策略重试；恢复期间流量可能暴露服务器真实出口 IP。可通过 `HEALTH_FALLBACK_AFTER` 调整回退时间。

Cloudflare One Client 2026.6 及更高版本注册和同步设置需要放行 `api.devices.cloudflare.com` 的出站 HTTPS；MASQUE 还要求 UDP/HTTP3 网络可用。

## 🔄 定时滚动重启

当 `INSTANCE_COUNT >= 4`（或 `ROTATE_RESTART_ENABLED=1`）时，守护进程按固定间隔（默认 `6h`）**逐台**硬重启：

1. 将该后端标 `down`，负载均衡先摘流
2. 等待 LB 记录的现有连接自然结束（默认最多 `120s`；超时仍继续）
3. 完整 `instance-ctl restart`（netns + warp-svc + gost），**保留当前 WARP 注册**
4. 对实例直连端口探针，直到 `warp=on` / `warp=plus`（默认 90s）
5. 成功后才重启下一台
6. 失败则再试 2 次，仍失败就跳过并继续
7. 上一轮还没跑完就到点，**整轮丢弃**（不排队）

容器启动后，定时滚动重启日志会**同时打到 Docker 控制台**和 `/var/log/warp-gost/rotate-restart.log` 文件（支持滚动截断）。

```bash
docker exec -it vh-warp rotate-restart status
docker exec -it vh-warp tail -f /var/log/warp-gost/rotate-restart.log
# 手动跑一轮（受单飞锁约束，与定时轮重叠则忽略）
docker exec -it vh-warp rotate-restart once
```

## 🔔 PushDeer 通知

进入配置菜单 **6) PushDeer 断线通知** 设置 PushKey：

1. 📲 安装 [PushDeer App](https://www.pushdeer.com/)
2. 🔑 在 App 中获取 PushKey
3. 📝 在 vhwarp 中输入 PushKey，自动发送测试通知确认

配置后，所有断线、重连、急救、恢复事件均实时推送到你手机 📱

## 📋 日志

日志保存在 `/var/log/warp-gost/`，单文件上限 3MB 自动截断：

| 📄 文件 | 📝 内容 |
|------|------|
| `warp-svc.log` | Cloudflare WARP 服务日志 |
| `gost.log` | GOST 代理服务日志 |
| `health-check.log` | 💓 心跳检测日志 |
| `rotate-restart.log` | 🔄 定时滚动重启日志（同时输出到控制台）
| `vhwarp.log` | ⚙️ 配置工具操作日志 |
| `entrypoint.log` | 🚀 容器启动日志 |

```bash
# 实时查看健康检测日志
docker exec -it vh-warp tail -f /var/log/warp-gost/health-check.log
```

## 📦 Docker Run

```bash
# 单实例
docker run -d \
  --name vh-warp \
  --restart=always \
  --memory=4g \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --device=/dev/net/tun \
  -p 1111:1111 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -v warp-data:/var/lib/cloudflare-warp \
  ghcr.io/lazzman/vh-warp:latest

# 三实例 + 负载均衡
docker run -d \
  --name vh-warp \
  --restart=always \
  --memory=4g \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --cap-add=SYS_ADMIN \
  --device=/dev/net/tun \
  -p 1110-1113:1110-1113 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv4.ip_forward=1 \
  -e INSTANCE_COUNT=3 \
  -e BASE_PORT=1111 \
  -e LB_PORT=1110 \
  -e LB_STRATEGY=round \
  -v warp-data:/var/lib/cloudflare-warp \
  ghcr.io/lazzman/vh-warp:latest
```

> 镜像默认时区 `Asia/Shanghai`，可通过 `-e TZ=Europe/London` 覆盖。WARP 连接后 DNS 全部走隧道，无需额外配系统 DNS。

### 环境变量一览

| 变量 | 默认 | 说明 |
|------|------|------|
| `INSTANCE_COUNT` | `1` | 实例数量（1–32） |
| `BASE_PORT` | `1111` | 实例 0 直连端口，其后递增 |
| `LB_PORT` | `1110` | 负载均衡入口 |
| `LB_STRATEGY` | `round` | `round` / `random` / `hash` / `rotate` |
| `LB_ROTATE_INTERVAL` | `5m` | `rotate` 切换间隔；裸数字按分钟，支持 `5m` / `300s` / `1h` |
| `LB_ENABLED` | `auto` | `auto` 在多实例时启用；`1`/`0` 强制 |
| `HEALTH_CHECK_INTERVAL` | `60` | 健康检测间隔（秒） |
| `HEALTH_SOFT_FAILURES` | `3` | 触发软重连的连续失败次数 |
| `HEALTH_FALLBACK_AFTER` | `600` | 回退 Free 的持续失败时间（秒） |
| `STATUS_EVENT_LOG` | `1` | 每轮健康检测同步输出完整状态表到 `docker logs`；本轮变化实例标记 `🔄`，`0` 仅写入健康检测日志 |
| `ROTATE_RESTART_ENABLED` | `auto` | `auto` 在实例数≥4 时启用；`1`/`0` 强制 |
| `ROTATE_RESTART_INTERVAL` | `6h` | 整轮间隔（`30m` / `6h` / `12h` / 纯秒） |
| `ROTATE_RESTART_PROBE_TIMEOUT` | `90` | 单台重启后等待 `warp=on` 的秒数 |
| `ROTATE_RESTART_RETRIES` | `2` | 本台失败后的额外硬重启次数 |
| `ROTATE_RESTART_DRAIN_TIMEOUT` | `120` | LB 摘流后等待已有连接结束的最长时长；`0` 关闭等待 |
| `UPSTREAM_SOCKS5` | 空 | 可选，WARP 建连走的上游 SOCKS5 |
| `UPSTREAM_SOCKS5_UDP` | `udp` | `udp` / `tcp`；MASQUE 需要真 UDP |
| `UPSTREAM_MTU` | `1280` | 上游 TUN MTU |
| `GOST_IDLE_TIMEOUT` | `120s` | GOST 空闲连接超时 |
| `GOST_READ_BUFFER` | `32768` | GOST 单连接读缓冲（字节） |
| `GOST_WRITE_BUFFER` | `32768` | GOST 单连接写缓冲（字节） |
| `GOST_BACKLOG` | `1024` | GOST listen backlog |
| `LB_IDLE_TIMEOUT` | `120` | LB 转发空闲超时（秒） |
| `PREFER_IPV4` | `0` | `1` 双栈出站选用 IPv4（A） |
| `PREFER_IPV6` | `0` | `1` 双栈出站选用 IPv6（AAAA） |

`PREFER_IPV4` 与 `PREFER_IPV6` 最多开启一项；若同时设为 `1`，IPv4 优先。对于双栈目标，首选地址 TCP 建连失败时不会自动重试另一地址族。

### 内存估算

每个实例是完整的 `warp-svc` + 双 `gost`（netns 内 + 主机转发）。内存主要是**进程基线**，不是当前连接数。

| `INSTANCE_COUNT` | 典型 RSS（跑过流量后） | 建议 `--memory` / `mem_limit` |
|------------------|-------------------------|------------------------------|
| 1 | 0.3–0.6 GB | `1g` |
| 3 | 1.0–1.5 GB | `2g` |
| 5 | 1.5–2.5 GB | `3g` |
| 10 | 2.5–3.5 GB | `4g`（compose 默认） |
| 16+ | ≈ 0.3 GB × N | `6g+` |

> compose 默认 `mem_limit: 4g` 是**上限不是预留**。`docker stats` 接近上限就上调；想省内存优先减实例数。`warp-svc` 的 RSS 通常不重启进程就不会掉下来。

### 上游 SOCKS5（经节点建立 WARP 隧道）

可选：容器出站经 `TUN → hev-socks5-tunnel → SOCKS5 节点` 再连 Cloudflare。

```bash
# .env
UPSTREAM_SOCKS5=socks5://user:pass@192.168.1.2:1086
```

| 会变 | 不变 |
|------|------|
| WARP 注册/握手路径（走节点） | 业务最终出口 IP（仍是 Cloudflare WARP） |

节点需支持 **SOCKS5 UDP**。可先用 `poc/upstream-socks5-tun-poc.sh` 验证。

```bash
docker exec vh-warp upstream-setup status
```

## 🩺 故障排查

```bash
# 查看 WARP 连接状态
docker exec -it vh-warp warp-cli status

# 查看心跳检测历史
docker exec -it vh-warp cat /var/log/warp-gost/health-check.log

# 查看 Docker 健康状态
docker inspect --format='{{.State.Health.Status}}' vh-warp

# 收集 Cloudflare 官方诊断包
docker exec -it vh-warp warp-diag

# 重置所有配置并重新来过
docker exec -it vh-warp vhwarp
# → 选择 "5) 重置并清理配置"
```

---

## ☕ 捐赠支持

如果这个项目对你有帮助，欢迎请我喝杯咖啡～

![打赏](better.png)

> 感谢每一位 Sponsor，你的支持是我持续维护的动力 💪

---

## ⚠️ 免责声明

本项目仅供学习与技术研究使用。使用者应遵守所在国家/地区的法律法规，不得将此工具用于任何非法用途。项目作者不承担任何因使用本工具而产生的法律责任。

Cloudflare, the Cloudflare logo, and Cloudflare WARP are trademarks of Cloudflare, Inc. This project is not affiliated with, endorsed by, or sponsored by Cloudflare, Inc.

## 📜 License

MIT
