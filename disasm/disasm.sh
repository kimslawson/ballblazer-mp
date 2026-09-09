#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# disasm.sh - disassemble YOUR OWN Ballblazer cartridge into build/ballblazer.s
#
#   usage: disasm/disasm.sh [path-to-rom]
#          (default path: rom/ballblazer.rom)
#
# Strips a 16-byte "CART" header if the dump has one, sanity-checks the size,
# then runs da65 with disasm/ballblazer.info.  The ROM never leaves your
# machine and is never committed (see .gitignore).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

ROM="${1:-rom/ballblazer.rom}"
RAW="build/ballblazer.raw"
mkdir -p build

if [ ! -f "$ROM" ]; then
    echo "error: ROM not found at '$ROM'." >&2
    echo "Place your own legally-owned Ballblazer cart dump there, or pass a path." >&2
    echo "See rom/README.md." >&2
    exit 1
fi

# Detect and strip an Atari "CART" header (magic 'CART' = 43 41 52 54).
magic=$(head -c 4 "$ROM" | od -An -tx1 | tr -d ' \n')
if [ "$magic" = "43415254" ]; then
    echo "note: 'CART' header detected - stripping 16-byte header."
    tail -c +17 "$ROM" > "$RAW"
else
    cp "$ROM" "$RAW"
fi

size=$(stat -c%s "$RAW")
echo "raw image: $size bytes"
case "$size" in
    16384) echo "-> 16K cartridge, mapping \$8000-\$BFFF (matches ballblazer.info).";;
    8192)  echo "WARNING: 8K image. Edit ballblazer.info: STARTADDR \$A000 and";
           echo "         move the control-block ranges to \$BFFA (still top of window).";;
    *)     echo "WARNING: unexpected size $size. Adjust STARTADDR/ranges in ballblazer.info.";;
esac

echo "running da65 ..."
da65 -i disasm/ballblazer.info
echo "wrote build/ballblazer.s ($(wc -l < build/ballblazer.s) lines)"
echo "Next: read it, refine disasm/ballblazer.info, then run disasm/rebuild.sh."
