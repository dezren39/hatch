# Shared model files

Canonical location for the qwen2.5-1.5b-instruct-q4_k_m.gguf path used
by local-model / route-rules test fixtures (churn forensics 2026-11-15,
reduction option 5).

FINDING (2026-11-15, verified three ways): the four 1,117,320,736-byte
"copies" that used to sit in ~/tmp/route-rules-* are NOT the model —
they are zero-filled placeholders of the model's exact size. Their
sha256, 8de2df505f2c46dd3b893364749702df7863e3183de4f386e868373848a157e9,
is exactly the sha256 of 1,117,320,736 zero bytes; the GGUF header is
zeros; du real usage is 0. The suites that created them evidently use
size-accurate stand-ins and never parse the file (the other six
fixtures are 29-byte text stand-ins saying so). There is no real model
file anywhere in the ~/tmp gguf population.

This directory holds ONE shared read-only copy of those placeholder
bytes; the four ~/tmp/route-rules-* paths are now symlinks to it, so
every fixture path serves byte-identical content to before while the
population is a single shared file. If a suite ever needs the REAL
model, download Qwen/Qwen2.5-1.5B-Instruct Q4_K_M from Hugging Face
into this directory under the same name (and update this note).
