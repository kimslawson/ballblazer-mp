#!/usr/bin/env python3
"""atr - inspect / unpack an Atari .atr disk image.

Emits only structural facts (sector geometry, boot record fields) and extracts
raw bytes for a disassembly workflow you run on your own legally-owned image.
It prints no game code.  Used for the DISK version of Ballblazer, whose boot
loader + segments replace the cartridge model in disasm/.

ATR header (16 bytes):
    0-1   magic $0296 (little-endian)          -> 96 02
    2-3   image size in 16-byte paragraphs (low word)
    4-5   sector size (128 or 256)
    6     paragraph count high byte
    7-15  reserved / flags

Boot record (sector 1, the first sector the OS loads):
    0     boot flag (usually 0)
    1     number of boot sectors to load
    2-3   load address (little-endian)
    4-5   init address (run after each load pass; RTS-terminated)
    6..   boot code; execution starts at load_addr+6

Usage:
    atr.py info   <img.atr>
    atr.py unpack <img.atr> <out_dir>   # writes sectors.img + boot.bin (+ notes)
"""
import struct
import sys
import os

HEADER = 16


def read(path):
    with open(path, "rb") as f:
        return f.read()


def parse_header(b):
    magic, plo, ssize, phi = struct.unpack_from("<HHHB", b, 0)
    if magic != 0x0296:
        raise SystemExit(f"not an ATR (magic ${magic:04X}, expected $0296)")
    paragraphs = plo | (phi << 16)
    return {"magic": magic, "sector_size": ssize,
            "claimed_bytes": paragraphs * 16}


def sector_offset(n, ssize):
    """Byte offset of sector n (1-based). The first 3 sectors are always 128
    bytes even on a 256-byte-sector disk (Atari boot convention)."""
    if ssize == 256:
        if n <= 3:
            return HEADER + (n - 1) * 128
        return HEADER + 3 * 128 + (n - 4) * 256
    return HEADER + (n - 1) * 128


def parse_boot(b, ssize):
    o = sector_offset(1, ssize)
    flag, nsec, load, init = struct.unpack_from("<BBHH", b, o)
    return {"flag": flag, "boot_sectors": nsec,
            "load_addr": load, "init_addr": init,
            "exec_addr": (load + 6) & 0xFFFF}


def cmd_info(path):
    b = read(path)
    h = parse_header(b)
    data = len(b) - HEADER
    ssize = h["sector_size"]
    per = 128 if ssize == 128 else None
    # count sectors present from actual file length
    if ssize == 128:
        nsec = data // 128
    else:
        # 3x128 then 256s
        nsec = 3 + max(0, (data - 3 * 128)) // 256
    boot = parse_boot(b, ssize)
    print(f"file            : {path}")
    print(f"file size       : {len(b)} bytes ({data} data + {HEADER} header)")
    print(f"sector size     : {ssize} bytes")
    print(f"sectors present : {nsec}")
    print(f"header claims   : {h['claimed_bytes']} data bytes"
          + ("  (matches)" if h['claimed_bytes'] == data
             else "  (note: differs from actual; using actual)"))
    print("boot record (sector 1):")
    print(f"  flag          : ${boot['flag']:02X}")
    print(f"  boot sectors  : {boot['boot_sectors']}")
    print(f"  load address  : ${boot['load_addr']:04X}")
    print(f"  init address  : ${boot['init_addr']:04X}")
    print(f"  first exec    : ${boot['exec_addr']:04X}  (load+6)")
    # DOS disk?  A DOS 2 disk has its boot flag/first bytes and a VTOC in
    # sector 360.  Custom game boots usually have flag 0 and no DOS signature.
    print("disk type       : custom boot (no DOS filesystem assumed)"
          if boot["flag"] == 0 else "disk type       : check for DOS")
    return b, h, boot, nsec


def cmd_unpack(path, out_dir):
    b, h, boot, nsec = cmd_info(path)
    ssize = h["sector_size"]
    os.makedirs(out_dir, exist_ok=True)

    # 1) full concatenated sector data (header stripped) - the raw disk body
    sectors = b[HEADER:]
    with open(os.path.join(out_dir, "sectors.img"), "wb") as f:
        f.write(sectors)

    # 2) the boot image: the first <boot_sectors> sectors' 128-byte payloads
    #    concatenated, i.e. the bytes the OS places starting at load_addr.
    n = boot["boot_sectors"]
    payload = bytearray()
    for s in range(1, n + 1):
        o = sector_offset(s, ssize)
        payload += b[o:o + 128]
    with open(os.path.join(out_dir, "boot.bin"), "wb") as f:
        f.write(payload)

    print()
    print(f"wrote {out_dir}/sectors.img ({len(sectors)} bytes)")
    print(f"wrote {out_dir}/boot.bin    ({len(payload)} bytes, "
          f"maps to ${boot['load_addr']:04X}-"
          f"${(boot['load_addr']+len(payload)-1)&0xFFFF:04X})")
    print("Next: disassemble boot.bin at its load address; follow the loader to")
    print("see how the remaining sectors are read in and where they land.")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "info":
        cmd_info(path)
    elif cmd == "unpack":
        if len(sys.argv) < 4:
            sys.exit("usage: atr.py unpack <img.atr> <out_dir>")
        cmd_unpack(path, sys.argv[3])
    else:
        sys.exit(f"unknown command '{cmd}'")


if __name__ == "__main__":
    main()
