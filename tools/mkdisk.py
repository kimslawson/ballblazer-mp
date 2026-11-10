#!/usr/bin/env python3
"""mkdisk - build the netplay disk from YOUR Ballblazer disk image.

The supported image ("Regulation Certified", 35,344-byte .atr) is a tiny boot
loader followed by one ordinary Atari binary-load stream. This tool leaves the
game bytes exactly as they are and appends two segments of our own code
(build/np/*.resident at $BC00, *.lobby at $2000) plus a new run address, so
the lobby runs first. Nothing from the game is stored in this repository; the
output contains your game and must stay on your machine like the original.

    mkdisk.py rom/ballblazer.atr build/np/np0 build/ballblazer-net.atr
    mkdisk.py ... --xex out.xex          also write the stream as a .xex
    mkdisk.py ... --role host --delay 4 --seed 1234   (test builds: preset cfg)
"""
import argparse
import hashlib
import sys

SUPPORTED_MD5 = "a37afb54b6edbd03c348efa0b714d37c"
SECTOR = 128
BOOT_SECTORS = 3
RESIDENT_ADDR = 0xBC00
LOBBY_ADDR = 0x2000
# offsets of the configuration bytes at the start of the resident image
CFG_ROLE, CFG_DELAY, CFG_BAUD, CFG_RND0, CFG_RND1 = range(5)


def parse_stream(x):
    """Split a binary-load stream into [(start, data)] segments."""
    segs, i = [], 0
    while i < len(x):
        if x[i] == 0xFF and x[i + 1] == 0xFF:
            i += 2
        s = x[i] | x[i + 1] << 8
        e = x[i + 2] | x[i + 3] << 8
        i += 4
        segs.append((s, x[i:i + e - s + 1]))
        i += e - s + 1
    return segs


def emit_stream(segs):
    out = bytearray(b"\xff\xff")
    for s, d in segs:
        e = s + len(d) - 1
        out += bytes([s & 255, s >> 8, e & 255, e >> 8]) + d
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("atr")
    ap.add_argument("code", help="ld65 output prefix (…/np0 or …/np1)")
    ap.add_argument("out")
    ap.add_argument("--xex")
    ap.add_argument("--role", choices=["host", "client"])
    ap.add_argument("--delay", type=int)
    ap.add_argument("--seed", type=lambda v: int(v, 0))
    ap.add_argument("--force", action="store_true",
                    help="accept an image with a different checksum")
    a = ap.parse_args()

    raw = open(a.atr, "rb").read()
    md5 = hashlib.md5(raw).hexdigest()
    if md5 != SUPPORTED_MD5 and not a.force:
        sys.exit("mkdisk: %s is not the supported image (md5 %s).\n"
                 "The patch addresses are specific to that dump; refusing.\n"
                 "(--force to try anyway)" % (a.atr, md5))
    if raw[0:2] != b"\x96\x02":
        sys.exit("mkdisk: not an ATR image")
    body = bytearray(raw[16:])
    boot = body[:BOOT_SECTORS * SECTOR]
    n = boot[9] | boot[10] << 8 | boot[11] << 16      # stream length
    stream = bytes(body[BOOT_SECTORS * SECTOR:BOOT_SECTORS * SECTOR + n])
    segs = parse_stream(stream)
    if segs[-1][0] != 0x02E0 or len(segs[-1][1]) != 2:
        sys.exit("mkdisk: unexpected stream layout (no final run address)")
    run = segs[-1][1][0] | segs[-1][1][1] << 8

    res = bytearray(open(a.code + ".resident", "rb").read())
    lob = open(a.code + ".lobby", "rb").read()
    if len(res) > 0x400:
        sys.exit("mkdisk: resident image too large")
    if a.role:
        res[CFG_ROLE] = 0x00 if a.role == "host" else 0x80
    if a.delay is not None:
        res[CFG_DELAY] = a.delay
    if a.seed is not None:
        res[CFG_RND0] = (a.seed & 0xFF) | 1
        res[CFG_RND1] = a.seed >> 8 & 0xFF

    new = segs[:-1] + [(RESIDENT_ADDR, bytes(res)), (LOBBY_ADDR, lob),
                       (0x02E0, bytes([LOBBY_ADDR & 255, LOBBY_ADDR >> 8]))]
    out_stream = emit_stream(new)
    if a.xex:
        open(a.xex, "wb").write(out_stream)

    m = len(out_stream)
    boot[9], boot[10], boot[11] = m & 255, m >> 8 & 255, m >> 16 & 255
    data = bytes(boot) + out_stream
    data += b"\0" * (-len(data) % SECTOR)
    data += b"\0" * max(0, 720 * SECTOR - len(data))    # a full SD floppy
    paras = len(data) // 16
    hdr = bytes([0x96, 0x02, paras & 255, paras >> 8 & 255,
                 SECTOR & 255, SECTOR >> 8, paras >> 16 & 255]) + b"\0" * 9
    open(a.out, "wb").write(hdr + data)
    print("mkdisk: game run address $%04X kept as the lobby's exit; "
          "stream %d -> %d bytes; wrote %s (%d sectors)"
          % (run, n, m, a.out, len(data) // SECTOR))


if __name__ == "__main__":
    main()
