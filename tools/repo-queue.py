#!/usr/bin/env python3
"""repo-queue.py — CLI helper for the repo-health queue/worker pilot.

Design: ~/workspace/goals/keep-the-four-repos-healthy/files/
        queue-worker-pilot-design-2026-10-25.md (v1.1)

Talks to Supabase PostgREST (schema `agent`) using the service-role key,
fetched transiently from Bitwarden Secrets Manager at runtime (item
`supabase.service-role-key`) — the value is never printed, logged, or
written to disk. HTTP goes through curl subprocesses (urllib chunked
reads are unreliable through this sandbox's egress proxy).

Packet files are JSON with an envelope plus the repo-task/v1 payload:

    {
      "title": "...",                  # required, agent.tasks.title
      "body": "...",                   # optional, ~250 words max (warn)
      "priority": 40,                  # required, design scale value
      "dedupe_key": "repo-health:v1:...",  # required, deterministic
      "not_before": "2026-10-25T12:00:00Z",# optional
      "max_attempts": 2,               # optional (else payload's)
      "payload": { ...repo-task/v1 payload, see
                   ~/tools/repo-task-v1.schema.json... }
    }

Environment overrides:
    REPO_QUEUE_SUPABASE_URL   default: Bitwarden supabase.project-url
    REPO_QUEUE_DEFAULT_QUEUE  default repo-health-code-shadow (Phase 0:
                              the shadow queue; live cutover will pass
                              --queue repo-health-code-pilot explicitly)
    REPO_QUEUE_SCHEMA_PATH    default ~/tools/repo-task-v1.schema.json
    REPO_QUEUE_SIGNAL_PATH    default <goal>/hidden_files/repo-queue-signal.json
    REPO_QUEUE_SERVICE_ROLE_KEY  pre-set key (skips the Bitwarden fetch)

Exit codes:
    0  success (for claim: a task was claimed)
    2  usage / packet validation failure
    3  configuration or credential failure
    4  HTTP / PostgREST error
    5  operation matched no row (e.g. claim found nothing claimable,
       complete/park/block/fail on a task not claimed by the worker)
"""
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

PROJECT_URL = "https://keihfchslgjetkmnmzra.supabase.co"  # fallback only; canonical value is Bitwarden `supabase.project-url`
DEFAULT_QUEUE = "repo-health-code-shadow"
DEFAULT_WORKER = "repo-worker-code"
PILOT_REPO = "developing-today/code"
FLEET_REPOS = ["developing-today/code", "developing-today/opencode",
               "developing-today/openchamber", "dezren39/nix"]
REPO_ALT = ("(?:developing-today/code|developing-today/opencode|"
            "developing-today/openchamber|dezren39/nix)")
BWS = os.path.expanduser("~/tools/bin/bws")
BWS_TOKEN_FILE = os.path.expanduser("~/.config/bitwarden/access-token")
SECRET_NAME = "supabase.service-role-key"
GOAL_DIR = os.path.expanduser(
    "~/workspace/goals/keep-the-four-repos-healthy/hidden_files")
DEFAULT_SIGNAL_PATH = os.path.join(GOAL_DIR, "repo-queue-signal.json")
PRIORITY_SCALE = {10, 20, 30, 40, 50, 70, 90}
KINDS = {"pr_shepherd", "triage", "small_fix", "ci_investigation"}
PAYLOAD_WARN_BYTES = 4096    # design target: payload normally below 4 KB
PAYLOAD_MAX_BYTES = 16384    # hard ceiling enforced by the validator
BODY_WARN_WORDS = 250        # design target for the human-readable body

DEDUPE_PATTERNS_DOC = (
    "fix:         repo-health:v1:fix:<repo>:issue:<n>\n"
    "triage:      repo-health:v1:triage:<repo>:issue:<n>\n"
    "pr:          repo-health:v1:pr:<repo>:pr:<n>\n"
    "pr-set:      repo-health:v1:pr-set:<repo>:<n>-<n>[-...] (sorted)\n"
    "set:         repo-health:v1:set:<origin issue>:owed:<repo>\n"
    "maintenance: repo-health:v1:maintenance:<repo>:<kind>:<YYYY-Www>"
)


def eprint(*args):
    print(*args, file=sys.stderr)


def die(code, msg):
    eprint(f"repo-queue: {msg}")
    sys.exit(code)


def utcnow_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# Credentials + HTTP (curl; secret lives only in a 0600 temp config file)
# --------------------------------------------------------------------------

