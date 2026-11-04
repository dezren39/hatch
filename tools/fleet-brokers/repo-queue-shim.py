#!/usr/bin/env python3
"""repo-queue.py — compatibility shim (code#5362).

The queue now lives on the laptop behind the session proxy: this shim
execs the Rust client (~/tools/repo-queue), which talks only to the
queue-broker via the laptop-agent broker socket. The legacy direct
implementation (repo_queue_legacy.py — Bitwarden fetch + PostgREST
from the sandbox) remains as the fallback: it runs only when the
client reports the broker path unavailable (exit 3) or when
REPO_QUEUE_VIA_BROKER=0. Its public names are re-exported here so
module importers (e.g. the fleet monitor) keep working.
"""
import os
import sys

sys.path.insert(0, os.path.expanduser("~/tools"))

try:
    from repo_queue_legacy import *  # noqa: F401,F403
    from repo_queue_legacy import (  # noqa: F401
        get_service_key, get_project_url, resolve_project, http, rpc,
        validate_packet, check_packet, load_packet, task_from_packet,
        default_queue, main as _legacy_main,
    )
except Exception:  # legacy module unavailable: CLI fallback impossible
    _legacy_main = None


def _main():
    client = os.path.expanduser("~/tools/repo-queue")
    if os.environ.get("REPO_QUEUE_VIA_BROKER", "1") != "0" \
            and os.path.exists(client):
        import subprocess
        rc = subprocess.call([client] + sys.argv[1:])
        if rc != 3:
            return rc
        print("repo-queue: broker path unavailable (exit 3); "
              "falling back to legacy direct path", file=sys.stderr)
    if _legacy_main is None:
        print("repo-queue: legacy implementation unavailable",
              file=sys.stderr)
        return 3
    return _legacy_main()


if __name__ == "__main__":
    sys.exit(_main())
