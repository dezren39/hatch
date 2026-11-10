#!/usr/bin/env python3
"""laptop-agent broker — keeps warm connections to the laptop-agent
daemon so single client calls skip the CONNECT handshake (code#5343).

The cold cost is the tunnel CONNECT through the DERP hairpin (measured
~1.8 s, variable); a request over an already-open tunnel is ~0.25 s.
Python client startup is ~25 ms — not the problem. So: this broker holds
a small pool of keep-alive HTTP connections (each over its own CONNECT
tunnel) and serves the CLI over a Unix socket, exactly like SSH's
ControlMaster/ControlPersist pattern. The client auto-starts it when the
socket is missing; it exits after an idle hour.

Protocol (length-prefixed JSON both ways):
  request  {"method", "path", "body", "port"?, "token_file"?}
  response {"status", "body"}

Timeout behaviour (2026-11-10): HTTP timeouts on pooled connections
are set per request from the caller's remaining deadline (header
"deadline_s"), never a flat 660 s, and a connection whose request
times out or errors is CLOSED, never returned to the pool — one
wedged tunnel cannot park or poison later callers. The broker writes
its pid to broker.pid so a client whose deadline fired while parked
on the broker socket can restart it for a clean pool.

`port` (default 4799, the laptop-agent) selects the laptop service —
the session proxy is the single entry point for all of them
(queue-broker on 4801, secrets-broker on 4800; code#5362). `token_file`
names the file whose contents are sent as X-Agent-Token for that
service (read per request, never stored); without it the laptop-agent
token is used. Pools are kept per port.
"""
import http.client
import importlib.util
import json
import os
import socket
import socketserver
import struct
import sys
import threading
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "la", str(Path.home() / "tools/laptop-agent.py"))
la = importlib.util.module_from_spec(spec)
spec.loader.exec_module(la)

SOCK_DIR = Path.home() / ".cache/laptop-agent"
SOCK_PATH = SOCK_DIR / "broker.sock"
POOL_SIZE = int(os.environ.get("LAPTOP_AGENT_POOL", "12"))
IDLE_EXIT_S = 3600
KEEPALIVE_S = 180

_pools = {}
_pool_lock = threading.Lock()
_last_used = time.time()       # client requests only; keepalive must not
                               # reset this or the idle exit never fires


_inflight = {}               # client unix-sock -> tracker dict with "tun"
_inflight_lock = threading.Lock()
_watch_started = False


def _track(client_sock, tracker):
    global _watch_started
    with _inflight_lock:
        _inflight[client_sock] = tracker
        start = not _watch_started
        _watch_started = True
    if start:
        threading.Thread(target=_inflight_watchdog, daemon=True).start()


def _untrack(client_sock):
    with _inflight_lock:
        _inflight.pop(client_sock, None)


def _inflight_watchdog():
    """Every 0.2 s: if a client whose request is in flight has hung up
    (EOF on its unix socket), hard-close the tunnel that request is
    using. The handler thread blocked in getresponse() then errors
    immediately, and closing the tunnel is also the signal the daemon
    uses to reap the remote command group. This is what makes an
    uncatchable client death (SIGKILL) bounded on the laptop side."""
    while True:
        time.sleep(0.2)
        with _inflight_lock:
            items = list(_inflight.items())
        for client_sock, tracker in items:
            tun = tracker.get("tun")
            if tun is None:
                continue
            try:
                client_sock.setblocking(False)
                try:
                    data = client_sock.recv(1, socket.MSG_PEEK)
                    gone = data == b""
                except BlockingIOError:
                    gone = False
                except OSError:
                    gone = True
                finally:
                    client_sock.setblocking(True)
            except OSError:
                gone = True
            if gone:
                try:
                    tun.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    tun.close()
                except OSError:
                    pass


def open_conn(port=4799):
    conn = http.client.HTTPConnection(la.TARGET_HOST, port, timeout=660)
    conn.sock = la.tunnel_socket(port)
    return conn


def pool_put(port, conn):
    with _pool_lock:
        pool = _pools.setdefault(port, [])
        if len(pool) < POOL_SIZE:
            pool.append(conn)
            return
    try:
        conn.close()
    except Exception:
        pass