def get_service_key():
    env_key = os.environ.get("REPO_QUEUE_SERVICE_ROLE_KEY")
    if env_key:
        return env_key
    env = dict(os.environ)
    if "BWS_ACCESS_TOKEN" not in env:
        try:
            with open(BWS_TOKEN_FILE) as f:
                env["BWS_ACCESS_TOKEN"] = f.read().strip()
        except OSError:
            die(3, "no Bitwarden access token file and "
                   "REPO_QUEUE_SERVICE_ROLE_KEY is unset")
    bws = BWS if os.path.exists(BWS) else "bws"
    try:
        out = subprocess.run([bws, "secret", "list", "-o", "json"],
                             capture_output=True, text=True, env=env,
                             timeout=60)
        if out.returncode != 0:
            die(3, f"bws secret list failed: {out.stderr.strip()[:200]}")
        sid = next((s["id"] for s in json.loads(out.stdout)
                    if s.get("key") == SECRET_NAME), None)
        if sid is None:
            die(3, f"Bitwarden secret {SECRET_NAME!r} not found")
        got = subprocess.run([bws, "secret", "get", sid, "-o", "json"],
                             capture_output=True, text=True, env=env,
                             timeout=60)
        if got.returncode != 0:
            die(3, f"bws secret get failed: {got.stderr.strip()[:200]}")
        return json.loads(got.stdout)["value"]
    except (subprocess.SubprocessError, ValueError, KeyError) as exc:
        die(3, f"credential fetch failed: {exc}")


def get_project_url():
    """Canonical project URL from Bitwarden (`supabase.project-url`) so a
    project move is a Bitwarden change, not a code change. Falls back to
    PROJECT_URL if the lookup fails."""
    env = dict(os.environ)
    if "BWS_ACCESS_TOKEN" not in env:
        try:
            with open(BWS_TOKEN_FILE) as f:
                env["BWS_ACCESS_TOKEN"] = f.read().strip()
        except OSError:
            return PROJECT_URL
    bws = BWS if os.path.exists(BWS) else "bws"
    try:
        out = subprocess.run([bws, "secret", "list", "-o", "json"],
                             capture_output=True, text=True, env=env,
                             timeout=60)
        sid = next((s["id"] for s in json.loads(out.stdout)
                    if s.get("key") == "supabase.project-url"), None)
        if sid is None:
            return PROJECT_URL
        got = subprocess.run([bws, "secret", "get", sid, "-o", "json"],
                             capture_output=True, text=True, env=env,
                             timeout=60)
        return json.loads(got.stdout)["value"]
    except (subprocess.SubprocessError, ValueError, KeyError):
        return PROJECT_URL


def base_url():
    if "REPO_QUEUE_SUPABASE_URL" in os.environ:
        return os.environ["REPO_QUEUE_SUPABASE_URL"].rstrip("/")
    return get_project_url().rstrip("/")


def http(method, path, key, body=None, extra_headers=(), want_headers=False):
    """One PostgREST request via curl. Returns parsed JSON (and headers
    when want_headers). Dies with exit 4 on HTTP >= 300."""
    url = f"{base_url()}/rest/v1/{path}"
    cfg_lines = [
        f'header = "apikey: {key}"',
        f'header = "Authorization: Bearer {key}"',
        'header = "Accept-Profile: agent"',
    ]
    if method in ("POST", "PATCH"):
        cfg_lines.append('header = "Content-Profile: agent"')
        cfg_lines.append('header = "Content-Type: application/json"')
    for h in extra_headers:
        cfg_lines.append(f'header = "{h}"')
    data_path = None
    hdr_path = None
    cfg = tempfile.NamedTemporaryFile("w", suffix=".curlcfg", delete=False)
    try:
        os.chmod(cfg.name, 0o600)
        cfg.write("\n".join(cfg_lines) + "\n")
        cfg.close()
        cmd = ["curl", "-sS", "-m", "60", "-A", "Mozilla/5.0",
               "-K", cfg.name, "-X", method, url, "-w", "\n%{http_code}"]
        if want_headers:
            hdr = tempfile.NamedTemporaryFile("w", suffix=".hdrs",
                                              delete=False)
            hdr_path = hdr.name
            hdr.close()
            cmd += ["-D", hdr_path]
        if body is not None:
            data = tempfile.NamedTemporaryFile("w", suffix=".json",
                                               delete=False)
            data_path = data.name
            json.dump(body, data)
            data.close()
            cmd += ["--data-binary", f"@{data_path}"]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        if out.returncode != 0:
            die(4, f"curl failed: {out.stderr.strip()[:300]}")
        text, _, code_s = out.stdout.rpartition("\n")
        code = int(code_s)
        if code >= 300:
            die(4, f"HTTP {code} from PostgREST: {text.strip()[:500]}")
        parsed = json.loads(text) if text.strip() else None
        if want_headers:
            headers = {}
            with open(hdr_path) as f:
                for line in f:
                    if ":" in line:
                        k, _, v = line.partition(":")
                        headers[k.strip().lower()] = v.strip()
            return parsed, headers
        return parsed
    finally:
        for p in (cfg.name, data_path, hdr_path):
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass


