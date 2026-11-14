#!/usr/bin/env python3
"""laptop-agent daemon — resident execution agent on Drew's laptop.

Design: developing-today/code#5343. Single file, Python stdlib only.
Binds the tailnet interface only; every request needs the X-Agent-Token
header (token in ~/.config/laptop-agent/token, mode 600).

API (JSON):
  GET  /health                    -> {ok, uptime_s, jobs, load1}
  POST /exec   {cmds:[{cwd, argv|shell}], timeout_s?}
                                  -> {results:[{exit, stdout, stderr,
                                      duration_ms, truncated}]}
  POST /jobs   {cwd, argv|shell, env?} -> {job_id}
  GET  /jobs                      -> {jobs:[{job_id, state, exit, ...}]}
  GET  /jobs/<id>?out_off&err_off -> {state, exit, stdout, stderr,
                                      out_next, err_next, duration_ms}
  POST /jobs/<id>/kill            -> {ok, state}
  POST /exec/<trip>/cancel        -> {ok, cancelled} (POST /cancel
                                      {trip} is the legacy spelling)

Job stdout/stderr spool to ~/.local/state/laptop-agent/jobs/<id>/ so a
daemon restart does not lose results. Finished jobs reaped after 24h.

Timeout semantics (2026-11-10): every /exec command runs in its OWN
process group (start_new_session) and the whole group is killed on
timeout, on an explicit /cancel for its trip, or when the client
connection dies mid-exec — a caller-side timeout therefore never
leaves orphan processes behind on the laptop, grandchildren included.
"""
import hashlib
import hmac
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

BIND_HOST = os.environ.get("LAPTOP_AGENT_HOST", "100.99.113.103")
BIND_PORT = int(os.environ.get("LAPTOP_AGENT_PORT", "4799"))
TOKEN_FILE = Path(os.environ.get(
    "LAPTOP_AGENT_TOKEN_FILE", Path.home() / ".config/laptop-agent/token"))
STATE_DIR = Path(os.environ.get(
    "LAPTOP_AGENT_STATE", Path.home() / ".local/state/laptop-agent"))
MAX_OUT = 1 << 20            # per-stream capture cap for /exec (tail kept)
EXEC_TIMEOUT_DEFAULT = 120
EXEC_TIMEOUT_MAX = 600
JOB_TTL_S = 24 * 3600
SEMA = threading.Semaphore(int(os.environ.get("LAPTOP_AGENT_SLOTS", "32")))
STARTED = time.time()

# Shell for `shell` specs. Never hardcode /bin/bash: on NixOS it does not
# exist (the 2026-11-04 laptop-ssh retirement verification caught shell
# mode failing with ENOENT for exactly this reason). Resolve once from
# the daemon's own PATH, then the standard NixOS locations.
BASH = next((p for p in (shutil.which("bash"),
                         "/etc/profiles/per-user/user/bin/bash",
                         "/run/current-system/sw/bin/bash",
                         "/bin/bash")
             if p and os.path.exists(p)), "/bin/bash")

TOKEN = TOKEN_FILE.read_text().strip()
JOBS = {}                    # job_id -> dict
JOBS_LOCK = threading.Lock()
TRIPS_FILE = STATE_DIR / "trips.jsonl"
EXEC_PROCS = {}              # trip -> set[Popen] currently running for /exec
EXEC_PROCS_LOCK = threading.Lock()


def log_trip(trip, kind, cmd_str, duration_ms, exit_code, out_bytes,
             err_bytes, t_received=None):
    """Append one trip record (single O_APPEND write) to trips.jsonl.

    Safety: only the command's first token and the sha256 of the full
    command string are recorded — never raw command text, environment,
    headers, or token values. Perf/safety: logging must never fail or
    visibly delay the request, so every error is swallowed.

    Trip logging v2 (code#5702): t_received is the millisecond epoch
    stamped at request entry in do_POST; with the client's t_sent /
    t_returned it splits the trip into outbound / daemon / return
    legs. v1 fields are kept verbatim for v1 readers."""
    try:
        parts = (cmd_str or "").split()
        rec = {"v": 2,
               "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "trip": trip, "kind": kind,
               "cmd0": parts[0] if parts else "",
               "cmd_sha256": hashlib.sha256(
                   (cmd_str or "").encode("utf-8", "replace")).hexdigest(),
               "duration_ms": duration_ms, "exit": exit_code,
               "out_bytes": out_bytes, "err_bytes": err_bytes}
        if t_received is not None:
            rec["t_received"] = t_received
        fd = os.open(TRIPS_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND,
                     0o644)
        try:
            os.write(fd, (json.dumps(rec) + "\n").encode())
        finally:
            os.close(fd)
    except Exception:
        pass


