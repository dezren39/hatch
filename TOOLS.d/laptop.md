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

- 2026-10-25: laptop-ssh.sh eats piped stdin (its Python source arrives via heredoc) — sudo -S through the helper gets EOF ("no password was provided"). For stdin-carrying SSH (sudo -S, password feeds), build a direct ssh call with the same socat ProxyCommand (proxy creds from HTTPS_PROXY env) instead of the helper.

## Host-key + credential-in-argv FIXED 2026-10-26 (cf. code issue #948)
- laptop-ssh.sh rewritten: ProxyCommand is now ~/tools/laptop-proxy-connect.py,
  a Python HTTP CONNECT relay that reads the proxy credential from the
  HTTPS_PROXY env and sends it only inside the CONNECT request — the
  credential appears in NO process argv (the old socat line embedded
  proxyauth= in the argv of both ssh and socat).
- Host key verification ON: laptop ed25519 key (captured from the host
  itself via ssh-keyscan over the established channel) pinned in
  ~/.ssh/known_hosts_laptop; StrictHostKeyChecking=yes. Negative test
  (bogus key) verified rejected.
- Side benefit: no more Python heredoc — stdin passes through to ssh, so
  the sudo -S / password-feed workaround is obsolete.
- Old version kept at ~/tools/laptop-ssh.sh.bak-2026-10-26.
- Verified 2026-10-26: fresh strict connection OK, helper OK, stdin OK.
