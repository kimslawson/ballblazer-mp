#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rebuild.sh - reassemble a disassembly and verify it matches the source image.
#
# A disassembly is "correct" when it reassembles to byte-identical bytes.
# Handles both project shapes:
#   * DISK: rebuild build/disk/boot.s and compare to build/disk/boot.bin
#   * CART: rebuild build/ballblazer.s and compare to build/ballblazer.raw
# (The same pipeline is proven generically on a synthetic cart by
#  tools/selftest_roundtrip.sh.)
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f build/disk/boot.s ]; then
    echo "=== verifying DISK boot loader ==="
    ca65 -t none build/disk/boot.s -o build/disk/boot.o
    ld65 -C disasm/disk-boot.cfg -o build/disk/boot.rebuilt build/disk/boot.o
    if cmp -s build/disk/boot.bin build/disk/boot.rebuilt; then
        echo "IDENTICAL: boot loader matches ($(stat -c%s build/disk/boot.bin) bytes)."
        echo "The loader disassembly is faithful. Continue mapping the loaded"
        echo "segments (docs/03-disassembly.md, 'Disk version')."
    else
        echo "DIFFERENT - first mismatch:"; cmp build/disk/boot.bin build/disk/boot.rebuilt || true
        echo "Refine disasm/disk-boot.info and retry."; exit 1
    fi
elif [ -f build/ballblazer.s ]; then
    echo "=== verifying CART image ==="
    ca65 -t none build/ballblazer.s -o build/ballblazer.o
    ld65 -C disasm/cart16k.cfg -o build/ballblazer.rebuilt build/ballblazer.o
    if cmp -s build/ballblazer.raw build/ballblazer.rebuilt; then
        echo "IDENTICAL: reassembled image matches the ROM."
    else
        echo "DIFFERENT - first mismatch:"; cmp build/ballblazer.raw build/ballblazer.rebuilt || true
        echo "Refine disasm/ballblazer.info and retry."; exit 1
    fi
else
    echo "nothing to rebuild; run disasm/disasm.sh first"; exit 1
fi
