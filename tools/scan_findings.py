#!/usr/bin/env python3
"""scan_findings - locate reverse-engineering seams in a RAM dump.

Input is a flat RAM image (base $0000) captured from atari800 (see
tools/dump_ram.sh).  Output is FACTS ONLY - the addresses of instructions that
reference known Atari I/O locations, a memory-occupancy map, and (optionally) a
diff of two dumps to reveal changing state variables.  It prints no game code,
so its output is safe to record in the tracked findings notes.

The heuristic: for each interesting target address T, find every absolute-mode
6502 opcode whose 2-byte operand == T.  That pinpoints where the game reads the
joysticks / triggers / PRNG / console keys - i.e. the input & AI seam.

Usage:
    scan_findings.py map   <dump.bin>
    scan_findings.py io    <dump.bin>
    scan_findings.py diff  <a.bin> <b.bin>
"""
import sys

BASE = 0x0000

# Absolute-addressing opcodes (operand is a 16-bit little-endian address).
ABS_OPS = {
    0xAD: "LDA", 0xBD: "LDA,X", 0xB9: "LDA,Y",
    0xAE: "LDX", 0xBE: "LDX,Y",
    0xAC: "LDY", 0xBC: "LDY,X",
    0x8D: "STA", 0x9D: "STA,X", 0x99: "STA,Y",
    0x2C: "BIT",
    0xCD: "CMP", 0xDD: "CMP,X", 0xD9: "CMP,Y",
    0x0D: "ORA", 0x2D: "AND", 0x4D: "EOR",
    0xEE: "INC", 0xCE: "DEC",
    0x6D: "ADC", 0xED: "SBC",
    0x4C: "JMP", 0x20: "JSR", 0x6C: "JMP()",
}

# Interesting targets: name -> address.  The input/AI seam reads these.
TARGETS = {
    "STICK0 (joy0 shadow)":   0x0278,
    "STICK1 (joy1 shadow)":   0x0279,
    "STRIG0 (trig0 shadow)":  0x0284,
    "STRIG1 (trig1 shadow)":  0x0285,
    "PORTA (raw joysticks)":  0xD300,
    "RANDOM (POKEY PRNG)":    0xD20A,
    "CONSOL (Start/Sel/Opt)": 0xD01F,
    "TRIG0 (GTIA)":           0xD010,
    "TRIG1 (GTIA)":           0xD011,
    "RTCLOK+2 (jiffy)":       0x0014,
}


def load(path):
    return open(path, "rb").read()


def cmd_map(path):
    data = load(path)
    print(f"# memory occupancy (base ${BASE:04X}, {len(data)} bytes)")
    for pg in range(0, len(data), 0x1000):
        chunk = data[pg:pg + 0x1000]
        nz = sum(1 for b in chunk if b)
        bar = "#" * (nz * 40 // 0x1000)
        print(f"  ${BASE+pg:04X}-${BASE+pg+0xFFF:04X}: {nz:4d}/4096 {bar}")


def cmd_io(path):
    data = load(path)
    print(f"# instructions referencing key I/O addresses in {path}")
    print("# (address = where the instruction lives; safe to record)")
    for name, tgt in TARGETS.items():
        lo, hi = tgt & 0xFF, (tgt >> 8) & 0xFF
        hits = []
        for i in range(len(data) - 2):
            op = data[i]
            if op in ABS_OPS and data[i + 1] == lo and data[i + 2] == hi:
                hits.append((BASE + i, ABS_OPS[op]))
        tag = f"${tgt:04X} {name}"
        if not hits:
            print(f"\n{tag}: (none)")
            continue
        print(f"\n{tag}: {len(hits)} reference(s)")
        for addr, mnem in hits:
            print(f"    ${addr:04X}  {mnem} ${tgt:04X}")


def cmd_diff(a, b):
    da, db = load(a), load(b)
    n = min(len(da), len(db))
    print(f"# bytes that differ between {a} and {b} (candidate live variables)")
    # focus on low RAM where game variables usually live
    runs = []
    i = 0
    while i < n:
        if da[i] != db[i]:
            j = i
            while j < n and da[j] != db[j]:
                j += 1
            runs.append((BASE + i, j - i))
            i = j
        else:
            i += 1
    zp = [r for r in runs if r[0] < 0x0100]
    lo = [r for r in runs if 0x0100 <= r[0] < 0x0600]
    print(f"total differing runs: {len(runs)}")
    print("zero-page changes (prime suspects for positions/velocities):")
    for addr, ln in zp:
        print(f"    ${addr:04X}  x{ln}")
    print("page 1-5 changes:")
    for addr, ln in lo[:60]:
        print(f"    ${addr:04X}  x{ln}")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "map":
        cmd_map(sys.argv[2])
    elif cmd == "io":
        cmd_io(sys.argv[2])
    elif cmd == "diff" and len(sys.argv) >= 4:
        cmd_diff(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
