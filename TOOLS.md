# TOOLS.md - Local Notes

Short, durable notes that make external tools work reliably in this
particular setup: device nicknames, host aliases, preferred voices, and
environment-specific quirks. Skills describe how tools work in general; this
file holds only what is unique here. Leave it empty until there is something
worth recording.

## Sandbox network quirk (found 2026-11-22, #12488; corrected by Drewry 22:20 CST; mechanics verified 22:24–22:31 CST)

UDP from this sandbox is **permission-gated, not banned**. The gate is the
"Direct network protocols" screen (Settings → Permissions): Drewry set the
UDP row to Ask, and a **connected** UDP flow (`connect()` then send/recv)
raises a per-destination approval; Felix requested it 2026-11-22, Drewry
approved, and connected UDP then worked — verified with real DNS replies
from 8.8.8.8:53 and a loopback exchange. **Unconnected `sendto` is still
EPERM everywhere** (loopback and egress) — the sandbox profile denies that
form outright and no approval covers it. So: tools that use connected UDP
sockets work here after a one-time per-destination approval; tools that
send on unconnected sockets (the pattern PR #12865's id-worlds capability
probe checks, and the pattern quinn-style transports use) still cannot —
don't chase those failures as load or flakiness. Sandbox cargo works via
the direct rustup toolchain path (`~/.rustup/toolchains/1.99.0-…/bin`);
the `~/tools/bin` dispatcher shim can hang.
