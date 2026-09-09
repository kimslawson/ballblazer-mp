#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# disasm.sh - disassemble YOUR OWN Ballblazer image into build/*.s
#
#   usage: disasm/disasm.sh [path]
#          default: rom/ballblazer.atr if present, else rom/ballblazer.rom
#
# Auto-detects the image type:
#   * .atr / ATR magic  -> DISK version. Unpacks with tools/atr.py and
#                          disassembles the boot loader (build/disk/boot.s).
#   * 16384-byte raw     -> CART version. da65 with disasm/ballblazer.info.
#   * 16-byte CART header -> stripped, then treated as CART.
#
# The image never leaves your machine and is never committed (see .gitignore).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

# pick default
if [ $# -ge 1 ]; then ROM="$1";
elif [ -f rom/ballblazer.atr ]; then ROM="rom/ballblazer.atr";
else ROM="rom/ballblazer.rom"; fi

if [ ! -f "$ROM" ]; then
    echo "error: image not found at '$ROM'." >&2
    echo "Place your own legally-owned Ballblazer disk (.atr) or cart (.rom) in rom/." >&2
    echo "See rom/README.md." >&2
    exit 1
fi

magic=$(head -c 2 "$ROM" | od -An -tx1 | tr -d ' \n')

if [ "${ROM##*.}" = "atr" ] || [ "$magic" = "9602" ]; then
    echo "=== DISK image detected ==="
    python3 tools/atr.py unpack "$ROM" build/disk
    echo
    echo "disassembling boot loader ..."
    da65 -i disasm/disk-boot.info
    echo "wrote build/disk/boot.s ($(wc -l < build/disk/boot.s) lines)"
    echo
    echo "Next steps (docs/03-disassembly.md, 'Disk version'):"
    echo "  * read build/disk/boot.s; note where it SIO-loads the remaining"
    echo "    sectors and the JMP (RUNAD) handoff, then map those addresses in"
    echo "    disasm/disk-boot.info;"
    echo "  * to disassemble the whole resident game, boot the .atr in atari800,"
    echo "    let it load, and dump RAM (see the doc)."
    echo "  * verify the boot disassembly with disasm/rebuild.sh."
    exit 0
fi

# ---- CART path ----
RAW="build/ballblazer.raw"
cartmagic=$(head -c 4 "$ROM" | od -An -tx1 | tr -d ' \n')
if [ "$cartmagic" = "43415254" ]; then
    echo "note: 'CART' header detected - stripping 16-byte header."
    tail -c +17 "$ROM" > "$RAW"
else
    cp "$ROM" "$RAW"
fi
size=$(stat -c%s "$RAW")
echo "=== CART image: $size bytes ==="
case "$size" in
    16384) echo "-> 16K cartridge, \$8000-\$BFFF (matches ballblazer.info).";;
    8192)  echo "WARNING: 8K image. Edit ballblazer.info: STARTADDR \$A000.";;
    *)     echo "WARNING: unexpected size. Adjust ballblazer.info.";;
esac
da65 -i disasm/ballblazer.info
echo "wrote build/ballblazer.s ($(wc -l < build/ballblazer.s) lines)"
echo "Next: refine disasm/ballblazer.info, then run disasm/rebuild.sh."