def rpc(fn_name, args, key):
    """Call an agent-schema RPC. PostgREST returns a composite row as a
    plain JSON object and SQL NULL as an empty body / null."""
    result = http("POST", f"rpc/{fn_name}", key, body=args)
    return result


def print_json(obj):
    print(json.dumps(obj, indent=2, default=str))


# --------------------------------------------------------------------------
# Packet validation (repo-task/v1)
# --------------------------------------------------------------------------

import re

_RE_ISSUE = r"(?P<num>\d+)"
DEDUPE_REGEXES = {
    "fix": re.compile(rf"^repo-health:v1:fix:(?P<repo>{REPO_ALT}):issue:{_RE_ISSUE}$"),
    "triage": re.compile(rf"^repo-health:v1:triage:(?P<repo>{REPO_ALT}):issue:{_RE_ISSUE}$"),
    "pr": re.compile(rf"^repo-health:v1:pr:(?P<repo>{REPO_ALT}):pr:{_RE_ISSUE}$"),
    "pr-set": re.compile(rf"^repo-health:v1:pr-set:(?P<repo>{REPO_ALT}):(?P<nums>\d+(?:-\d+)*)$"),
    "set": re.compile(rf"^repo-health:v1:set:{_RE_ISSUE}:owed:(?P<repo>{REPO_ALT})$"),
    "maintenance": re.compile(
        rf"^repo-health:v1:maintenance:(?P<repo>{REPO_ALT}):([a-z0-9][a-z0-9_-]*):(\d{{4}}-W\d{{2}})$"),
}
# Which dedupe families each task kind may use (design: deterministic keys).
KIND_DEDUPE_FAMILIES = {
    "small_fix": {"fix"},
    "triage": {"triage", "maintenance"},
    "pr_shepherd": {"pr", "pr-set", "set"},
    "ci_investigation": {"fix", "triage", "pr"},
}


def schema_errors(payload):
    """Validate the payload against repo-task-v1.schema.json with the
    jsonschema library when available; fall back to built-in checks."""
    schema_path = os.environ.get(
        "REPO_QUEUE_SCHEMA_PATH",
        os.path.expanduser("~/tools/repo-task-v1.schema.json"))
    try:
        import jsonschema
    except ImportError:
        return _manual_schema_errors(payload)
    try:
        with open(schema_path) as f:
            schema = json.load(f)
    except OSError:
        return _manual_schema_errors(payload)
    validator = jsonschema.Draft202012Validator(schema)
    errs = []
    for err in sorted(validator.iter_errors(payload),
                      key=lambda e: list(e.absolute_path)):
        parts = [str(p) for p in err.absolute_path]
        if not parts:
            # e.g. a missing required property: name the field, not "(payload)"
            m = re.match(r"'([^']+)' is a required property", err.message)
            parts = [m.group(1)] if m else []
        path = ".".join(parts)
        errs.append(f"payload.{path}: {err.message}" if path
                    else f"payload: {err.message}")
    return errs


