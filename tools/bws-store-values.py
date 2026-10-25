#!/usr/bin/env python3
"""Store k=v lines from a staging file as Bitwarden secrets, verify, shred staging file.
Usage: bws-store-values.py /tmp/staging.tmp   (BWS_ACCESS_TOKEN must be in env)
Values are never printed; only key names and OK/FAIL status.
"""
import hashlib
import json
import os
import subprocess
import sys

PROJECT = "d370cd10-3d67-4b34-b61a-b4dc00753f97"
DATE = "2026-10-07"
NOTES = {
    "cloudflare.api-token-account-wide":
        f"Account-wide Cloudflare API token. Stored {DATE}. NEVER put in Worker "
        "secrets/env - mint scoped tokens from it instead.",
    "cloudflare.r2-access-key-id":
        f"R2 S3 Access Key ID (nix-cache-nars). Stored {DATE}. "
        "Also set as Worker secret R2_ACCESS_KEY_ID.",
    "cloudflare.r2-secret-access-key":
        f"R2 S3 Secret Access Key (nix-cache-nars). Stored {DATE}. "
        "Also set as Worker secret R2_SECRET_ACCESS_KEY.",
    "cloudflare.r2-endpoint":
        f"R2 S3 API endpoint for account 234b866b99ce2b142d7963d8d139cbfa. "
        f"Stored {DATE}. Kept with the R2 creds; also set as Worker secret R2_ACCOUNT_ID "
        "(worker builds the endpoint from the account id).",
    "cloudflare.api-token-day-to-day":
        f"Scoped day-to-day Cloudflare API token (minted {DATE} from the account-wide "
        "token). Use for routine wrangler/API work; the account-wide token stays in the vault.",
}


def run(*args, input_text=None):
    return subprocess.run(
        list(args), capture_output=True, text=True, timeout=120,
        input=input_text)


def bw_secret_id(key):
    r = run("bws", "secret", "list")
    for s in json.loads(r.stdout or "[]"):
        if s.get("key") == key:
            return s["id"]
    return None


def bw_value(secret_id):
    r = run("bws", "secret", "get", secret_id, "-o", "json")
    obj = json.loads(r.stdout)
    return obj[0]["value"] if isinstance(obj, list) else obj["value"]


def main():
    staging = sys.argv[1]
    pairs = []
    with open(staging) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or "=" not in line:
                continue
            k, v = line.split("=", 1)
            pairs.append((k, v))
    fail = 0
    for key, value in pairs:
        note = NOTES.get(key, f"Stored {DATE}.")
        existing = bw_secret_id(key)
        if existing:
            got = bw_value(existing)
            if hashlib.sha256(got.encode()).hexdigest() == hashlib.sha256(value.encode()).hexdigest():
                print(f"OK {key} (already correct)")
                continue
            run("bws", "secret", "delete", existing, "-o", "none")
            print(f"REWRITE {key}")
        r = run("bws", "secret", "create", "--note", note, "-o", "json",
                "--", key, value, PROJECT)
        try:
            sid = json.loads(r.stdout)["id"]
        except Exception:
            print(f"FAIL {key}: create error: {(r.stderr or '')[-200:]}")
            fail = 1
            continue
        got = bw_value(sid)
        if hashlib.sha256(got.encode()).hexdigest() == hashlib.sha256(value.encode()).hexdigest():
            print(f"OK {key} (created, verified)")
        else:
            print(f"FAIL {key}: round-trip mismatch")
            fail = 1
    # shred staging file
    try:
        size = os.path.getsize(staging)
        with open(staging, "r+b") as f:
            f.write(os.urandom(size))
        os.unlink(staging)
        print("staging shredded")
    except OSError as e:
        print(f"WARN: could not shred staging file: {e}")
        fail = 1
    print(f"fail={fail}")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
