#!/usr/bin/env python3
"""Wrap a flat binary blob into a bootable Atari 8-bit executable (.xex).

Atari binary-load (.xex / DOS "COM"/"EXE") format:
    $FF $FF                      magic (once, at the very start)
    <start_lo> <start_hi>        first address of a segment
    <end_lo>   <end_hi>          last address of that segment (inclusive)
    <data ...>                   (end-start+1) bytes
    ... more segments ...

Loading a value into RUNAD ($02E0/$02E1) tells the OS where to jump once the
whole file is loaded.  We emit two segments: the program image, then a 2-byte
segment that writes the run address into $02E0.

Usage: xex.py <infile.bin> <outfile.xex> <load_addr_hex> [run_addr_hex]
       (run address defaults to the load address)
"""
import sys


def seg(start, data):
    end = start + len(data) - 1
    return bytes([start & 0xFF, (start >> 8) & 0xFF,
                  end & 0xFF, (end >> 8) & 0xFF]) + data


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    infile, outfile = sys.argv[1], sys.argv[2]
    load = int(sys.argv[3], 16)
    run = int(sys.argv[4], 16) if len(sys.argv) > 4 else load

    with open(infile, "rb") as f:
        image = f.read()
    if not image:
        sys.exit("error: input image is empty")

    out = bytearray(b"\xff\xff")
    out += seg(load, image)
    # RUNAD ($02E0): the OS jumps here after load completes.
    out += seg(0x02E0, bytes([run & 0xFF, (run >> 8) & 0xFF]))

    with open(outfile, "wb") as f:
        f.write(out)
    print(f"{outfile}: load ${load:04X}..${load+len(image)-1:04X} "
          f"({len(image)} bytes), run ${run:04X}, total {len(out)} bytes")


if __name__ == "__main__":
    main()