def _manual_schema_errors(p):
    errs = []

    def req(field):
        if field not in p or p[field] in (None, "", [], {}):
            errs.append(f"payload.{field}: required field missing or empty")

    if not isinstance(p, dict):
        return ["payload: must be a JSON object"]
    if p.get("schema") != "repo-task/v1":
        errs.append("payload.schema: must be 'repo-task/v1'")
    if p.get("kind") not in KINDS:
        errs.append(f"payload.kind: must be one of {sorted(KINDS)}")
    if p.get("repo") not in FLEET_REPOS:
        errs.append(f"payload.repo: {p.get('repo')!r} is not a fleet repo")
    for f in ("problem", "priority_reason"):
        req(f)
    for f in ("evidence", "acceptance", "tests", "context_refs"):
        if not isinstance(p.get(f), list):
            errs.append(f"payload.{f}: must be a list")
    for f in ("evidence", "acceptance", "tests"):
        if isinstance(p.get(f), list) and not p[f]:
            errs.append(f"payload.{f}: must not be empty")
    scope = p.get("scope")
    if not isinstance(scope, dict):
        errs.append("payload.scope: must be an object with include/exclude")
    else:
        if not isinstance(scope.get("include"), list):
            errs.append("payload.scope.include: must be a list")
        if not scope.get("exclude"):
            errs.append("payload.scope.exclude: required (scope exclusions)")
    risk = p.get("risk")
    if not isinstance(risk, dict) or risk.get("level") not in (
            "low", "medium", "high"):
        errs.append("payload.risk.level: must be low|medium|high")
    elif not isinstance(risk.get("flags"), list):
        errs.append("payload.risk.flags: must be a list")
    for f in ("timebox_minutes", "max_attempts"):
        if not isinstance(p.get(f), int) or p.get(f, 0) < 1:
            errs.append(f"payload.{f}: must be a positive integer")
    ded = p.get("dedupe")
    if not isinstance(ded, dict) or not ded.get("checked_at") \
            or not ded.get("basis"):
        errs.append("payload.dedupe: must have checked_at and basis")
    has_issue = isinstance(p.get("issue"), dict) \
        and isinstance(p["issue"].get("number"), int)
    has_prs = isinstance(p.get("prs"), list) and len(p["prs"]) > 0
    has_set = isinstance(p.get("set"), dict)
    has_source = isinstance(p.get("source"), dict) \
        and isinstance(p["source"].get("pr"), int) \
        and bool(p["source"].get("finding"))
    if not (has_issue or has_prs or has_set or has_source):
        errs.append("payload identity: need issue.number, a non-empty prs "
                    "list, a set object, or a pre-filing source {pr, finding}")
    return errs


