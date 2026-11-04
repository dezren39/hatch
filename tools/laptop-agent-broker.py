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
  request  {"method", "path", "body"}
  response {"status", "body"}
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
POOL_SIZE = int(os.environ.get("LAPTOP_AGENT_POOL", "6"))
IDLE_EXIT_S = 3600
KEEPALIVE_S = 180

_pool = []
_pool_lock = threading.Lock()
_last_used = time.time()       # client requests only; keepalive must not
                               # reset this or the idle exit never fires


def open_conn():
    conn = http.client.HTTPConnection(la.TARGET_HOST, la.TARGET_PORT,
                                      timeout=660)
    conn.sock = la.tunnel_socket()
    return conn


def pool_put(conn):
    with _pool_lock:
        if len(_pool) < POOL_SIZE:
            _pool.append(conn)
            return
    try:
        conn.close()
    except Exception:
        pass


def pool_get():
    with _pool_lock:
        if _pool:
            return _pool.pop()
    return open_conn()


def do_request(method, path, body, client=True):
    """One request on a pooled warm connection; one retry on a fresh
    connection if the pooled one went stale."""
    global _last_used
    if client:
        _last_used = time.time()
    token = la.TOKEN_FILE.read_text().strip()
    payload = json.dumps(body) if body is not None else None
    last_err = None
    for attempt in (1, 2):
        conn = pool_get() if attempt == 1 else open_conn()
        try:
            conn.request(method, path, body=payload, headers={
                "X-Agent-Token": token,
                "Content-Type": "application/json",
            })
            resp = conn.getresponse()
            data = resp.read()
            pool_put(conn)
            return resp.status, json.loads(data or b"{}")
        except Exception as e:
            last_err = e
            try:
                conn.close()
            except Exception:
                pass
    raise last_err


def preconnect():
    for _ in range(POOL_SIZE):
        try:
            pool_put(open_conn())
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
            try:
                status, body = do_request(req["method"], req["path"],
                                          req.get("body"))
                write_msg(self.request, {"status": status, "body": body})
            except Exception as e:
                write_msg(self.request, {
                    "status": 502,
                    "body": {"error": f"broker: {type(e).__name__}: {e}"}})


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
    srv = Server(str(SOCK_PATH), Handler)
    threading.Thread(target=preconnect, daemon=True).start()
    threading.Thread(target=keepalive_loop, daemon=True).start()
    print(f"laptop-agent broker on {SOCK_PATH}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
