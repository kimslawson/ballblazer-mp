#!/usr/bin/env python3
"""np_serial - exercise the REAL serial driver inside the running game.

The stock emulator has no FujiNet, but it does emulate POKEY's serial port at
the byte/interrupt level for the cassette. So a "tape" stands in for the remote
machine: a CAS image holding, at 2400 baud and with real-time gaps, exactly the
bytes a host would send - the handshake reply, then one input packet every
100 ms for a minute. The production resident code (interrupt-driven receive and
transmit, line turnaround, the IRQ re-enables inside the display kernels) has
to catch every byte while the game's display interrupts hog the CPU; the
emulator models POKEY's one-byte receive buffer, so a late interrupt shows up
as an overrun and a lost packet.

Pass = every packet accepted, no damaged bytes, and the game is in a match.

Needs rom/ballblazer.atr and the stock atari800.
"""
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import npproto as P  # noqa: E402
from rig import Rig  # noqa: E402
from nplink import labels  # noqa: E402

BAUD = 2400
DELAY = 4
PACKETS = 600            # one every 100 ms
TICKS_PER_PACKET = 5     # 50 ticks/s: just under what the game consumes


def chunk(kind, data=b"", aux=0):
    return kind + struct.pack("<HH", len(data), aux) + data


def make_tape(path):
    byte_ms = 10000.0 / BAUD
    t = chunk(b"FUJI", b"ballblazer netplay serial test") + chunk(b"baud", aux=BAUD)
    welcome = P.packet(P.T_WELCOME, bytes([0x35, 0x9C, DELAY]))
    t += chunk(b"data", welcome, 1500)
    t += chunk(b"data", welcome, 800)
    host = P.Endpoint(host=True, delay=DELAY)
    gap = 5000               # the client is busy starting the game
    total = 0
    for n in range(PACKETS):
        if 40 <= n < 42:
            c = P.code(key="start")
        elif n >= 60:
            c = P.code("U" if (n // 20) % 3 else "UL", trig=(n % 37 == 0))
        else:
            c = P.NEUTRAL
        for _ in range(TICKS_PER_PACKET):
            host.push(c)
        pkt = host.build()
        assert host.tx_cnt == TICKS_PER_PACKET
        total += host.tx_cnt
        host.l_base += host.tx_cnt      # a tape cannot wait for the answer
        host.seq ^= 0x80
        t += chunk(b"data", pkt, gap)
        gap = int(100 - len(pkt) * byte_ms)
    open(path, "wb").write(t)
    return total


def main():
    def sh(*a):
        subprocess.run(a, cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    os.makedirs(os.path.join(ROOT, "build/np"), exist_ok=True)
    for src, obj in (("resident", "res2"), ("lobby", "lob2")):
        sh("ca65", "-g", "-t", "none", "-D", "TEST=0", "-D", "NOFUJI=1", "-I",
           "src/netplay", "src/netplay/%s.s" % src, "-o", "build/np/%s.o" % obj)
    sh("ld65", "-C", "cfg/netplay.cfg", "-Ln", "build/np/np2.lbl", "-o",
       "build/np/np2", "build/np/res2.o", "build/np/lob2.o")
    sh(sys.executable, "tools/mkdisk.py", "rom/ballblazer.atr", "build/np/np2",
       "build/np/serial-client.atr", "--role", "client")
    L = labels(os.path.join(ROOT, "build/np/np2.lbl"))
    cas = os.path.join(ROOT, "build/np/serial-host.cas")
    total = make_tape(cas)

    with Rig(os.path.join(ROOT, "build/np/serial-client.atr"),
             extra=["-nopatch", "-tape", cas, "-tape-readonly"]) as r:
        # boot (real SIO timing now), lobby, handshake, game start, 60 s of tape
        frames = 0
        st = {}
        for _ in range(60):
            r.step(160)
            frames += 160
            m = r.dump(0x0180, 0x01BF)
            st = {n: m[L[n] - 0x180] for n in
                  ("tick", "r_wr", "l_wr", "l_base", "got_data", "err_cnt",
                   "net_mode", "tx_busy")}
            print("frame %5d  %s" % (frames, st), flush=True)
            if frames > 3000 and st["r_wr"] == (DELAY + total) & 0xFF \
                    and st["tick"] == st["r_wr"]:
                break
        r.shot(os.path.join(ROOT, "build/shots/serial.png"))

    want = (DELAY + total) & 0xFF
    ok = (st["got_data"] == 1 and st["err_cnt"] == 0 and st["r_wr"] == want
          and st["tick"] == want)
    print("sent %d ticks in %d packets; client has r_wr=%d (want %d), tick=%d, "
          "damaged=%d" % (total, PACKETS, st["r_wr"], want, st["tick"],
                          st["err_cnt"]))
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