def validate_packet(packet):
    """Return (errors, warnings) for a full packet file object."""
    errors, warnings = [], []
    if not isinstance(packet, dict):
        return ["packet: must be a JSON object"], []
    payload = packet.get("payload")
    if not isinstance(payload, dict):
        return ["packet.payload: required object (repo-task/v1 payload)"], []

    # JSON-Schema / built-in structural checks on the payload.
    errors.extend(schema_errors(payload))

    # Envelope checks.
    title = packet.get("title")
    if not isinstance(title, str) or not title.strip():
        errors.append("packet.title: required non-empty string")
    priority = packet.get("priority")
    if priority is None:
        errors.append("packet.priority: required (numeric priority from "
                      "the design scale: 10, 20, 30, 40, 50, 70, 90)")
    elif not isinstance(priority, int) or isinstance(priority, bool):
        errors.append("packet.priority: must be an integer")
    elif priority not in PRIORITY_SCALE:
        errors.append(f"packet.priority: {priority} is not on the design "
                      f"scale {sorted(PRIORITY_SCALE)}")
    body = packet.get("body")
    if isinstance(body, str) and len(body.split()) > BODY_WARN_WORDS:
        warnings.append(f"packet.body: {len(body.split())} words exceeds "
                        f"the ~{BODY_WARN_WORDS}-word design target")

    # Payload size guard (design: normally < 4 KB; hard ceiling 16 KB).
    size = len(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    if size > PAYLOAD_MAX_BYTES:
        errors.append(f"payload size: {size} bytes exceeds the "
                      f"{PAYLOAD_MAX_BYTES}-byte hard ceiling (evidence and "
                      "pointers, not full diffs/logs)")
    elif size > PAYLOAD_WARN_BYTES:
        warnings.append(f"payload size: {size} bytes is above the "
                        f"{PAYLOAD_WARN_BYTES}-byte design target")

    # Soft design-convention warnings.
    tb = payload.get("timebox_minutes")
    if isinstance(tb, int) and tb not in (20, 45):
        warnings.append(f"payload.timebox_minutes: {tb} is not a standard "
                        "design timebox (20 triage / 45 standard)")
    ma = payload.get("max_attempts")
    kind = payload.get("kind")
    if isinstance(ma, int):
        want = 3 if kind in ("triage", "ci_investigation") else 2
        if ma != want:
            warnings.append(f"payload.max_attempts: design default for "
                            f"{kind} is {want}, packet says {ma}")

    # Dedupe key: format family, kind consistency, identity cross-check.
    errors.extend(_dedupe_errors(packet, payload))
    return errors, warnings


def _dedupe_errors(packet, payload):
    errors = []
    key = packet.get("dedupe_key")
    if not isinstance(key, str) or not key:
        return ["packet.dedupe_key: required deterministic key:\n"
                + DEDUPE_PATTERNS_DOC]
    family, match = None, None
    for fam, rx in DEDUPE_REGEXES.items():
        m = rx.match(key)
        if m:
            family, match = fam, m
            break
    if family is None:
        return [f"packet.dedupe_key: {key!r} matches no design pattern:\n"
                + DEDUPE_PATTERNS_DOC]
    key_repo = match.group("repo")
    if payload.get("repo") is not None and key_repo != payload.get("repo"):
        errors.append(f"packet.dedupe_key: repo {key_repo!r} in key does "
                      f"not match payload.repo {payload.get('repo')!r}")
    kind = payload.get("kind")
    allowed = KIND_DEDUPE_FAMILIES.get(kind)
    if allowed is not None and family not in allowed:
        errors.append(f"packet.dedupe_key: family {family!r} is not valid "
                      f"for kind {kind!r} (allowed: {sorted(allowed)})")
    issue_no = None
    if isinstance(payload.get("issue"), dict):
        issue_no = payload["issue"].get("number")
    pr_numbers = []
    if isinstance(payload.get("prs"), list):
        pr_numbers = [p.get("number") for p in payload["prs"]
                      if isinstance(p, dict)]
    if family in ("fix", "triage"):
        n = int(match.group("num"))
        if issue_no is not None and n != issue_no:
            errors.append(f"packet.dedupe_key: issue {n} in key does not "
                          f"match payload.issue.number {issue_no}")
    elif family == "pr":
        n = int(match.group("num"))
        if pr_numbers and n not in pr_numbers:
            errors.append(f"packet.dedupe_key: PR {n} in key is not in "
                          f"payload.prs {pr_numbers}")
    elif family == "pr-set":
        nums = [int(x) for x in match.group("nums").split("-")]
        if nums != sorted(nums):
            errors.append("packet.dedupe_key: pr-set numbers must be "
                          "sorted ascending")
        if pr_numbers and nums != sorted(pr_numbers):
            errors.append(f"packet.dedupe_key: pr-set {nums} does not "
                          f"match payload.prs {sorted(pr_numbers)}")
    elif family == "set":
        origin = int(match.group("num"))
        st = payload.get("set")
        if isinstance(st, dict) and st.get("origin_issue") is not None \
                and st["origin_issue"] != origin:
            errors.append(f"packet.dedupe_key: origin issue {origin} does "
                          f"not match payload.set.origin_issue "
                          f"{st['origin_issue']}")
    return errors


def load_packet(path):
    try:
        with open(path) as f:
            return json.load(f)
    except OSError as exc:
        die(2, f"cannot read packet file: {exc}")
    except ValueError as exc:
        die(2, f"packet file is not valid JSON: {exc}")


def check_packet(packet, quiet=False):
    errors, warnings = validate_packet(packet)
    for w in warnings:
        eprint(f"warning: {w}")
    if errors:
        for e in errors:
            eprint(f"error: {e}")
        die(2, f"packet validation failed ({len(errors)} error(s))")
    if not quiet:
        eprint("packet valid (repo-task/v1)")
    return warnings


def task_from_packet(packet, queue):
    payload = packet["payload"]
    return {
        "queue": queue,
        "title": packet["title"],
        "body": packet.get("body"),
        "payload": payload,
        "dedupe_key": packet["dedupe_key"],
        "priority": packet["priority"],
        "not_before": packet.get("not_before"),
        "max_attempts": packet.get("max_attempts",
                                   payload.get("max_attempts")),
    }


# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------

def default_queue():
    return os.environ.get("REPO_QUEUE_DEFAULT_QUEUE", DEFAULT_QUEUE)


def cmd_validate(args):
    packet = load_packet(args.packet)
    check_packet(packet)
    print_json({"valid": True, "dedupe_key": packet.get("dedupe_key"),
                "kind": packet.get("payload", {}).get("kind"),
                "title": packet.get("title")})
    return 0


def cmd_enqueue(args):
    packet = load_packet(args.packet)
    check_packet(packet, quiet=args.dry_run)
    queue = args.queue or default_queue()
    task = task_from_packet(packet, queue)
    if args.dry_run:
        out = dict(task)
        out["_dry_run"] = True
        out["_rpc"] = "agent.enqueue_repo_task"
        print_json(out)
        return 0
    repo = (packet.get("payload") or {}).get("repo")
    rpc_name = ("enqueue_repo_task" if repo in (None, PILOT_REPO)
                else "enqueue_repo_task_fleet")
    key = get_service_key()
    result = rpc(rpc_name, {
        "p_queue": task["queue"],
        "p_title": task["title"],
        "p_body": task["body"],
        "p_payload": task["payload"],
        "p_dedupe_key": task["dedupe_key"],
        "p_priority": task["priority"],
        "p_not_before": task["not_before"],
        "p_max_attempts": task["max_attempts"],
    }, key)
    if result is None:
        die(5, f"{rpc_name} returned no row")
    print_json(result)
    return 0


def _execution_arg(args):
    raw = getattr(args, "execution", None)
    if raw is None:
        return None
    try:
        val = json.loads(raw)
    except ValueError as exc:
        die(2, f"--execution is not valid JSON: {exc}")
    if not isinstance(val, dict):
        die(2, "--execution must be a JSON object")
    lane = val.get("lane")
    if lane is not None and lane not in ("opencode", "direct"):
        die(2, "--execution.lane must be 'opencode' or 'direct'")
    return val


def _record_execution(args, key):
    """Record the executed lane into the lane ledger (migration 0010).

    Called AFTER a terminal/park verb has succeeded, only when the caller
    passed --execution. Returns the ledger row, or None when no
    --execution was given. A missing ledger row raises in the RPC, which
    surfaces here as an HTTP error — loud by design (an unrecorded lane
    outcome is a protocol defect), and it cannot undo the terminal verb.
    """
    ex = _execution_arg(args)
    if ex is None:
        return None
    return rpc("record_repo_task_lane_execution", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_executed_lane": ex.get("lane"),
        "p_fallback_reason": ex.get("fallback_reason"),
        "p_session_id": ex.get("session_id"),
    }, key)


