#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_tests.sh - all automated checks that need no copyrighted ROM.
# Runs: 6502 protocol unit tests (sim65), the disassembly round-trip self-test,
# the demo build, and the vpeer protocol self-test.  Exit 0 iff all pass.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
fail=0

step() { printf '\n=== %s ===\n' "$1"; }

step "6502 protocol unit tests (sim65)"
ca65 -t sim6502 -DUNIT_TEST -I src/common -I src/net src/net/netgame.s -o build/netgame_t.o
ca65 -t sim6502 -I src/common -I src/net src/net/ncio.s               -o build/ncio_t.o
ca65 -t sim6502 -I src/common -I src/net tests/test_netgame.s         -o build/test.o
ld65 -t sim6502 -o build/test.prg build/test.o build/netgame_t.o build/ncio_t.o sim6502.lib
if sim65 build/test.prg; then echo "PASS"; else echo "FAIL (check id $?)"; fail=1; fi

step "disassembly round-trip self-test"
bash tools/selftest_roundtrip.sh || fail=1

step "demo build (host + client)"
ca65 -t atari -I src/common -I src/net -I src/demo src/net/ncio.s     -o build/ncio.o
ca65 -t atari -I src/common -I src/net -I src/demo src/net/netgame.s  -o build/netgame.o
ca65 -t atari -I src/common -I src/net -I src/demo src/demo/netdemo.s -o build/netdemo.o
ld65 -C cfg/atari-xex.cfg -o build/netdemo.bin build/netdemo.o build/netgame.o build/ncio.o
python3 tools/xex.py build/netdemo.bin build/netdemo.xex 2000 >/dev/null && echo "PASS"

step "vpeer protocol self-test"
python3 tools/vpeer.py --selftest || fail=1

step "injected patch builds (netpatch + netgame + ncio)"
ca65 -t none -I src/common -I src/net -I src/game src/game/netpatch.s -o build/netpatch.o
ca65 -t none -I src/common -I src/net src/net/netgame.s -o build/ng_i.o
ca65 -t none -I src/common -I src/net src/net/ncio.s -o build/ncio_i.o
ld65 -C cfg/atari-inject.cfg -o build/netpatch.blob build/netpatch.o build/ng_i.o build/ncio_i.o \
  && echo "PASS ($(stat -c%s build/netpatch.blob) bytes)" || fail=1

printf '\n========================================\n'
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
