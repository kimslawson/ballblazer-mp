#!/usr/bin/env python3
"""Generate a deterministic synthetic 16K Atari cartridge image.

Used only by the disassembly self-test: it lets tools/selftest_roundtrip.sh
prove the disassemble->reassemble->diff pipeline is byte-exact WITHOUT using any
copyrighted ROM.  Layout mirrors a real 16K cart ($8000-$BFFF):

    $8000-$800F  a short block of valid 6502 code (exercises code disassembly)
    $8010-$BFF9  filler pattern (byte value = low byte of its address)
    $BFFA-$BFFF  cartridge control block:
                   $BFFA/B run address  = $8000
                   $BFFC    present flag = $00
                   $BFFD    option byte  = $04 (init cart)
                   $BFFE/F init address  = $8000
"""
import sys

BASE = 0x8000
SIZE = 0x4000  # 16K

# Hand-chosen valid instructions, exactly 16 bytes, at $8000:
#   LDA #$00 / STA $D01F / LDX #$FF / TXS / JSR $8020 / JMP $8000 / NOP / NOP
CODE = bytes([
    0xA9, 0x00,             # LDA #$00
    0x8D, 0x1F, 0xD0,       # STA $D01F
    0xA2, 0xFF,             # LDX #$FF
    0x9A,                   # TXS
    0x20, 0x20, 0x80,       # JSR $8020
    0x4C, 0x00, 0x80,       # JMP $8000
    0xEA, 0xEA,             # NOP NOP
])
assert len(CODE) == 0x10


def build():
    img = bytearray(SIZE)
    img[0:len(CODE)] = CODE
    for off in range(len(CODE), SIZE):
        addr = BASE + off
        img[off] = addr & 0xFF
    # control block at $BFFA-$BFFF (offset SIZE-6)
    cb = SIZE - 6
    img[cb + 0] = 0x00        # run lo
    img[cb + 1] = 0x80        # run hi  -> $8000
    img[cb + 2] = 0x00        # present
    img[cb + 3] = 0x04        # options: init cart
    img[cb + 4] = 0x00        # init lo
    img[cb + 5] = 0x80        # init hi -> $8000
    return bytes(img)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "fakecart.rom"
    with open(out, "wb") as f:
        f.write(build())
    print(f"wrote {out}: {SIZE} bytes, base ${BASE:04X}")