def cmd_lane(args):
    key = get_service_key()
    result = rpc("assign_repo_task_lane", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_exclusion_reason": getattr(args, "exclusion_reason", None),
    }, key)
    return _require_row(result, "assign_repo_task_lane")


def cmd_claim(args):
    key = get_service_key()
    result = rpc("claim_repo_task", {
        "p_worker": args.worker,
        "p_queue": args.queue or default_queue(),
        "p_lease_seconds": args.lease_seconds,
    }, key)
    if result is None:
        eprint("repo-queue: no claimable task")
        print_json({"task": None})
        return 5
    print_json(result)
    return 0


def _progress_arg(args):
    raw = getattr(args, "progress", None)
    pfile = getattr(args, "progress_file", None)
    if raw and pfile:
        die(2, "pass only one of --progress / --progress-file")
    if pfile:
        try:
            with open(pfile) as f:
                raw = f.read()
        except OSError as exc:
            die(2, f"cannot read progress file: {exc}")
    if raw is None:
        return None
    try:
        val = json.loads(raw)
    except ValueError as exc:
        die(2, f"--progress is not valid JSON: {exc}")
    if not isinstance(val, dict):
        die(2, "--progress must be a JSON object")
    return val


def _require_row(result, what):
    if result is None:
        die(5, f"{what}: no matching claimed row (task not claimed by "
               "this worker, or already terminal)")
    print_json(result)
    return 0


def cmd_heartbeat(args):
    key = get_service_key()
    result = rpc("heartbeat_task", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_extend_seconds": args.extend_seconds,
        "p_progress": _progress_arg(args),
    }, key)
    return _require_row(result, "heartbeat_task")


def cmd_checkpoint(args):
    key = get_service_key()
    result = rpc("checkpoint_task", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_stage": args.stage,
        "p_progress": _progress_arg(args) or {},
    }, key)
    return _require_row(result, "checkpoint_task")


def cmd_park(args):
    key = get_service_key()
    result = rpc("park_task", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_reason": args.reason,
        "p_delay_seconds": args.delay_seconds,
        "p_progress": _progress_arg(args) or {},
    }, key)
    if result is None:
        return _require_row(result, "park_task")
    ledger = _record_execution(args, key)
    if ledger is not None:
        print_json({"task": result, "lane_ledger": ledger})
        return 0
    return _require_row(result, "park_task")


def cmd_block(args):
    key = get_service_key()
    result = rpc("block_task", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_reason_class": args.reason_class,
        "p_blocker": args.blocker,
        "p_progress": _progress_arg(args) or {},
    }, key)
    return _require_row(result, "block_task")


def cmd_cancel(args):
    key = get_service_key()
    result = rpc("cancel_repo_task", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_reason": args.reason,
    }, key)
    return _require_row(result, "cancel_repo_task")


def cmd_fail(args):
    key = get_service_key()
    result = rpc("fail_repo_task", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_error": args.error,
        "p_reason_class": args.reason_class,
    }, key)
    if result is None:
        return _require_row(result, "fail_repo_task")
    ledger = _record_execution(args, key)
    if ledger is not None:
        print_json({"task": result, "lane_ledger": ledger})
        return 0
    return _require_row(result, "fail_repo_task")


