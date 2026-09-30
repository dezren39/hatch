#!/bin/bash
# tools/install-mcpx-servers.sh — (re)install the lootbox-parity MCP server binaries.
# Idempotent. Everything lands on the persistent volume (~/.local, ~/tools/bin,
# ~/git), so a sandbox recycle only needs node (base image) + this script.
# Versions pinned 2026-09-30; bump as needed.
set -euo pipefail

NPM_PREFIX="$HOME/.local/npm-global"
BIN="$HOME/tools/bin"
CHROME_DIR="$HOME/.local/share/chrome"

mkdir -p "$NPM_PREFIX" "$BIN" "$CHROME_DIR" \
  "$HOME/.local/share/fff" "$HOME/.local/share/opencode/worktree" "$HOME/git"

# --- npm MCP servers (node comes from the base image) ---
export PATH="$NPM_PREFIX/bin:$PATH"
npm install -g --prefix "$NPM_PREFIX" \
  chrome-devtools-mcp \
  mcp-remote \
  codebase-memory-mcp@0.11.0

# --- fff-mcp (dmtrKovalenko/fff nightly; not in nixpkgs, not on npm) ---
if [ ! -x "$BIN/fff-mcp" ]; then
  tmp=$(mktemp -d)
  gh release download 0.11.1-nightly.89c1927 --repo dmtrKovalenko/fff \
    --pattern 'fff-mcp-x86_64-unknown-linux-gnu*' --dir "$tmp"
  (cd "$tmp" && sha256sum -c fff-mcp-x86_64-unknown-linux-gnu.sha256)
  install -m 755 "$tmp/fff-mcp-x86_64-unknown-linux-gnu" "$BIN/fff-mcp"
  rm -rf "$tmp"
fi

# --- codedb (justrach/codedb) ---
if [ ! -x "$BIN/codedb" ]; then
  tmp=$(mktemp -d)
  gh release download v0.2.5860 --repo justrach/codedb \
    --pattern 'codedb-linux-x86_64' --dir "$tmp"
  install -m 755 "$tmp/codedb-linux-x86_64" "$BIN/codedb"
  rm -rf "$tmp"
fi

# --- Chrome headless shell (chrome-devtools-mcp has no bundled browser) ---
if [ ! -x "$CHROME_DIR/chrome-headless-shell-linux64/chrome-headless-shell" ]; then
  url=$(curl -s https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print([x['url'] for x in d['channels']['Stable']['downloads']['chrome-headless-shell'] if x['platform']=='linux64'][0])")
  tmp=$(mktemp -d)
  curl -sL -o "$tmp/chrome.zip" "$url"
  unzip -q -o "$tmp/chrome.zip" -d "$CHROME_DIR"
  rm -rf "$tmp"
fi

# --- fff-nix index target: persistent clone of Drew's nix config ---
if [ ! -d "$HOME/git/nix/.git" ]; then
  git clone --quiet https://github.com/dezren39/nix.git "$HOME/git/nix"
fi

echo "mcpx servers installed. Restart the daemon: systemctl restart mcpx"
