#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# selftest_roundtrip.sh - prove the disassembly workflow is byte-exact.
#
# Generates a synthetic 16K cartridge, runs it through the SAME da65 -> ca65 ->
# ld65 pipeline the real ROM will use, and asserts the rebuilt image is
# identical to the original.  No copyrighted ROM is involved, so this can run
# in CI and demonstrates the tooling is sound before you point disasm.sh at
# your own legally-owned Ballblazer cartridge.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
echo "[1/4] generate synthetic cartridge"
python3 tools/mkfakecart.py build/fakecart.rom >/dev/null

echo "[2/4] disassemble with da65"
da65 -i tests/fakecart.info >/dev/null

echo "[3/4] reassemble with ca65 + ld65"
ca65 -t none build/fakecart.s -o build/fakecart.o
ld65 -C disasm/cart16k.cfg -o build/fakecart.rebuilt build/fakecart.o

echo "[4/4] compare"
if cmp -s build/fakecart.rom build/fakecart.rebuilt; then
    echo "PASS: rebuilt image is byte-identical to the original ($(stat -c%s build/fakecart.rom) bytes)"
    exit 0
else
    echo "FAIL: images differ:"
    cmp build/fakecart.rom build/fakecart.rebuilt || true
    exit 1
fi
