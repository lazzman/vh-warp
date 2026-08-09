#!/usr/bin/env python3
"""vh-warp mixed (SOCKS5 + HTTP) load balancer.

Strategies (LB_STRATEGY):
  round   - round-robin
  random  - random backend
  hash    - sticky by client IP
  sticky  - sticky by SOCKS5/HTTP username when present, else round-robin
            (username always wins when provided, regardless of strategy)

Sticky usage:
  socks5h://my-session-id@127.0.0.1:1110
  Same id always maps to the same backend (hash mod N).

Backends file (LB_BACKENDS_FILE): one host:port per line.
Reloaded automatically when mtime changes.
"""

from __future__ import annotations

import errno
import hashlib
import os
import random
import select
import socket
import struct
import threading
import time
from typing import List, Optional, Tuple

LB_PORT = int(os.environ.get("LB_PORT", "1110"))
LB_STRATEGY = os.environ.get("LB_STRATEGY", "round").strip().lower()
BACKENDS_FILE = os.environ.get(
    "LB_BACKENDS_FILE", "/var/lib/cloudflare-warp/.runtime/backends.txt"
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


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [lb] {msg}", flush=True)


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


def sticky_index(key: str, n: int) -> int:
    h = hashlib.sha256(key.encode("utf-8", errors="ignore")).digest()
    return int.from_bytes(h[:8], "big") % n


def pick_backend(
    client_ip: str, username: Optional[str]
) -> Optional[Tuple[str, int]]:
    backends = load_backends()
    if not backends:
        return None
    n = len(backends)

    # Username always enables sticky mapping when present
    if username:
        return backends[sticky_index(username, n)]

    strategy = LB_STRATEGY
    if strategy in ("sticky", "hash"):
        # sticky without user → fall back to client-IP hash for hash;
        # sticky strategy without user → round
        if strategy == "hash":
            return backends[sticky_index(client_ip or "0.0.0.0", n)]
        strategy = "round"

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
        if not handed_off:
            close_quiet(upstream)
            # client closed by handle_client finally


def handle_http(client: socket.socket, first: bytes, client_ip: str) -> None:
    client.settimeout(HANDSHAKE_TIMEOUT)
    upstream: Optional[socket.socket] = None
    handed_off = False
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

        try:
            upstream = connect_backend(backend)
        except OSError:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return

        # Forward original request; strip proxy-authorization (sticky id only)
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
    if not _backends:
        log(f"warning: no backends in {BACKENDS_FILE}, waiting...")

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((LISTEN_ADDR, LB_PORT))
    sock.listen(min(512, max(32, MAX_CONN)))
    sock.settimeout(1.0)
    log(
        f"listening on {LISTEN_ADDR}:{LB_PORT} strategy={LB_STRATEGY} "
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


if __name__ == "__main__":
    serve()
