#!/bin/bash
# tools/install-mcpx-servers.sh — (re)install the lootbox-parity MCP server binaries.
# Idempotent. Everything lands on the persistent volume (~/.local, ~/tools/bin,
# ~/git), so a sandbox recycle only needs node (base image) + this script.
# Versions pinned 2026-09-30; codebase-memory + gopls pins added 2026-10-25.
# NPM_PREFIX / LOCAL_BIN / GO may be overridden (scratch-prefix testing).
# The npm/go installs below are network-heavy; beyond the curl/gh/git
# bounds added inline, they rely on init.sh running this script as a
# deferred step under a 900s run_step budget — a network stall fails
# the step instead of hanging the boot sequence (hardening 2026-10-25).
set -euo pipefail

NPM_PREFIX="${NPM_PREFIX:-$HOME/.local/npm-global}"
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"
BIN="$HOME/tools/bin"
CHROME_DIR="$HOME/.local/share/chrome"
GO="${GO:-$HOME/tools/go/bin/go}"

mkdir -p "$NPM_PREFIX" "$LOCAL_BIN" "$BIN" "$CHROME_DIR" \
  "$HOME/.local/share/fff" "$HOME/.local/share/opencode/worktree" "$HOME/git"

# /tmp is a 512 MB tmpfs that CANNOT be enlarged from inside the sandbox
# (platform-owned locked mount — see TOOLS.d/sandbox.md). Staging for the
# installs below (codebase-memory's ~330 MB native binary, npm's fetch tree,
# go's build work) overflows it and collides with other tools' spill, so
# ALL temp work for this script goes to the persistent volume instead.
mkdir -p "$HOME/tmp"
export TMPDIR="$HOME/tmp"
export GOTMPDIR="$HOME/tmp"

# --- npm MCP servers (node comes from the base image) ---
export PATH="$NPM_PREFIX/bin:$PATH"
npm install -g --prefix "$NPM_PREFIX" \
  chrome-devtools-mcp \
  mcp-remote

# --- codebase-memory-mcp (pinned; installed bare-name for the mcpx daemon) ---
# The old npx launch form re-walked the registry + a 330 MB binary download
# on every cold start and blew mcpx's initialize deadline (2026-10-25). A
# pinned global install starts in ~3 s; skip when the version already matches.
CBM_VER=0.12.1
if [ "$("$NPM_PREFIX/bin/codebase-memory-mcp" --version 2>/dev/null | awk '{print $NF}')" != "$CBM_VER" ]; then
  npm install -g --prefix "$NPM_PREFIX" "codebase-memory-mcp@$CBM_VER"
fi

# --- gopls (pinned; prebuilt via go install for the mcpx gopls-mcp-server) ---
# The old launch form was `go run golang.org/x/tools/gopls@latest` on every
# cold start: network re-resolution + a full gopls compile (~300 MB of build
# spill) before initialize could answer — handshake deadlines on both the
# sandbox and the laptop (2026-10-25). Prebuilt binary starts in ~7 s.
GOPLS_VER=v0.24.0
if [ "$("$LOCAL_BIN/gopls" version 2>/dev/null | awk '{print $NF}')" != "$GOPLS_VER" ]; then
  GOBIN="$LOCAL_BIN" "$GO" install "golang.org/x/tools/gopls@$GOPLS_VER"
fi

# --- fff-mcp (dmtrKovalenko/fff nightly; not in nixpkgs, not on npm) ---
if [ ! -x "$BIN/fff-mcp" ]; then
  tmp=$(mktemp -d)
  timeout 300 gh release download 0.11.1-nightly.89c1927 --repo dmtrKovalenko/fff \
    --pattern 'fff-mcp-x86_64-unknown-linux-gnu*' --dir "$tmp"
  (cd "$tmp" && sha256sum -c fff-mcp-x86_64-unknown-linux-gnu.sha256)
  install -m 755 "$tmp/fff-mcp-x86_64-unknown-linux-gnu" "$BIN/fff-mcp"
  rm -rf "$tmp"
fi

# --- codedb (justrach/codedb) ---
if [ ! -x "$BIN/codedb" ]; then
  tmp=$(mktemp -d)
  timeout 300 gh release download v0.2.5860 --repo justrach/codedb \
    --pattern 'codedb-linux-x86_64' --dir "$tmp"
  install -m 755 "$tmp/codedb-linux-x86_64" "$BIN/codedb"
  rm -rf "$tmp"
fi

# --- Chrome headless shell (chrome-devtools-mcp has no bundled browser) ---
if [ ! -x "$CHROME_DIR/chrome-headless-shell-linux64/chrome-headless-shell" ]; then
  url=$(curl -s --max-time 30 https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print([x['url'] for x in d['channels']['Stable']['downloads']['chrome-headless-shell'] if x['platform']=='linux64'][0])")
  tmp=$(mktemp -d)
  curl -sL --max-time 600 -o "$tmp/chrome.zip" "$url"
  unzip -q -o "$tmp/chrome.zip" -d "$CHROME_DIR"
  rm -rf "$tmp"
fi

# --- fff-nix index target: persistent clone of Drew's nix config ---
if [ ! -d "$HOME/git/nix/.git" ]; then
  timeout 300 git clone --quiet https://github.com/dezren39/nix.git "$HOME/git/nix"
fi

echo "mcpx servers installed (codebase-memory-mcp $CBM_VER, gopls $GOPLS_VER). Restart the daemon: systemctl restart mcpx"
