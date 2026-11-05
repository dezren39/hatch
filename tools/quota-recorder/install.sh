#!/usr/bin/env bash
# install.sh — idempotent installer for the quota-recorder systemd
# units. /etc/systemd/system does not survive sandbox recycles, so
# ~/tools/init.sh calls this on every boot where the timer is not
# active (the same restore pattern as the other unit families,
# code#6148). Safe to re-run any time. No apt/network dependency:
# a failure here is genuine and init counts it.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"

cp "$DIR/quota-recorder.service" /etc/systemd/system/quota-recorder.service
cp "$DIR/quota-recorder.timer" /etc/systemd/system/quota-recorder.timer
systemctl daemon-reload
systemctl enable --now quota-recorder.timer
systemctl is-active --quiet quota-recorder.timer &&
  echo "quota-recorder.timer active" ||
  {
    echo "FAILED to activate quota-recorder.timer"
    exit 1
  }