def tail_bytes(data: bytes, cap: int):
    if len(data) <= cap:
        return data, False
    return data[-cap:], True


def kill_group(proc, grace_s=2.0):
    """TERM a process group, escalate to KILL after grace_s. The exec
    children run with start_new_session=True, so proc.pid is the pgid
    and this reaches grandchildren that a plain proc.kill() misses."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except OSError:
        pass
    deadline = time.time() + grace_s
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            try:
                proc.kill()
            except OSError:
                pass
    try:
        proc.wait(timeout=5)
    except Exception:
        pass


def _drain(stream, buf):
    try:
        while True:
            chunk = stream.read(65536)
            if not chunk:
                break
            buf.append(chunk)
    except (OSError, ValueError):
        pass


def run_one(spec, timeout_s, trip=None, cancel_event=None):
    """Run one command in its own process group, capturing output.

    The group dies when ANY of these fires: timeout_s expires, the
    cancel_event is set (explicit /cancel or the client connection
    died — see Handler._client_gone), or the watchdog notices.
    Bytes are drained incrementally so a killed grandchild holding
    the pipes open can never wedge the reader (the classic
    subprocess.run+timeout hang)."""
    cwd = spec.get("cwd") or str(Path.home())
    env = dict(os.environ)
    env.update(spec.get("env") or {})
    if spec.get("shell") is not None:
        argv = [BASH, "-lc", spec["shell"]]
        cmd_str = spec["shell"]
    else:
        argv = list(spec["argv"])
        cmd_str = " ".join(argv)
    t0 = time.time()
    try:
        proc = subprocess.Popen(argv, cwd=cwd, env=env,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                start_new_session=True)
    except Exception as e:  # cwd missing, argv[0] missing, ...
        return {"exit": None, "error": f"{type(e).__name__}: {e}",
                "stdout": "", "stderr": "",
                "duration_ms": int((time.time() - t0) * 1000),
                "truncated": False,
                "_cmd": cmd_str, "_out_bytes": 0, "_err_bytes": 0}
    if trip:
        with EXEC_PROCS_LOCK:
            EXEC_PROCS.setdefault(trip, set()).add(proc)
    out_parts, err_parts = [], []
    t_out = threading.Thread(target=_drain,
                             args=(proc.stdout, out_parts), daemon=True)
    t_err = threading.Thread(target=_drain,
                             args=(proc.stderr, err_parts), daemon=True)
    t_out.start()
    t_err.start()
    timed_out = False
    cancelled = False
    deadline = time.time() + timeout_s
    try:
        while True:
            if proc.poll() is not None:
                break
            if cancel_event is not None and cancel_event.is_set():
                cancelled = True
                kill_group(proc)
                break
            if time.time() >= deadline:
                timed_out = True
                kill_group(proc)
                break
            time.sleep(0.05)
    finally:
        if trip:
            with EXEC_PROCS_LOCK:
                s = EXEC_PROCS.get(trip)
                if s is not None:
                    s.discard(proc)
                    if not s:
                        EXEC_PROCS.pop(trip, None)
    # Collect whatever the pipes still hold, but never wait forever:
    # a detached grandchild can keep a pipe fd open after the group
    # leader dies; the capture cap makes a short grace sufficient.
    t_out.join(timeout=2)
    t_err.join(timeout=2)
    out = b"".join(out_parts)
    err = b"".join(err_parts)
    out_t, out_tr = tail_bytes(out, MAX_OUT)
    err_t, err_tr = tail_bytes(err, MAX_OUT)
    result = {"exit": proc.returncode,
              "stdout": out_t.decode("utf-8", "replace"),
              "stderr": err_t.decode("utf-8", "replace"),
              "duration_ms": int((time.time() - t0) * 1000),
              "truncated": out_tr or err_tr,
              "_cmd": cmd_str, "_out_bytes": len(out),
              "_err_bytes": len(err)}
    if timed_out:
        result["exit"] = None
        result["timeout"] = True
    if cancelled:
        result["exit"] = None
        result["timeout"] = True
        result["cancelled"] = True
    return result


def job_dir(job_id):
    return STATE_DIR / "jobs" / job_id


def job_state(job):
    if job["proc"] is not None and job["proc"].poll() is None:
        return "running"
    return "done"


def job_public(job, out_off=0, err_off=0):
    d = job_dir(job["id"])
    out = b""
    err = b""
    try:
        with open(d / "stdout", "rb") as f:
            f.seek(out_off)
            out = f.read(MAX_OUT)
    except OSError:
        pass
    try:
        with open(d / "stderr", "rb") as f:
            f.seek(err_off)
            err = f.read(MAX_OUT)
    except OSError:
        pass
    state = job_state(job)
    return {"job_id": job["id"], "state": state,
            "exit": (job["proc"].returncode if state == "done"
                     and job["proc"] is not None else None),
            "cwd": job["cwd"], "cmd": job["cmd_repr"],
            "started_at": job["started_at"],
            "duration_ms": int(((job["ended_at"] or time.time())
                                - job["started_at"]) * 1000),
            "stdout": out.decode("utf-8", "replace"),
            "stderr": err.decode("utf-8", "replace"),
            "out_next": out_off + len(out), "err_next": err_off + len(err)}


def reap_old_jobs():
    now = time.time()
    with JOBS_LOCK:
        dead = [j for j in JOBS.values()
                if job_state(j) == "done"
                and (j["ended_at"] or now) < now - JOB_TTL_S]
        for j in dead:
            JOBS.pop(j["id"], None)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet; journal gets tracebacks only
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        given = self.headers.get("X-Agent-Token", "")
        return hmac.compare_digest(given, TOKEN)

    def _client_gone(self):
        """True once the client connection has died (EOF/error).

        ThreadingHTTPServer handlers never poll the socket while a
        /exec runs, so a client killed by an outer `timeout` used to
        leave its command running to the daemon-side cap — or longer,
        for grandchildren. Closing the write side makes the peer see
        FIN at once; the handler thread then re-checks between drain
        slices. Used as run_one's disconnect watchdog trigger."""
        try:
            self.connection.setblocking(False)
            try:
                data = self.connection.recv(1, socket.MSG_PEEK)
                return data == b""
            except BlockingIOError:
                return False
            except OSError:
                return True
            finally:
                self.connection.setblocking(True)
        except OSError:
            return True

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        return json.loads(raw or b"{}")

    def do_GET(self):
        if not self._authed():
            return self._send(401, {"error": "bad token"})
        path = urlparse(self.path)
        if path.path == "/health":
            with JOBS_LOCK:
                n = len(JOBS)
            return self._send(200, {"ok": True,
                                    "uptime_s": int(time.time() - STARTED),
                                    "jobs": n, "load1": os.getloadavg()[0]})
        if path.path == "/jobs":
            with JOBS_LOCK:
                items = [job_public(j) for j in JOBS.values()]
            return self._send(200, {"jobs": items})
        if path.path.startswith("/jobs/"):
            job_id = path.path.split("/")[2]
            q = parse_qs(path.query)
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if job is None:
                return self._send(404, {"error": "no such job"})
            return self._send(200, job_public(
                job, int(q.get("out_off", [0])[0]),
                int(q.get("err_off", [0])[0])))
        return self._send(404, {"error": "no such route"})

    def do_POST(self):
        # Trip v2 (code#5702): stamp reception at request entry; the
        # value is echoed to the client as the internal _t_received
        # response field (stripped client-side) and logged daemon-side.
        t_received_ms = int(time.time() * 1000)
        if not self._authed():
            return self._send(401, {"error": "bad token"})
        path = urlparse(self.path).path
        if path == "/exec":
            body = self._body()
            trip = self.headers.get("X-Trip-Id") or body.get("trip")
            if not isinstance(trip, str) or not trip:
                trip = secrets.token_hex(6)
            timeout = min(int(body.get("timeout_s", EXEC_TIMEOUT_DEFAULT)),
                          EXEC_TIMEOUT_MAX)
            cmds = body.get("cmds") or []
            if not isinstance(cmds, list) or not cmds:
                return self._send(400, {"error": "cmds required"})
            if not SEMA.acquire(timeout=5):
                return self._send(503, {"error": "busy"})
            cancel_event = threading.Event()

            def watch_disconnect(ev=cancel_event):
                # Poll the socket at 4 Hz while the exec runs; check
                # for cancellation events too (cheap flag).
                while not ev.is_set():
                    if self._client_gone():
                        ev.set()
                        with EXEC_PROCS_LOCK:
                            procs = list(EXEC_PROCS.get(trip, ()))
                        for p in procs:
                            if p.poll() is None:
                                kill_group(p)
                        return
                    ev.wait(0.25)

            watcher = threading.Thread(target=watch_disconnect,
                                       daemon=True)
            watcher.start()
            try:
                results = [run_one(c, timeout, trip=trip,
                                   cancel_event=cancel_event)
                           for c in cmds]
            finally:
                cancel_event.set()
                watcher.join(timeout=1)
                SEMA.release()
            for r in results:
                cmd_str = r.pop("_cmd", "")
                out_b = r.pop("_out_bytes", 0)
                err_b = r.pop("_err_bytes", 0)
                log_trip(trip, "exec", cmd_str, r.get("duration_ms"),
                         r.get("exit"), out_b, err_b,
                         t_received=t_received_ms)
            try:
                return self._send(200, {"results": results,
                                        "_t_received": t_received_ms})
            except (BrokenPipeError, ConnectionResetError):
                pass  # client already gone; the work is done/killed
            return
        if path == "/cancel" or (path.startswith("/exec/")
                                  and path.endswith("/cancel")):
            body = self._body()
            trip = (body.get("trip") or self.headers.get("X-Trip-Id")
                    or (path.split("/")[2]
                        if path.startswith("/exec/") else None))
            if not isinstance(trip, str) or not trip:
                return self._send(400, {"error": "trip required"})
            with EXEC_PROCS_LOCK:
                procs = list(EXEC_PROCS.get(trip, ()))
            killed = 0
            for p in procs:
                if p.poll() is None:
                    kill_group(p)
                    killed += 1
            return self._send(200, {"ok": True, "cancelled": killed})
        if path == "/jobs":
            body = self._body()
            trip = self.headers.get("X-Trip-Id") or body.get("trip")
            if not isinstance(trip, str) or not trip:
                trip = secrets.token_hex(6)
            cwd = body.get("cwd") or str(Path.home())
            if body.get("shell") is not None:
                argv = [BASH, "-lc", body["shell"]]
                cmd_repr = body["shell"]
            else:
                argv = list(body["argv"])
                cmd_repr = " ".join(argv)
            job_id = secrets.token_hex(6)
            d = job_dir(job_id)
            d.mkdir(parents=True, exist_ok=True)
            env = dict(os.environ)
            env.update(body.get("env") or {})
            out_f = open(d / "stdout", "wb")
            err_f = open(d / "stderr", "wb")
            try:
                proc = subprocess.Popen(argv, cwd=cwd, env=env,
                                        stdout=out_f, stderr=err_f,
                                        start_new_session=True)
            except Exception as e:
                return self._send(400, {"error": f"{type(e).__name__}: {e}"})
            job = {"id": job_id, "proc": proc, "cwd": cwd,
                   "cmd_repr": cmd_repr, "started_at": time.time(),
                   "ended_at": None, "_files": (out_f, err_f),
                   "trip": trip, "t_received": t_received_ms}
            with JOBS_LOCK:
                JOBS[job_id] = job

            def watch(j=job):
                j["proc"].wait()
                j["ended_at"] = time.time()
                for f in j["_files"]:
                    try:
                        f.close()
                    except OSError:
                        pass
                try:
                    d = job_dir(j["id"])
                    out_b = (d / "stdout").stat().st_size
                    err_b = (d / "stderr").stat().st_size
                except OSError:
                    out_b = err_b = 0
                log_trip(j["trip"], "job", j["cmd_repr"],
                         int((j["ended_at"] - j["started_at"]) * 1000),
                         j["proc"].returncode, out_b, err_b,
                         t_received=j.get("t_received"))
            threading.Thread(target=watch, daemon=True).start()
            reap_old_jobs()
            return self._send(200, {"job_id": job_id,
                                    "_t_received": t_received_ms})
        if path.startswith("/jobs/") and path.endswith("/kill"):
            job_id = path.split("/")[2]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if job is None:
                return self._send(404, {"error": "no such job"})
            if job_state(job) == "running":
                try:
                    os.killpg(job["proc"].pid, signal.SIGTERM)
                except OSError:
                    pass

                def hard_kill(j=job):
                    time.sleep(5)
                    if j["proc"].poll() is None:
                        try:
                            os.killpg(j["proc"].pid, signal.SIGKILL)
                        except OSError:
                            pass
                threading.Thread(target=hard_kill, daemon=True).start()
            return self._send(200, {"ok": True, "job_id": job_id})
        return self._send(404, {"error": "no such route"})


def main():
    (STATE_DIR / "jobs").mkdir(parents=True, exist_ok=True)
    srv = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    print(f"laptop-agent listening on {BIND_HOST}:{BIND_PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
