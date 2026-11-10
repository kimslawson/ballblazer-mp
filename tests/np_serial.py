#!/usr/bin/env python3
"""np_serial - exercise the REAL serial driver and the lobby inside the game.

The stock emulator has no FujiNet, but it does emulate POKEY's serial port at
the byte/interrupt level for the cassette. So a "tape" stands in for the remote
machine: a CAS image holding, at 2400 baud and with real-time gaps, exactly the
bytes the other side would send - its half of the handshake, then one input
packet every 100 ms for a minute. The production resident code (interrupt-
driven receive and transmit, line turnaround, the IRQ re-enables around the
display kernels) has to catch every byte while the game's display interrupts
hog the CPU; the emulator models POKEY's one-byte receive buffer, so a late
interrupt shows up as an overrun and a lost packet.

The lobby is driven through its real prompts with typed keys; only the two
FujiNet SIO commands are stubbed out (NOFUJI build).

    np_serial.py client     the tape plays the host   (default)
    np_serial.py host       the tape plays the client

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


def make_tape(path, tape_is_host):
    """The remote side's transmissions as a cassette image. Returns the number
    of ticks of input it carries."""
    byte_ms = 10000.0 / BAUD
    t = chunk(b"FUJI", b"ballblazer netplay serial test") + chunk(b"baud", aux=BAUD)
    if tape_is_host:
        welcome = P.packet(P.T_WELCOME, bytes([0x35, 0x9C, DELAY]))
        t += chunk(b"data", welcome, 1500)
        t += chunk(b"data", welcome, 800)
    else:
        hello = P.packet(P.T_HELLO, bytes([P.VERSION, P.GAME_SUM & 255,
                                           P.GAME_SUM >> 8]))
        t += chunk(b"data", hello, 1500)
        t += chunk(b"data", hello, 1500)
        t += chunk(b"data", P.packet(P.T_START), 1500)
        t += chunk(b"data", P.packet(P.T_START), 800)
    ep = P.Endpoint(host=tape_is_host, delay=DELAY)
    if not tape_is_host:
        ep.seq = 0x00            # a client echoes the host's seq: 0, 1, 0 ...
    gap = 6000                   # the Atari is busy starting the game
    total = 0
    for n in range(PACKETS):
        if 40 <= n < 42 and tape_is_host:
            c = P.code(key="start")
        elif n >= 60:
            c = P.code("U" if (n // 20) % 3 else "UL", trig=(n % 37 == 0))
        else:
            c = P.NEUTRAL
        for _ in range(TICKS_PER_PACKET):
            ep.push(c)
        pkt = ep.build()
        assert ep.tx_cnt == TICKS_PER_PACKET
        total += ep.tx_cnt
        ep.l_base += ep.tx_cnt   # a tape cannot wait for the other side
        ep.seq ^= 0x80
        t += chunk(b"data", pkt, gap)
        gap = int(100 - len(pkt) * byte_ms)
    open(path, "wb").write(t)
    return total


def main():
    role = sys.argv[1] if len(sys.argv) > 1 else "client"
    assert role in ("host", "client")

    def sh(*a):
        subprocess.run(a, cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    os.makedirs(os.path.join(ROOT, "build/np"), exist_ok=True)
    for src, obj in (("resident", "res2"), ("lobby", "lob2")):
        sh("ca65", "-g", "-t", "none", "-D", "TEST=0", "-D", "NOFUJI=1", "-I",
           "src/netplay", "src/netplay/%s.s" % src, "-o", "build/np/%s.o" % obj)
    sh("ld65", "-C", "cfg/netplay.cfg", "-Ln", "build/np/np2.lbl", "-o",
       "build/np/np2", "build/np/res2.o", "build/np/lob2.o")
    sh(sys.executable, "tools/mkdisk.py", "rom/ballblazer.atr", "build/np/np2",
       "build/np/serial.atr")
    L = labels(os.path.join(ROOT, "build/np/np2.lbl"))
    cas = os.path.join(ROOT, "build/np/serial-%s.cas" % role)
    total = make_tape(cas, tape_is_host=(role == "client"))

    with Rig(os.path.join(ROOT, "build/np/serial.atr"),
             extra=["-nopatch", "-tape", cas, "-tape-readonly"]) as r:
        r.step(1700)                       # boot at real disk speed
        r.type("10.0.0.2\n")               # opponent's address
        r.step(30)
        if role == "host":
            r.type("H\n")
            r.step(30)
            r.type("%d\n" % DELAY)         # input delay
        else:
            r.type("J\n")
        r.shot(os.path.join(ROOT, "build/shots/serial_lobby_%s.png" % role))
        # the START key belongs to the lobby until the game runs
        st = {}
        want = (DELAY + total) & 0xFF
        for n in range(60):
            if role == "host" and n == 8:
                r.step(8, start=True)      # the host starts the match
            r.step(160)
            m = r.dump(0x0180, 0x01BF)
            st = {k: m[L[k] - 0x180] for k in
                  ("tick", "r_wr", "l_wr", "l_base", "got_data", "err_cnt",
                   "net_mode", "tx_busy")}
            print("%s" % st, flush=True)
            if n > 20 and st["r_wr"] == want and st["tick"] == want:
                break
        r.shot(os.path.join(ROOT, "build/shots/serial_%s.png" % role))
        cfg = r.dump(0xBC00, 0xBC04)

    ok = (st["err_cnt"] == 0 and st["r_wr"] == want and st["tick"] == want
          and st["net_mode"] == 1 and cfg[1] == DELAY
          and cfg[0] == (0x00 if role == "host" else 0x80))
    print("role %s: the tape sent %d ticks in %d packets; this Atari has "
          "r_wr=%d (want %d), tick=%d, damaged=%d, delay=%d"
          % (role, total, PACKETS, st["r_wr"], want, st["tick"],
             st["err_cnt"], cfg[1]))
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
