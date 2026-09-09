#!/usr/bin/env bash
# SessionStart hook: make sure the 6502 toolchain is present so `make test`
# works in a fresh Claude-on-web container. Idempotent and best-effort:
# it never fails the session if packages can't be fetched.
set -u
need=""
for t in ca65 ld65 da65 sim65 dasm; do
    command -v "$t" >/dev/null 2>&1 || need="$t $need"
done
if [ -n "$need" ]; then
    echo "ballblazer-mp: installing 6502 toolchain (missing: $need) ..."
    if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=; fi
    $SUDO apt-get update -qq >/dev/null 2>&1 || true
    $SUDO apt-get install -y -qq cc65 dasm atari800 >/dev/null 2>&1 \
        && echo "ballblazer-mp: toolchain ready." \
        || echo "ballblazer-mp: could not auto-install; see docs/03-disassembly.md."
else
    echo "ballblazer-mp: 6502 toolchain present."
fi
exit 0
