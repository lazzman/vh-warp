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
- ⚖️ **Load Balancer** — Unified port `1110` with round / random / hash / sticky strategies; sticky via `socks5h://{id}@host:1110`
- 🔄 **Rolling Restart** — When `INSTANCE_COUNT>=4`, hard-restarts instances one by one every 6h; waits for `warp=on` before the next; overlapping rounds are skipped
- 🌐 **IPv6 Priority** — `PREFER_IPV6=1` makes GOST resolve dual-stack hosts via AAAA first; IPv4-only sites still work

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
LB_STRATEGY=round   # round | random | hash | sticky
```

| Access | Address | Notes |
|------|------|------|
| Load balancer | `host:1110` | Distributes across all healthy instances |
| Instance 0 | `host:1111` | Direct to instance 0 |
| Instance 1 | `host:1112` | Direct to instance 1 |
| Instance N | `host:1111+N` | Direct to instance N |

**Sticky session** (same id → same backend):

```bash
# SOCKS5: username is the sticky id (password ignored)
socks5h://session-alice@192.168.x.x:1110
socks5h://42@192.168.x.x:1110

# HTTP proxy with basic user
http://session-alice@192.168.x.x:1110
```

When a username/id is present, traffic is always hashed to a fixed backend regardless of `LB_STRATEGY`. Without a username, `round` / `random` / `hash`(by client IP) apply.

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
2. Full `instance-ctl restart` (netns + warp-svc + gost), **keeping the current WARP registration**
3. Probe the instance direct port until `warp=on` / `warp=plus` (default 90s)
4. Only then restart the next instance
5. A failed instance is retried twice, then skipped; the round continues
6. If the previous round is still running when the next tick fires, that tick is **dropped** (not queued)

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
| `LB_STRATEGY` | `round` | `round` / `random` / `hash` / `sticky` |
| `LB_ENABLED` | `auto` | `auto` enables LB when count>1; `1`/`0` forces |
| `HEALTH_CHECK_INTERVAL` | `60` | Health check interval (seconds) |
| `HEALTH_SOFT_FAILURES` | `3` | Failures before soft reconnect |
| `HEALTH_FALLBACK_AFTER` | `600` | Seconds before Free fallback |
| `ROTATE_RESTART_ENABLED` | `auto` | `auto` enables when count≥4; `1`/`0` forces |
| `ROTATE_RESTART_INTERVAL` | `6h` | Whole-round interval (`30m` / `6h` / `12h` / seconds) |
| `ROTATE_RESTART_PROBE_TIMEOUT` | `90` | Seconds to wait for `warp=on` after each restart |
| `ROTATE_RESTART_RETRIES` | `2` | Extra hard-restart attempts per instance before skip |
| `UPSTREAM_SOCKS5` | _(empty)_ | Optional upstream SOCKS5 for WARP dial (`socks5://user:pass@host:port`) |
| `UPSTREAM_SOCKS5_UDP` | `udp` | `udp` or `tcp`; MASQUE needs real UDP |
| `UPSTREAM_MTU` | `1280` | TUN MTU for hev-socks5-tunnel |
| `GOST_IDLE_TIMEOUT` | `120s` | GOST idle connection timeout |
| `GOST_READ_BUFFER` | `32768` | GOST per-conn read buffer (bytes) |
| `GOST_WRITE_BUFFER` | `32768` | GOST per-conn write buffer (bytes) |
| `GOST_BACKLOG` | `1024` | GOST listen backlog |
| `LB_IDLE_TIMEOUT` | `120` | LB relay idle timeout (seconds) |
| `PREFER_IPV6` | `0` | `1` prefers IPv6 (AAAA) for dual-stack destinations; IPv4-only still works |

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
- ⚖️ **负载均衡** — 统一入口 `1110`，支持轮询/随机/哈希/粘性；`socks5h://{id}@host:1110` 固定后端
- 🔄 **定时滚动重启** — `INSTANCE_COUNT>=4` 时每 6 小时逐台硬重启；探针 `warp=on` 后才动下一台；叠轮直接忽略
- 🌐 **IPv6 优先** — `PREFER_IPV6=1` 时 GOST 解析双栈域名优先 AAAA；纯 IPv4 站点仍可访问

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
LB_STRATEGY=round   # round | random | hash | sticky
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

只要带了用户名/id，就会按 id 哈希固定到后端，与 `LB_STRATEGY` 无关；不带用户名时按 round/random/hash（客户端 IP）调度。

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
2. 完整 `instance-ctl restart`（netns + warp-svc + gost），**保留当前 WARP 注册**
3. 对实例直连端口探针，直到 `warp=on` / `warp=plus`（默认 90s）
4. 成功后才重启下一台
5. 失败则再试 2 次，仍失败就跳过并继续
6. 上一轮还没跑完就到点，**整轮丢弃**（不排队）

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
| `LB_STRATEGY` | `round` | `round` / `random` / `hash` / `sticky` |
| `LB_ENABLED` | `auto` | `auto` 在多实例时启用；`1`/`0` 强制 |
| `HEALTH_CHECK_INTERVAL` | `60` | 健康检测间隔（秒） |
| `HEALTH_SOFT_FAILURES` | `3` | 触发软重连的连续失败次数 |
| `HEALTH_FALLBACK_AFTER` | `600` | 回退 Free 的持续失败时间（秒） |
| `ROTATE_RESTART_ENABLED` | `auto` | `auto` 在实例数≥4 时启用；`1`/`0` 强制 |
| `ROTATE_RESTART_INTERVAL` | `6h` | 整轮间隔（`30m` / `6h` / `12h` / 纯秒） |
| `ROTATE_RESTART_PROBE_TIMEOUT` | `90` | 单台重启后等待 `warp=on` 的秒数 |
| `ROTATE_RESTART_RETRIES` | `2` | 本台失败后的额外硬重启次数 |
| `UPSTREAM_SOCKS5` | 空 | 可选，WARP 建连走的上游 SOCKS5 |
| `UPSTREAM_SOCKS5_UDP` | `udp` | `udp` / `tcp`；MASQUE 需要真 UDP |
| `UPSTREAM_MTU` | `1280` | 上游 TUN MTU |
| `GOST_IDLE_TIMEOUT` | `120s` | GOST 空闲连接超时 |
| `GOST_READ_BUFFER` | `32768` | GOST 单连接读缓冲（字节） |
| `GOST_WRITE_BUFFER` | `32768` | GOST 单连接写缓冲（字节） |
| `GOST_BACKLOG` | `1024` | GOST listen backlog |
| `LB_IDLE_TIMEOUT` | `120` | LB 转发空闲超时（秒） |
| `PREFER_IPV6` | `0` | `1` 双栈出站优先 IPv6（AAAA）；纯 IPv4 仍通，不检测不重启 |

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
