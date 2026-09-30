#!/bin/bash
# ~/tools/install-mcpx-service.sh — install the mcpx systemd unit.
# /etc is ephemeral, so init.sh runs this every boot: copy the canonical
# unit file, daemon-reload, enable --now. Idempotent.
set -u
SRC=/home/hatch/tools/mcpx.service
UNIT=/etc/systemd/system/mcpx.service

# mcpx may not be installed yet (profile install happens separately).
# Skip quietly — a later init poll (or manual run) will pick it up.
if [ ! -x /usr/local/bin/mcpx ] && [ ! -x /home/hatch/.nix-profile/bin/mcpx ]; then
  echo "install-mcpx-service: mcpx not installed, skipping"
  exit 0
fi

cp "$SRC" "$UNIT"
systemctl daemon-reload
systemctl enable --now mcpx.service
sleep 2
if systemctl is-active --quiet mcpx.service; then
  echo "install-mcpx-service: mcpx.service active"
else
  echo "install-mcpx-service: mcpx.service NOT active after enable --now:"
  systemctl status mcpx.service --no-pager 2>&1 | head -15
  exit 1
fi
