#!/usr/bin/env python3
"""SQL against the ORIGINAL muse-dev project ONLY (ref nltgxorqwxhgfzseiirt),
using its preserved scoped token `supabase.muse-dev.access-token-muse-cli`.
Deliberately pinned: this exists for the recovery watch on the frozen legacy
project. For the primary project use ~/tools/supabase-exec.py (canonical)."""
import json, subprocess, sys, os, tempfile
REF = 'nltgxorqwxhgfzseiirt'
def tok():
    out = subprocess.run(['bash','-c','source ~/tools/bws-env.sh >/dev/null 2>&1; SID=$(bws secret list 2>/dev/null | jq -r \'.[] | select(.key=="supabase.muse-dev.access-token-muse-cli") | .id\'); bws secret get "$SID" 2>/dev/null | jq -r .value'], capture_output=True, text=True)
    return out.stdout.strip()
sql = open(sys.argv[1]).read()
with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as tf:
    json.dump({'query': sql}, tf); p = tf.name
r = subprocess.run(['curl','-s','-m','280','-X','POST', f'https://api.supabase.com/v1/projects/{REF}/database/query','-H',f'Authorization: Bearer {tok()}','-H','Content-Type: application/json','-H','User-Agent: Mozilla/5.0','-d','@'+p,'-w','\n%{http_code}'], capture_output=True, text=True)
os.unlink(p)
body, _, code = r.stdout.rpartition('\n')
print(f"HTTP {code}"); print(body)
sys.exit(0 if code.startswith('2') else 1)
