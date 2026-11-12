#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_tests.sh - every automated check that needs NO game image.
#   * the netplay code assembles in all three build variants and fits
#   * the Python reference of the link protocol agrees with itself under loss
#     and with the byte patterns the 6502 code produces
#   * the disk builder refuses an image it does not know
#   * the disassembly pipeline round-trips a synthetic image byte-exactly
# The emulator tests (lockstep soak, serial driver) need your own disk image:
# see `make nptest`.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/np
fail=0
step() { printf '\n=== %s ===\n' "$1"; }

step "netplay code assembles (production / link-test / serial-test builds)"
n=0
for flags in "-D TEST=0" "-D TEST=1" "-D TEST=0 -D NOFUJI=1"; do
    # shellcheck disable=SC2086
    if ca65 -g -t none $flags -I src/netplay src/netplay/resident.s -o build/np/res$n.o &&
       ca65 -g -t none $flags -I src/netplay src/netplay/lobby.s    -o build/np/lob$n.o &&
       ld65 -C cfg/netplay.cfg -Ln build/np/np$n.lbl -m build/np/np$n.map \
            -o build/np/np$n build/np/res$n.o build/np/lob$n.o; then
        echo "  np$n: resident $(wc -c < build/np/np$n.resident | tr -d ' ')/1024 bytes," \
             "lobby $(wc -c < build/np/np$n.lobby | tr -d ' ') bytes"
    else
        fail=1
    fi
    n=$((n+1))
done
[ "$fail" -eq 0 ] && echo "PASS"

step "link protocol reference (lossless + 30% loss, wire format)"
python3 tools/vpeer.py selftest || fail=1

step "disk builder rejects an unknown image"
head -c 4096 /dev/zero > build/np/not-the-game.atr
if python3 tools/mkdisk.py build/np/not-the-game.atr build/np/np0 build/np/x.atr \
        >/dev/null 2>&1; then
    echo "FAIL: accepted a bogus image"; fail=1
else
    echo "PASS"
fi

step "disassembly round-trip self-test"
bash tools/selftest_roundtrip.sh || fail=1

printf '\n========================================\n'
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
