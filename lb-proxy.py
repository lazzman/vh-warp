#!/usr/bin/env python3
"""vh-warp mixed (SOCKS5 + HTTP) load balancer.

Strategies (LB_STRATEGY):
  round   - round-robin
  random  - random backend
  hash    - 按客户端 IP 的 Rendezvous 哈希
  rotate  - 按固定时间窗口统一切换后端

基于 id 的路由：
  socks5h://my-session-id@127.0.0.1:1110
  同一 id 通过 Rendezvous 哈希固定映射到同一后端（rotate 策略除外）。

Backends file (LB_BACKENDS_FILE): one host:port per line.
Reloaded automatically when mtime changes.
"""

from __future__ import annotations

import errno
import hashlib
import os
import random
import re
import select
import socket
import struct
import threading
import time
from typing import Dict, List, Optional, Tuple

LB_PORT = int(os.environ.get("LB_PORT", "1110"))
LB_STRATEGY = os.environ.get("LB_STRATEGY", "round").strip().lower()
LB_ROTATE_INTERVAL = os.environ.get("LB_ROTATE_INTERVAL", "5m").strip()
BACKENDS_FILE = os.environ.get(
    "LB_BACKENDS_FILE", "/var/lib/cloudflare-warp/.runtime/backends.txt"
)
BACKEND_CONNECTION_STATE_FILE = os.environ.get(
    "LB_CONNECTION_STATE_FILE", "/var/lib/cloudflare-warp/.runtime/lb-connections.txt"
)
LISTEN_ADDR = os.environ.get("LB_LISTEN", "0.0.0.0")
BUFFER = 64 * 1024
IDLE_TIMEOUT = float(os.environ.get("LB_IDLE_TIMEOUT", "120"))
# Handshake / header read timeout (seconds). Prevents stalled clients from
# holding threads and sockets forever.
HANDSHAKE_TIMEOUT = float(os.environ.get("LB_HANDSHAKE_TIMEOUT", "30"))
# Cap concurrent connection handlers to bound thread + FD + buffer memory.
MAX_CONN = max(1, int(os.environ.get("LB_MAX_CONN", "512")))

_lock = threading.Lock()
_rr_index = 0
_backends: List[Tuple[str, int]] = []
_backends_mtime = -1.0
_conn_sem = threading.BoundedSemaphore(MAX_CONN)
_active_conn = 0
_active_lock = threading.Lock()
_backend_connections: Dict[Tuple[str, int], int] = {}
_backend_connections_lock = threading.Lock()
_rotate_started_at = time.monotonic()
_rotate_slot = 0
_rotate_target: Optional[Tuple[str, int]] = None
_rotate_backend: Optional[Tuple[str, int]] = None
_rotate_backend_order: List[Tuple[str, int]] = []


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [lb] {msg}", flush=True)


def write_backend_connection_state() -> None:
    """将各后端正在处理的连接数原子写入运行时状态文件。"""
    directory = os.path.dirname(BACKEND_CONNECTION_STATE_FILE) or "."
    temporary = (
        f"{BACKEND_CONNECTION_STATE_FILE}.{os.getpid()}.{threading.get_ident()}.tmp"
    )
    try:
        os.makedirs(directory, exist_ok=True)
        with open(temporary, "w", encoding="utf-8") as f:
            for (host, port), count in sorted(_backend_connections.items()):
                if count > 0:
                    f.write(f"{host}:{port}\t{count}\n")
        os.replace(temporary, BACKEND_CONNECTION_STATE_FILE)
    except OSError as e:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        log(f"写入后端连接状态失败: {e}")


def track_backend_connection(backend: Tuple[str, int], delta: int) -> None:
    """更新后端连接计数；摘流重启据此等待现有连接自然结束。"""
    with _backend_connections_lock:
        count = _backend_connections.get(backend, 0) + delta
        if count > 0:
            _backend_connections[backend] = count
        else:
            _backend_connections.pop(backend, None)
        write_backend_connection_state()


