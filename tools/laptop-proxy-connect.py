#!/usr/bin/env python3
"""HTTP CONNECT relay for laptop SSH (ProxyCommand helper).

Speaks the proxy handshake to the tailnet tunnel proxy and then relays
bytes between stdio and the tunnel socket. The proxy credential is read
from the HTTPS_PROXY environment variable at runtime and is only ever
sent inside the CONNECT request itself — it never appears in any
process's argument list (the flaw in the old socat-based ProxyCommand,
where proxyauth= sat in the argv of both ssh and socat).

Target and proxy port match the historical setup: the laptop
(100.99.113.103:22) via the tunnel proxy on port 3130 of the host named
in HTTPS_PROXY.
"""
import base64
import os
import signal
import socket
import sys
import threading
import urllib.parse

TARGET_HOST = "100.99.113.103"
TARGET_PORT = 22
PROXY_PORT = 3130


def fail(msg: str) -> "SystemExit":
    print(f"laptop-proxy-connect: {msg}", file=sys.stderr)
    return SystemExit(1)


def main() -> None:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    raw = os.environ.get("HTTPS_PROXY")
    if not raw:
        raise fail("HTTPS_PROXY must be set (runtime proxy env)")
    u = urllib.parse.urlparse(raw)
    user = urllib.parse.unquote(u.username or "")
    pw = urllib.parse.unquote(u.password or "")
    if not u.hostname:
        raise fail("HTTPS_PROXY has no host")

    sock = socket.create_connection((u.hostname, PROXY_PORT), timeout=60)
    auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
    req = (
        f"CONNECT {TARGET_HOST}:{TARGET_PORT} HTTP/1.1\r\n"
        f"Host: {TARGET_HOST}:{TARGET_PORT}\r\n"
        f"Proxy-Authorization: Basic {auth}\r\n"
        f"Proxy-Connection: Keep-Alive\r\n\r\n"
    )
    sock.sendall(req.encode())

    # Read the response headers (byte-wise until the blank line; the
    # tunnel may already have SSH banner bytes queued behind them, so do
    # not over-read into a buffered reader).
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(1)
        if not chunk:
            raise fail("proxy closed during CONNECT")
        buf += chunk
        if len(buf) > 65536:
            raise fail("proxy response too large")
    status = buf.split(b"\r\n", 1)[0].decode("latin-1")
    if " 200 " not in status and not status.endswith(" 200"):
        raise fail(f"CONNECT refused: {status}")
    sock.settimeout(None)

    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    def pump_in() -> None:
        try:
            while True:
                data = stdin.read1(65536) if hasattr(stdin, "read1") else stdin.read(65536)
                if not data:
                    break
                sock.sendall(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            try:
                sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    t = threading.Thread(target=pump_in, daemon=True)
    t.start()
    try:
        while True:
            data = sock.recv(65536)
            if not data:
                break
            stdout.write(data)
            stdout.flush()
    except (ConnectionResetError, OSError):
        pass


if __name__ == "__main__":
    main()