def pool_get(port):
    with _pool_lock:
        pool = _pools.get(port) or []
        if pool:
            return pool.pop()
    return open_conn(port)


def do_request(method, path, body, port=4799, token_file=None, client=True,
               trip=None, deadline_s=None, tracker=None):
    """One request on a pooled warm connection; one retry on a fresh
    connection if the pooled one went stale. The socket timeout is
    the caller's remaining deadline (clamped), and a connection that
    fails or times out is closed — never returned to the pool."""
    global _last_used
    if client:
        _last_used = time.time()
    if token_file:
        token = Path(token_file).read_text().strip()
    else:
        token = la.TOKEN_FILE.read_text().strip()
    payload = json.dumps(body) if body is not None else None
    if deadline_s is None:
        timeout_s = 660
    else:
        timeout_s = max(1.0, min(660.0, float(deadline_s)))
    last_err = None
    for attempt in (1, 2):
        conn = pool_get(port) if attempt == 1 else open_conn(port)
        if tracker is not None:
            tracker["tun"] = conn.sock
        try:
            if conn.sock is not None:
                conn.sock.settimeout(timeout_s)
            headers = {"X-Agent-Token": token,
                       "Content-Type": "application/json"}
            if trip:
                headers["X-Trip-Id"] = trip
            conn.request(method, path, body=payload, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            pool_put(port, conn)
            return resp.status, json.loads(data or b"{}")
        except Exception as e:
            last_err = e
            if tracker is not None:
                tracker["tun"] = None
            try:
                conn.close()
            except Exception:
                pass
            if isinstance(e, (TimeoutError, socket.timeout)):
                raise  # deadline fired; conn already dropped — no retry
    raise last_err


def preconnect():
    for _ in range(POOL_SIZE):
        try:
            pool_put(4799, open_conn(4799))
        except Exception:
            pass


def keepalive_loop():
    while True:
        time.sleep(KEEPALIVE_S)
        if time.time() - _last_used > IDLE_EXIT_S:
            os._exit(0)
        try:
            do_request("GET", "/health", None, client=False)
        except Exception:
            pass


def read_msg(conn):
    hdr = b""
    while len(hdr) < 8:
        chunk = conn.recv(8 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    (n,) = struct.unpack(">Q", hdr)
    data = b""
    while len(data) < n:
        chunk = conn.recv(min(1 << 20, n - len(data)))
        if not chunk:
            return None
        data += chunk
    return json.loads(data)


def write_msg(conn, obj):
    data = json.dumps(obj).encode()
    conn.sendall(struct.pack(">Q", len(data)) + data)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            req = read_msg(self.request)
            if req is None:
                return
            tracker = {"tun": None}
            _track(self.request, tracker)
            try:
                body_in = req.get("body")
                deadline_s = req.get("deadline_s")
                if deadline_s is None and isinstance(body_in, dict):
                    ts = body_in.get("timeout_s")
                    if isinstance(ts, (int, float)):
                        deadline_s = float(ts) + 15.0
                status, body = do_request(
                    req["method"], req["path"], body_in,
                    port=int(req.get("port", 4799)),
                    token_file=req.get("token_file"),
                    trip=req.get("trip"),
                    deadline_s=deadline_s,
                    tracker=tracker)
                write_msg(self.request, {"status": status, "body": body})
            except Exception as e:
                try:
                    write_msg(self.request, {
                        "status": 502,
                        "body": {"error": f"broker: {type(e).__name__}: {e}"}})
                except OSError:
                    pass  # client already gone — nothing to answer
            finally:
                _untrack(self.request)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    SOCK_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(SOCK_DIR, 0o700)
    except OSError:
        pass
    if SOCK_PATH.exists():
        # A live broker already owns the socket; exit quietly.
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(SOCK_PATH))
            probe.close()
            return
        except OSError:
            SOCK_PATH.unlink()
    try:
        (SOCK_DIR / "broker.pid").write_text(str(os.getpid()))
    except OSError:
        pass
    srv = Server(str(SOCK_PATH), Handler)
    threading.Thread(target=preconnect, daemon=True).start()
    threading.Thread(target=keepalive_loop, daemon=True).start()
    print(f"laptop-agent broker on {SOCK_PATH}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