def parse_rotate_interval_seconds(raw: str) -> int:
    """解析定时轮换间隔；不带单位的数字按分钟处理。"""
    value = raw.strip().lower()
    if not value:
        raise ValueError("empty interval")

    match = re.fullmatch(r"(\d+)([smhd]?)", value)
    if not match:
        raise ValueError(f"invalid interval: {raw}")

    amount = int(match.group(1))
    unit = match.group(2)
    if amount <= 0:
        raise ValueError(f"interval must be positive: {raw}")

    # 此策略面向“每 N 分钟”的配置；裸数字保持该直觉，显式单位可精确到秒。
    multiplier = {"": 60, "s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
    return amount * multiplier


try:
    LB_ROTATE_INTERVAL_SECONDS = parse_rotate_interval_seconds(LB_ROTATE_INTERVAL)
except ValueError as e:
    LB_ROTATE_INTERVAL_SECONDS = 5 * 60
    log(f"无效 LB_ROTATE_INTERVAL={LB_ROTATE_INTERVAL!r} ({e})，回退为 5m")


def rotate_window_slot(elapsed_seconds: float) -> int:
    """返回从 LB 启动开始经过的时间窗口编号。"""
    return int(max(0.0, elapsed_seconds) // LB_ROTATE_INTERVAL_SECONDS)


def next_healthy_rotate_backend(
    backends: List[Tuple[str, int]], current: Optional[Tuple[str, int]]
) -> Tuple[str, int]:
    """从固定实例顺序中选择 current 的下一个健康后端。"""
    if current not in _rotate_backend_order:
        return backends[0]

    start = _rotate_backend_order.index(current)
    for offset in range(1, len(_rotate_backend_order) + 1):
        candidate = _rotate_backend_order[
            (start + offset) % len(_rotate_backend_order)
        ]
        if candidate in backends:
            return candidate
    return backends[0]


def next_rotate_target(current: Optional[Tuple[str, int]]) -> Tuple[str, int]:
    """按固定实例顺序推进轮换目标，不受当前健康状态影响。"""
    if current not in _rotate_backend_order:
        return _rotate_backend_order[0]
    current_index = _rotate_backend_order.index(current)
    return _rotate_backend_order[
        (current_index + 1) % len(_rotate_backend_order)
    ]


def healthy_backend_for_rotate_target(
    backends: List[Tuple[str, int]], target: Tuple[str, int]
) -> Tuple[str, int]:
    """优先使用轮换目标；目标摘流时才选择下一个健康实例。"""
    if target in backends:
        return target
    return next_healthy_rotate_backend(backends, target)


def pick_rotate_backend(backends: List[Tuple[str, int]]) -> Tuple[str, int]:
    """选择定时轮换后端，并在摘流时平滑故障转移。"""
    global _rotate_backend, _rotate_slot, _rotate_target

    target_slot = rotate_window_slot(time.monotonic() - _rotate_started_at)
    with _lock:
        # 保留实例首次出现的顺序。健康列表在滚动重启时临时移除实例，
        # 不能因此改变本轮目标或打乱“下一个实例”的顺序。
        for backend in backends:
            if backend not in _rotate_backend_order:
                _rotate_backend_order.append(backend)

        if _rotate_target is None:
            _rotate_target = backends[0]
            _rotate_backend = _rotate_target

        # 轮换进度仅由单调时钟推进，不受实例重启或后端文件热更新影响。
        while _rotate_slot < target_slot:
            _rotate_target = next_rotate_target(_rotate_target)
            _rotate_backend = healthy_backend_for_rotate_target(
                backends, _rotate_target
            )
            _rotate_slot += 1

        # 定时滚动重启会先将目标实例从健康列表摘除。此时仅故障转移到
        # 下一个健康实例；待原实例恢复后，本时间窗口仍保持当前故障转移目标。
        if _rotate_backend not in backends:
            _rotate_backend = healthy_backend_for_rotate_target(
                backends, _rotate_target
            )

        return _rotate_backend


def close_quiet(sock: Optional[socket.socket]) -> None:
    if sock is None:
        return
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


def load_backends(force: bool = False) -> List[Tuple[str, int]]:
    global _backends, _backends_mtime
    try:
        st = os.stat(BACKENDS_FILE)
        mtime = st.st_mtime
    except OSError:
        return list(_backends)

    with _lock:
        if not force and mtime == _backends_mtime and _backends:
            return list(_backends)
        result: List[Tuple[str, int]] = []
        try:
            with open(BACKENDS_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if ":" not in line:
                        continue
                    host, _, port_s = line.rpartition(":")
                    try:
                        result.append((host.strip(), int(port_s.strip())))
                    except ValueError:
                        continue
        except OSError as e:
            log(f"read backends failed: {e}")
            return list(_backends)
        if result:
            _backends = result
            _backends_mtime = mtime
        return list(_backends)


def rendezvous_score(key: str, backend: Tuple[str, int]) -> bytes:
    """计算 key 与后端组合的稳定权重。"""
    key_bytes = key.encode("utf-8", errors="ignore")
    backend_bytes = f"{backend[0]}:{backend[1]}".encode("utf-8")
    h = hashlib.sha256()
    h.update(len(key_bytes).to_bytes(4, "big"))
    h.update(key_bytes)
    h.update(backend_bytes)
    return h.digest()


def rendezvous_backend(
    key: str, backends: List[Tuple[str, int]]
) -> Tuple[str, int]:
    """使用最高随机权重哈希选择后端。

    相比哈希取模，实例新增时只有权重高于原后端的 key 会迁移到新实例；
    实例移除时也只迁移原本落在该实例上的 key。等权后端和大量离散 key
    的分布会趋于均匀。
    """
    return max(backends, key=lambda backend: rendezvous_score(key, backend))


def pick_backend(
    client_ip: str, username: Optional[str]
) -> Optional[Tuple[str, int]]:
    backends = load_backends()
    if not backends:
        return None
    n = len(backends)

    strategy = LB_STRATEGY
    if strategy in ("rotate", "timed", "interval"):
        # 定时轮换必须先于用户名粘性处理，才能保证同一时间窗口内的
        # 所有新连接都使用同一个后端。
        return pick_rotate_backend(backends)

    # 除定时轮换外，用户名始终启用粘性映射。
    if username:
        return rendezvous_backend(username, backends)

    if strategy == "hash":
        return rendezvous_backend(client_ip or "0.0.0.0", backends)

    if strategy == "random":
        return random.choice(backends)

    # round (default)
    global _rr_index
    with _lock:
        idx = _rr_index % n
        _rr_index += 1
    return backends[idx]


def relay(a: socket.socket, b: socket.socket) -> None:
    """Bidirectional pipe. Always closes both sockets on exit."""
    # Relay is driven by select idle timeout; clear per-socket timeouts.
    for s in (a, b):
        try:
            s.settimeout(None)
        except OSError:
            pass
    sockets = [a, b]
    try:
        while True:
            r, _, x = select.select(sockets, [], sockets, IDLE_TIMEOUT)
            if x or not r:
                break
            for s in r:
                other = b if s is a else a
                try:
                    data = s.recv(BUFFER)
                except OSError:
                    return
                if not data:
                    return
                try:
                    other.sendall(data)
                except OSError:
                    return
    except Exception:
        return
    finally:
        close_quiet(a)
        close_quiet(b)


def connect_backend(backend: Tuple[str, int]) -> socket.socket:
    s = socket.create_connection(backend, timeout=10)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("eof")
        buf += chunk
    return buf


def handle_socks5(client: socket.socket, first: bytes, client_ip: str) -> None:
    # Keep handshake timeout so slow/stalled clients cannot pin a thread forever.
    client.settimeout(HANDSHAKE_TIMEOUT)
    upstream: Optional[socket.socket] = None
    handed_off = False
    backend: Optional[Tuple[str, int]] = None
    backend_tracked = False
    try:
        # first already has at least 1 byte (0x05); read rest of greeting
        data = first
        while len(data) < 2:
            data += recv_exact(client, 2 - len(data))
        nmethods = data[1]
        while len(data) < 2 + nmethods:
            data += recv_exact(client, 2 + nmethods - len(data))

        methods = set(data[2 : 2 + nmethods])
        username: Optional[str] = None

        if 0x02 in methods:
            # username/password auth
            client.sendall(b"\x05\x02")
            auth = recv_exact(client, 2)
            if auth[0] != 0x01:
                client.sendall(b"\x01\x01")
                return
            ulen = auth[1]
            user = (
                recv_exact(client, ulen).decode("utf-8", errors="ignore") if ulen else ""
            )
            plen_b = recv_exact(client, 1)
            plen = plen_b[0]
            _password = recv_exact(client, plen) if plen else b""
            username = user
            client.sendall(b"\x01\x00")  # success, accept any password
        elif 0x00 in methods:
            client.sendall(b"\x05\x00")
        else:
            client.sendall(b"\x05\xFF")
            return

        # request
        req = recv_exact(client, 4)
        ver, cmd, _, atyp = req
        if ver != 0x05:
            return
        if cmd != 0x01:  # only CONNECT
            # rep=7 command not supported
            client.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
            return

        raw = b""
        ln = 0
        if atyp == 0x01:
            raw = recv_exact(client, 4)
            _host = socket.inet_ntoa(raw)
        elif atyp == 0x03:
            ln = recv_exact(client, 1)[0]
            _host = recv_exact(client, ln).decode("utf-8", errors="ignore")
        elif atyp == 0x04:
            raw = recv_exact(client, 16)
            _host = socket.inet_ntop(socket.AF_INET6, raw)
        else:
            client.sendall(b"\x05\x08\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        _port = struct.unpack("!H", recv_exact(client, 2))[0]

        backend = pick_backend(client_ip, username)
        if not backend:
            client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        # 从选中后端起即开始计数，覆盖与后端握手中的连接，避免摘流后
        # 仍有刚完成选择的连接穿透排空窗口。
        track_backend_connection(backend, 1)
        backend_tracked = True

        try:
            upstream = connect_backend(backend)
        except OSError:
            client.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            return

        # Replay SOCKS5 handshake to upstream (no auth to backends)
        try:
            upstream.settimeout(HANDSHAKE_TIMEOUT)
            upstream.sendall(b"\x05\x01\x00")
            greet = recv_exact(upstream, 2)
            if greet[0] != 0x05 or greet[1] != 0x00:
                client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
                return
            # forward original request bytes
            upstream.sendall(req)
            if atyp == 0x01:
                upstream.sendall(raw + struct.pack("!H", _port))
            elif atyp == 0x03:
                upstream.sendall(
                    bytes([ln]) + _host.encode("utf-8") + struct.pack("!H", _port)
                )
            else:
                upstream.sendall(raw + struct.pack("!H", _port))
            # read reply and pass to client
            reply = recv_exact(upstream, 4)
            atyp_r = reply[3]
            if atyp_r == 0x01:
                reply += recv_exact(upstream, 6)
            elif atyp_r == 0x03:
                ln_r = recv_exact(upstream, 1)
                reply += ln_r + recv_exact(upstream, ln_r[0] + 2)
            elif atyp_r == 0x04:
                reply += recv_exact(upstream, 18)
            client.sendall(reply)
            if reply[1] != 0x00:
                return
        except Exception:
            try:
                client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
            except OSError:
                pass
            return

        tag = username or "-"
        log(
            f"SOCKS5 {client_ip} user={tag} → {backend[0]}:{backend[1]} dest={_host}:{_port}"
        )
        handed_off = True
        relay(client, upstream)
    finally:
        if backend_tracked and backend:
            track_backend_connection(backend, -1)
        if not handed_off:
            close_quiet(upstream)
            # client closed by handle_client finally


def handle_http(client: socket.socket, first: bytes, client_ip: str) -> None:
    client.settimeout(HANDSHAKE_TIMEOUT)
    upstream: Optional[socket.socket] = None
    handed_off = False
    backend: Optional[Tuple[str, int]] = None
    backend_tracked = False
    try:
        # Read full headers
        data = first
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = client.recv(4096)
            if not chunk:
                return
            data += chunk
        try:
            header_blob, _, body = data.partition(b"\r\n\r\n")
            lines = header_blob.decode("iso-8859-1", errors="ignore").split("\r\n")
            request_line = lines[0]
            parts = request_line.split()
            if len(parts) < 2:
                return
            method, target = parts[0].upper(), parts[1]
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, _, v = line.partition(":")
                    headers[k.strip().lower()] = v.strip()
        except Exception:
            return

        username: Optional[str] = None
        auth = headers.get("proxy-authorization", "")
        if auth.lower().startswith("basic "):
            import base64

            try:
                decoded = base64.b64decode(auth.split(None, 1)[1]).decode(
                    "utf-8", errors="ignore"
                )
                username = decoded.split(":", 1)[0]
            except Exception:
                username = None

        backend = pick_backend(client_ip, username)
        if not backend:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return
        track_backend_connection(backend, 1)
        backend_tracked = True

        try:
            upstream = connect_backend(backend)
        except OSError:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return

        # 转发原请求；移除仅用于路由的 Proxy-Authorization。
        out_lines = [request_line]
        for line in lines[1:]:
            if line.lower().startswith("proxy-authorization:"):
                continue
            out_lines.append(line)
        forward = (
            "\r\n".join(out_lines) + "\r\n\r\n"
        ).encode("iso-8859-1", errors="ignore") + body

        try:
            upstream.settimeout(HANDSHAKE_TIMEOUT)
            upstream.sendall(forward)
        except OSError:
            return

        tag = username or "-"
        log(
            f"HTTP {client_ip} user={tag} → {backend[0]}:{backend[1]} {method} {target}"
        )
        handed_off = True
        relay(client, upstream)
    finally:
        if backend_tracked and backend:
            track_backend_connection(backend, -1)
        if not handed_off:
            close_quiet(upstream)


def _track_conn(delta: int) -> int:
    global _active_conn
    with _active_lock:
        _active_conn += delta
        return _active_conn


def handle_client(client: socket.socket, addr) -> None:
    client_ip = addr[0] if addr else "0.0.0.0"
    _track_conn(1)
    try:
        client.settimeout(HANDSHAKE_TIMEOUT)
        try:
            first = client.recv(1)
            if not first:
                return
            if first[0] == 0x05:
                handle_socks5(client, first, client_ip)
            else:
                # HTTP — already consumed 1 byte; read more under handshake timeout
                more = client.recv(4095)
                handle_http(client, first + more, client_ip)
        except Exception as e:
            log(f"client error {client_ip}: {e}")
    finally:
        # Safe even if relay() already closed the socket.
        close_quiet(client)
        active = _track_conn(-1)
        # Periodic visibility under load (every 64 releases, rough)
        if active >= MAX_CONN - 1 or (active > 0 and active % 64 == 0):
            log(f"active_conn={active}/{MAX_CONN}")


def serve() -> None:
    load_backends(force=True)
    with _backend_connections_lock:
        write_backend_connection_state()
    if not _backends:
        log(f"warning: no backends in {BACKENDS_FILE}, waiting...")

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((LISTEN_ADDR, LB_PORT))
    sock.listen(min(512, max(32, MAX_CONN)))
    sock.settimeout(1.0)
    log(
        f"listening on {LISTEN_ADDR}:{LB_PORT} strategy={LB_STRATEGY} "
        f"rotate_interval={LB_ROTATE_INTERVAL}({LB_ROTATE_INTERVAL_SECONDS}s) "
        f"max_conn={MAX_CONN} idle={IDLE_TIMEOUT}s hs={HANDSHAKE_TIMEOUT}s "
        f"backends_file={BACKENDS_FILE}"
    )
    log(f"backends: {load_backends()}")

    try:
        while True:
            try:
                load_backends()  # hot reload
                # Bound concurrent handlers: wait briefly for a free slot so we
                # do not spawn unbounded threads (each holds stack + 2 sockets).
                acquired = _conn_sem.acquire(timeout=0.5)
                if not acquired:
                    # Still accept? No — backpressure by not accepting keeps
                    # kernel backlog full and clients retry / fail fast.
                    # Drain accept only when we have capacity.
                    continue
                try:
                    client, addr = sock.accept()
                except socket.timeout:
                    _conn_sem.release()
                    continue
                except Exception:
                    _conn_sem.release()
                    raise
                try:
                    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                except OSError:
                    close_quiet(client)
                    _conn_sem.release()
                    continue

                def _run(c=client, a=addr) -> None:
                    try:
                        handle_client(c, a)
                    finally:
                        _conn_sem.release()

                try:
                    t = threading.Thread(target=_run, daemon=True)
                    t.start()
                except Exception as e:
                    log(f"thread start failed: {e}")
                    close_quiet(client)
                    _conn_sem.release()
            except KeyboardInterrupt:
                break
            except Exception as e:
                if getattr(e, "errno", None) == errno.EINTR:
                    continue
                log(f"accept loop: {e}")
                time.sleep(0.2)
    finally:
        close_quiet(sock)
        with _backend_connections_lock:
            _backend_connections.clear()
            write_backend_connection_state()


if __name__ == "__main__":
    serve()