def cmd_complete(args):
    result_raw = args.result
    if args.result_file:
        try:
            with open(args.result_file) as f:
                result_raw = f.read()
        except OSError as exc:
            die(2, f"cannot read result file: {exc}")
    result_obj = {}
    if result_raw:
        try:
            result_obj = json.loads(result_raw)
        except ValueError as exc:
            die(2, f"--result is not valid JSON: {exc}")
        if not isinstance(result_obj, dict):
            die(2, "--result must be a JSON object")
    ex = _execution_arg(args)
    if ex is not None and "execution" not in result_obj:
        block = {"lane": ex.get("lane"),
                 "session_id": ex.get("session_id"),
                 "fallback": ex.get("fallback_reason") is not None}
        if ex.get("fallback_reason") is not None:
            block["fallback_reason"] = ex["fallback_reason"]
        if ex.get("assigned") is not None:
            block["assigned"] = ex["assigned"]
        result_obj["execution"] = block
    key = get_service_key()
    # complete_task is the EXISTING global function (design v1.1: untouched).
    result = rpc("complete_task", {
        "p_task_id": args.task_id,
        "p_worker": args.worker,
        "p_result": result_obj,
    }, key)
    if result is None:
        return _require_row(result, "complete_task")
    ledger = _record_execution(args, key)
    if ledger is not None:
        print_json({"task": result, "lane_ledger": ledger})
        return 0
    return _require_row(result, "complete_task")


def cmd_health(args):
    key = get_service_key()
    path = "repo_queue_health?select=*"
    if args.queue:
        from urllib.parse import quote
        path += f"&queue=eq.{quote(args.queue, safe='')}"
    rows = http("GET", path, key) or []
    if not rows:
        print("(no queues have tasks)")
        return 0
    cols = list(rows[0].keys())
    str_rows = [[_fmt_cell(r.get(c)) for c in cols] for r in rows]
    widths = [max(len(c), *(len(r[i]) for r in str_rows))
              for i, c in enumerate(cols)]

    def fmt_row(cells):
        return "  ".join(c.ljust(widths[i]) for i, c in enumerate(cells))

    print(fmt_row(cols))
    print(fmt_row(["-" * len(c) for c in cols]))
    for r in str_rows:
        print(fmt_row(r))
    return 0


def _fmt_cell(v):
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        return json.dumps(v, separators=(",", ":"))
    return str(v)


def cmd_signal(args):
    queue = args.queue or default_queue()
    key = get_service_key()
    from urllib.parse import quote
    path = ("tasks?select=id,created_at"
            f"&queue=eq.{quote(queue, safe='')}"
            "&status=eq.queued&order=created_at.asc&limit=1")
    rows, headers = http("GET", path, key,
                         extra_headers=("Prefer: count=exact",),
                         want_headers=True)
    rows = rows or []
    queued_count = len(rows)
    content_range = headers.get("content-range", "")
    if "/" in content_range:
        try:
            queued_count = int(content_range.rsplit("/", 1)[1])
        except ValueError:
            pass
    oldest = rows[0]["created_at"] if rows else None

    signal_path = os.environ.get("REPO_QUEUE_SIGNAL_PATH",
                                 DEFAULT_SIGNAL_PATH)
    state_path = os.path.join(os.path.dirname(signal_path),
                              "repo-queue-signal-state.json")
    generation = 0
    for candidate in (signal_path, state_path):
        try:
            with open(candidate) as f:
                prev = json.load(f)
            if prev.get("queue") == queue:
                generation = max(generation,
                                 int(prev.get("generation", 0)))
        except (OSError, ValueError, TypeError):
            continue
    generation += 1

    signal = {
        "queue": queue,
        "generation": generation,
        "queued_count": queued_count,
        "oldest_queued_at": oldest,
        "updated_at": utcnow_iso(),
        "reason": args.reason,
    }
    os.makedirs(os.path.dirname(signal_path), exist_ok=True)
    _atomic_write_json(signal_path, signal)
    _atomic_write_json(state_path, {"queue": queue,
                                    "generation": generation,
                                    "updated_at": signal["updated_at"]})
    print_json(signal)
    return 0


