# TOOLS.d/laptop.md — split verbatim from TOOLS.md 2026-10-25 (token review #2)

## Laptop SSH drops — ROOT CAUSED 2026-10-25 (MaxStartups, not "flakiness")
- The laptop's sshd runs stock **MaxStartups 10:30:100** (no override in
  /etc/ssh/sshd_config). New-connection setups through the tailnet route take
  5–45s (all sandbox↔laptop traffic hairpins via the **NYC DERP relay**;
  tailscale ping times out while SSH data flows), so each setup holds a
  startup slot for seconds. Bursts >10 concurrent pre-auth setups (watch +
  launchers + coordinators overlapping) get sshd's literal early-drop bytes
  `Not allowed at this time` → client sees "Connection closed by UNKNOWN port
  65535", rc 255. Established sessions are NEVER dropped. MaxStartups drops
  are NOT logged at INFO — the journal shows only successful accepts, which
  is why it looked like random flakiness that "recovers on its own".
  Reproduced 2026-10-25: 14 parallel laptop-ssh.sh calls → 2 failed.
- INTERIM FIX APPLIED 2026-10-25: ~/tools/laptop-ssh.sh now uses SSH
  connection multiplexing (ControlMaster=auto, ControlPath
  ~/.ssh/cm-%r@%h:%p, ControlPersist=600 — 600 chosen to bridge the 10-min
  watch cadence). Verified: warm-master burst 14/14 OK (cold-start race can
  still drop a couple while several clients race to create the master).
- PERMANENT FIX (not yet applied): `services.openssh.settings.MaxStartups =
  "100:30:300"` in the laptop's NixOS config + switch — time the switch when
  no interactive laptop SSH is in use (sshd restart can take in-cgroup
  session processes; the OpenCode server on 40181 is independent of sshd).
