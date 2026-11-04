#!/usr/bin/env python3
"""laptop-agent client — talk to the laptop-agent daemon (code#5343).

Reaches the laptop through the VM's tailnet tunnel proxy (HTTP CONNECT,
same construction as laptop-proxy-connect.py; the proxy credential is read
from HTTPS_PROXY and sent only inside the CONNECT request). The agent
token lives in ~/tools/laptop-agent-token (mode 600) and is sent as a
header — never in argv.

Usage:
  laptop-agent.py health
  laptop-agent.py exec [--cwd DIR] [--timeout S] [--shell] -- cmd [args...]
  laptop-agent.py exec-batch FILE.json     # {"cmds":[...], "timeout_s":N}
  laptop-agent.py run  [--cwd DIR] [--shell] -- cmd [args...]
  laptop-agent.py poll JOB [--wait S]
  laptop-agent.py kill JOB
  laptop-agent.py jobs
"""
import argparse
import base64
import http.client
import json
import os
import socket
import sys
import time
import urllib.parse
from pathlib import Path

TARGET_HOST = "100.99.113.103"
TARGET_PORT = 4799
PROXY_PORT = 3130
TOKEN_FILE = Path.home() / "tools/laptop-agent-token"
OFFSET_DIR = Path.home() / ".cache/laptop-agent"


def tunnel_socket():
    raw = os.environ.get("HTTPS_PROXY")
    if not raw:
        sys.exit("laptop-agent: HTTPS_PROXY must be set")
    u = urllib.parse.urlparse(raw)
    user = urllib.parse.unquote(u.username or "")
    pw = urllib.parse.unquote(u.password or "")
    sock = socket.create_connection((u.hostname, PROXY_PORT), timeout=60)
    auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
    req = (f"CONNECT {TARGET_HOST}:{TARGET_PORT} HTTP/1.1\r\n"
           f"Host: {TARGET_HOST}:{TARGET_PORT}\r\n"
           f"Proxy-Authorization: Basic {auth}\r\n"
           f"Proxy-Connection: Keep-Alive\r\n\r\n")
    sock.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(1)
        if not chunk:
            sys.exit("laptop-agent: proxy closed during CONNECT")
        buf += chunk
    status = buf.split(b"\r\n", 1)[0].decode("latin-1")
    if " 200 " not in status and not status.endswith(" 200"):
        sys.exit(f"laptop-agent: CONNECT refused: {status}")
    sock.settimeout(None)
    return sock


class TunnelHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock = tunnel_socket()


def request(method, path, body=None):
    token = TOKEN_FILE.read_text().strip()
    conn = TunnelHTTP(TARGET_HOST, TARGET_PORT, timeout=660)
    payload = json.dumps(body) if body is not None else None
    conn.request(method, path, body=payload, headers={
        "X-Agent-Token": token,
        "Content-Type": "application/json",
    })
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    obj = json.loads(data or b"{}")
    if resp.status >= 400:
        sys.exit(f"laptop-agent: HTTP {resp.status}: {obj.get('error', obj)}")
    return obj


def split_cmd(args):
    """Everything after -- is the command."""
    if "--" in args:
        i = args.index("--")
        return args[:i], args[i + 1:]
    return args, []


def cmd_spec(opt_args, cmd_args, cwd, shell):
    if not cmd_args:
        sys.exit("laptop-agent: no command given (use -- cmd...)")
    if shell:
        return {"cwd": cwd, "shell": " ".join(cmd_args)}
    return {"cwd": cwd, "argv": cmd_args}


def main():
    argv = sys.argv[1:]
    if not argv:
        sys.exit(__doc__)
    sub = argv[0]
    rest = argv[1:]

    if sub == "health":
        print(json.dumps(request("GET", "/health")))
        return

    if sub == "jobs":
        print(json.dumps(request("GET", "/jobs"), indent=1))
        return

    if sub == "kill":
        print(json.dumps(request("POST", f"/jobs/{rest[0]}/kill", {})))
        return

    if sub == "exec-batch":
        body = json.loads(Path(rest[0]).read_text())
        print(json.dumps(request("POST", "/exec", body), indent=1))
        return

    if sub in ("exec", "run"):
        opt_args, cmd_args = split_cmd(rest)
        ap = argparse.ArgumentParser()
        ap.add_argument("--cwd", default=None)
        ap.add_argument("--timeout", type=int, default=120)
        ap.add_argument("--shell", action="store_true")
        opts = ap.parse_args(opt_args)
        spec = cmd_spec(opt_args, cmd_args, opts.cwd, opts.shell)
        if sub == "run":
            out = request("POST", "/jobs", spec)
            print(out["job_id"])
            return
        out = request("POST", "/exec",
                      {"cmds": [spec], "timeout_s": opts.timeout})
        r = out["results"][0]
        sys.stdout.write(r.get("stdout", ""))
        sys.stderr.write(r.get("stderr", ""))
        if r.get("error"):
            sys.stderr.write(f"laptop-agent: {r['error']}\n")
        if r.get("timeout"):
            sys.stderr.write("laptop-agent: command timed out\n")
        sys.exit(r["exit"] if r["exit"] is not None else 1)

    if sub == "poll":
        job_id = rest[0]
        wait = 0
        if "--wait" in rest:
            wait = int(rest[rest.index("--wait") + 1])
        OFFSET_DIR.mkdir(parents=True, exist_ok=True)
        off_file = OFFSET_DIR / f"{job_id}.json"
        offs = {"out": 0, "err": 0}
        if off_file.exists():
            offs = json.loads(off_file.read_text())
        deadline = time.time() + wait
        while True:
            out = request("GET",
                          f"/jobs/{job_id}?out_off={offs['out']}"
                          f"&err_off={offs['err']}")
            sys.stdout.write(out.get("stdout", ""))
            sys.stdout.flush()
            sys.stderr.write(out.get("stderr", ""))
            sys.stderr.flush()
            offs = {"out": out["out_next"], "err": out["err_next"]}
            off_file.write_text(json.dumps(offs))
            if out["state"] == "done":
                print(f"[laptop-agent] job {job_id} done "
                      f"exit={out['exit']} "
                      f"duration_ms={out['duration_ms']}",
                      file=sys.stderr)
                sys.exit(out["exit"] if out["exit"] is not None else 1)
            if time.time() >= deadline:
                print(f"[laptop-agent] job {job_id} still running",
                      file=sys.stderr)
                return
            time.sleep(3)

    sys.exit(f"laptop-agent: unknown subcommand {sub!r}")


if __name__ == "__main__":
    main()
