#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rebuild.sh - reassemble build/ballblazer.s and verify it matches the ROM.
#
# A disassembly is "correct" when it reassembles to a byte-identical image.
# Until this prints IDENTICAL you have not fully understood the code/data
# split yet - keep refining disasm/ballblazer.info.  (The same pipeline is
# proven end-to-end on a synthetic cart by tools/selftest_roundtrip.sh.)
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

RAW="build/ballblazer.raw"
[ -f build/ballblazer.s ] || { echo "run disasm/disasm.sh first"; exit 1; }
[ -f "$RAW" ]             || { echo "missing $RAW; run disasm/disasm.sh first"; exit 1; }

ca65 -t none build/ballblazer.s -o build/ballblazer.o
ld65 -C disasm/cart16k.cfg -o build/ballblazer.rebuilt build/ballblazer.o

if cmp -s "$RAW" build/ballblazer.rebuilt; then
    echo "IDENTICAL: reassembled image matches the ROM ($(stat -c%s "$RAW") bytes)."
    echo "The disassembly is faithful; safe to start patching."
else
    echo "DIFFERENT - first mismatch:"
    cmp "$RAW" build/ballblazer.rebuilt || true
    echo "Refine disasm/ballblazer.info (mark data ranges, fix mis-decodes) and retry."
    exit 1
fi
