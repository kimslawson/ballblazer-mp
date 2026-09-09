#!/usr/bin/env python3
"""vpeer - a virtual Ballblazer-MP opponent that speaks the wire protocol.

Lets you test ONE Atari + FujiNet against a PC (no second Atari needed).  It
receives the 16-byte state packets the Atari sends, validates them exactly like
netgame.s does, and replies with its own packets driving a "bot" rotofoil in a
slow circle so the remote craft visibly moves on the Atari's screen.

This file is also the executable spec of the packet format in fujinet.inc; keep
the two in sync.  `--selftest` runs offline checks (no socket) and is used by
tools/run_tests.sh / CI.

Examples:
    # Atari built as CLIENT dials this machine; we act as HOST (ball authority):
    tools/vpeer.py --listen 5000 --host

    # Atari built as HOST listens; we act as CLIENT dialing the Atari:
    tools/vpeer.py --connect 192.168.1.77:5000
"""
import argparse
import math
import socket
import sys
import time

PKT_LEN = 16
# byte offsets (mirror fujinet.inc)
MAGIC, SEQ, ACK, FLAGS = 0, 1, 2, 3
RFX, RFXF, RFY, RFYF = 4, 5, 6, 7
RFVX, RFVY, RFHDG = 8, 9, 10
BALLX, BALLY, BALLST, EVENT, CSUM = 11, 12, 13, 14, 15

PROTO_MAGIC = 0xB1
FLAG_HOST = 0x01
FLAG_HAVEBALL = 0x02


def checksum(buf):
    """XOR of bytes 0..14 - identical to ng_csum in netgame.s."""
    c = 0
    for i in range(CSUM):
        c ^= buf[i]
    return c & 0xFF


def build(seq, ack, flags, x, y, vx, vy, hdg, bx=0, by=0, bst=0, event=0):
    p = bytearray(PKT_LEN)
    p[MAGIC] = PROTO_MAGIC
    p[SEQ] = seq & 0xFF
    p[ACK] = ack & 0xFF
    p[FLAGS] = flags & 0xFF
    p[RFX] = x & 0xFF
    p[RFY] = y & 0xFF
    p[RFVX] = vx & 0xFF
    p[RFVY] = vy & 0xFF
    p[RFHDG] = hdg & 0xFF
    p[BALLX] = bx & 0xFF
    p[BALLY] = by & 0xFF
    p[BALLST] = bst & 0xFF
    p[EVENT] = event & 0xFF
    p[CSUM] = checksum(p)
    return bytes(p)


def parse(buf):
    if len(buf) < PKT_LEN:
        return None, "short"
    if buf[MAGIC] != PROTO_MAGIC:
        return None, "bad-magic"
    if checksum(buf) != buf[CSUM]:
        return None, "bad-checksum"
    return {
        "seq": buf[SEQ], "ack": buf[ACK], "flags": buf[FLAGS],
        "x": buf[RFX], "y": buf[RFY],
        "vx": u8_to_s8(buf[RFVX]), "vy": u8_to_s8(buf[RFVY]),
        "hdg": buf[RFHDG], "ballx": buf[BALLX], "bally": buf[BALLY],
        "ballst": buf[BALLST], "event": buf[EVENT],
    }, None


def u8_to_s8(b):
    return b - 256 if b >= 128 else b


def selftest():
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("  ok  " if cond else " FAIL ") + msg)
        ok = ok and cond

    # checksum matches the documented 6502 algorithm on a known vector
    v = bytes([0xB1, 0x01, 0x00, 0x01, 0x11, 0x22, 0x33, 0x44,
               0x05, 0xFB, 0x40, 0, 0, 0, 0])
    expect = 0
    for b in v:
        expect ^= b
    check(checksum(v + bytes([0])) == expect, "checksum XOR of bytes 0..14")

    # build -> parse round-trips
    p = build(seq=5, ack=4, flags=FLAG_HOST, x=0x11, y=0x33,
              vx=5, vy=-5, hdg=0x40)
    d, err = parse(p)
    check(err is None, "valid packet accepted")
    check(d and d["x"] == 0x11 and d["y"] == 0x33, "x/y parsed")
    check(d and d["vx"] == 5 and d["vy"] == -5, "signed velocity parsed")
    check(d and (d["flags"] & FLAG_HOST), "host flag parsed")

    # tampering is rejected
    bad = bytearray(p)
    bad[CSUM] ^= 0xFF
    _, err = parse(bytes(bad))
    check(err == "bad-checksum", "corrupt checksum rejected")
    bad = bytearray(p)
    bad[MAGIC] = 0x00
    _, err = parse(bytes(bad))
    check(err == "bad-magic", "bad magic rejected")

    print("SELFTEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def run(sock, peer, is_host, hz):
    print(f"vpeer up as {'HOST' if is_host else 'CLIENT'}; "
          f"peer={peer or 'first sender'}; {hz} Hz")
    period = 1.0 / hz
    seq = 0
    last_ack = 0
    cx, cy, r = 128.0, 128.0, 40.0     # bot flies a circle around grid centre
    theta = 0.0
    ballx, bally = 128, 128
    t_next = time.time()
    sock.settimeout(period)
    while True:
        # drain inbound
        try:
            while True:
                data, addr = sock.recvfrom(256)
                if peer is None:
                    peer = addr
                    print("peer discovered:", peer)
                d, err = parse(data)
                if err:
                    print("  rx drop:", err)
                    continue
                last_ack = d["seq"]
                print(f"  rx seq={d['seq']:3d} pos=({d['x']:3d},{d['y']:3d}) "
                      f"v=({d['vx']:+d},{d['vy']:+d}) hdg={d['hdg']:3d} "
                      f"flags={d['flags']:08b}")
        except socket.timeout:
            pass
        except BlockingIOError:
            pass

        # send our state on schedule
        now = time.time()
        if now >= t_next and peer is not None:
            t_next = now + period
            seq = (seq + 1) & 0xFF
            theta += 0.15
            x = int(cx + r * math.cos(theta)) & 0xFF
            y = int(cy + r * math.sin(theta)) & 0xFF
            vx = int(-r * math.sin(theta) * 0.15)
            vy = int(r * math.cos(theta) * 0.15)
            flags = FLAG_HOST | FLAG_HAVEBALL if is_host else 0
            pkt = build(seq, last_ack, flags, x, y, vx, vy,
                        int(theta * 40) & 0xFF, ballx, bally,
                        FLAG_HAVEBALL if is_host else 0)
            sock.sendto(pkt, peer)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--listen", metavar="PORT", type=int,
                   help="bind this UDP port and wait for the Atari to send")
    g.add_argument("--connect", metavar="IP:PORT",
                   help="send to this Atari address")
    ap.add_argument("--host", action="store_true",
                    help="act as the ball authority (set FLAG_HOST)")
    ap.add_argument("--hz", type=int, default=20, help="send rate (default 20)")
    ap.add_argument("--selftest", action="store_true",
                    help="run offline protocol checks and exit")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest())

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    peer = None
    if args.listen:
        sock.bind(("0.0.0.0", args.listen))
    elif args.connect:
        ip, port = args.connect.split(":")
        peer = (ip, int(port))
        sock.bind(("0.0.0.0", 0))
    else:
        ap.error("one of --listen or --connect is required (or --selftest)")

    try:
        run(sock, peer, args.host, args.hz)
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