def _atomic_write_json(path, obj):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, indent=2)
            f.write("\n")
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(3, f"cannot write {path}: {exc}")


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def build_parser():
    import argparse
    p = argparse.ArgumentParser(
        prog="repo-queue.py",
        description="Repo-health queue/worker pilot helper (repo-task/v1).",
        epilog="Exit codes: 0 ok · 2 validation/usage · 3 config/credential"
               " · 4 HTTP/PostgREST · 5 no matching row.")
    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("validate", help="validate a packet file")
    sp.add_argument("packet")
    sp.set_defaults(func=cmd_validate)

    sp = sub.add_parser("enqueue", help="validate + enqueue a packet")
    sp.add_argument("packet")
    sp.add_argument("--queue", default=None)
    sp.add_argument("--dry-run", action="store_true",
                    help="print the would-be task; no credential fetch, "
                         "no network call")
    sp.set_defaults(func=cmd_enqueue)

    sp = sub.add_parser("claim", help="claim one task (claim_repo_task)")
    sp.add_argument("--queue", default=None)
    sp.add_argument("--worker", default=DEFAULT_WORKER)
    sp.add_argument("--lease-seconds", type=int, default=2700)
    sp.set_defaults(func=cmd_claim)

    sp = sub.add_parser("lane", help="assign the execution lane for a "
                        "claimed task (assign_repo_task_lane, #1654)")
    sp.add_argument("task_id", type=int)
    sp.add_argument("--worker", default=DEFAULT_WORKER)
    sp.add_argument("--exclusion-reason", default=None,
                    help="packet cannot run as a session: assign direct "
                         "and record this exclusion (counts toward "
                         "neither lane)")
    sp.set_defaults(func=cmd_lane)

    sp = sub.add_parser("heartbeat", help="extend a claim's lease")
    sp.add_argument("task_id", type=int)
    sp.add_argument("--worker", default=DEFAULT_WORKER)
    sp.add_argument("--extend-seconds", type=int, default=900)
    sp.add_argument("--progress")
    sp.add_argument("--progress-file")
    sp.set_defaults(func=cmd_heartbeat)

    sp = sub.add_parser("checkpoint", help="record a progress checkpoint")
    sp.add_argument("task_id", type=int)
    sp.add_argument("--worker", default=DEFAULT_WORKER)
    sp.add_argument("--stage", required=True)
    sp.add_argument("--progress")
    sp.add_argument("--progress-file")
    sp.set_defaults(func=cmd_checkpoint)

    sp = sub.add_parser("park", help="park a claimed task until a retry time")
    sp.add_argument("task_id", type=int)
    sp.add_argument("--worker", default=DEFAULT_WORKER)
    sp.add_argument("--reason", required=True)
    sp.add_argument("--delay-seconds", type=int, default=1200)
    sp.add_argument("--progress")
    sp.add_argument("--progress-file")
    sp.add_argument("--execution",
                    help="JSON execution block for the lane ledger "
                         "(e.g. session_id bookkeeping on park)")
    sp.set_defaults(func=cmd_park)

    sp = sub.add_parser("block", help="block a claimed task on a named blocker")
    sp.add_argument("task_id", type=int)
    sp.add_argument("--worker", default=DEFAULT_WORKER)
    sp.add_argument("--reason-class", required=True)
    sp.add_argument("--blocker", required=True)
    sp.add_argument("--progress")
    sp.add_argument("--progress-file")
    sp.set_defaults(func=cmd_block)

    sp = sub.add_parser("cancel", help="cancel a queued/parked task that will never be worked (cancel_repo_task)")
    sp.add_argument("task_id", type=int)
    sp.add_argument("--worker", default="fleet-monitor")
    sp.add_argument("--reason", required=True)
    sp.set_defaults(func=cmd_cancel)

    sp = sub.add_parser("fail", help="fail a claimed task (fail_repo_task)")
    sp.add_argument("task_id", type=int)
    sp.add_argument("--worker", default=DEFAULT_WORKER)
    sp.add_argument("--error", required=True)
    sp.add_argument("--reason-class", default="transient",
                    choices=["transient", "deterministic", "blocked"])
    sp.add_argument("--execution",
                    help="JSON execution block {lane, session_id, "
                         "fallback_reason} recorded in the lane ledger")
    sp.set_defaults(func=cmd_fail)

    sp = sub.add_parser("complete",
                        help="complete a claimed task (existing "
                             "agent.complete_task)")
    sp.add_argument("task_id", type=int)
    sp.add_argument("--worker", default=DEFAULT_WORKER)
    sp.add_argument("--result")
    sp.add_argument("--result-file")
    sp.add_argument("--execution",
                    help="JSON execution block {lane, session_id, "
                         "fallback_reason, assigned}: merged into the "
                         "result as result.execution and recorded in "
                         "the lane ledger")
    sp.set_defaults(func=cmd_complete)

    sp = sub.add_parser("health", help="print the repo_queue_health view")
    sp.add_argument("--queue", default=None)
    sp.set_defaults(func=cmd_health)

    sp = sub.add_parser("signal",
                        help="refresh the queue signal file for the hook")
    sp.add_argument("--queue", default=None)
    sp.add_argument("--reason", default="manual_signal")
    sp.set_defaults(func=cmd_signal)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
