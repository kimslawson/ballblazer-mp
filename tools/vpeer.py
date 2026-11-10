#!/usr/bin/env python3
"""vpeer - a PC stand-in for the second Atari.

Speaks the Ballblazer netplay protocol over UDP, the way a FujiNet in
NetStream mode relays it: every datagram is a run of raw serial bytes. Point
ONE real Atari + FujiNet at this computer's address and you can test the whole
link - lobby handshake, lockstep, loss recovery - before a second Atari is
involved. The PC "player" cannot see the game; it just wanders about and
shoots now and then, which is enough to see the opponent's rotofoil move and
the match stay alive.

    vpeer.py join <atari-ip>      Atari hosts (answer H there); PC is player 2
    vpeer.py host                 Atari joins (answer J there); PC is player 1
    vpeer.py selftest             no network: two endpoints over a lossy pipe

On the Atari, enter this computer's IP address as the opponent's address.
Both ends use UDP port 6502.
"""
import argparse
import random
import socket
import sys
import time

import npproto as P

TICK = 1 / 59.92          # NTSC frame
T_O = 8 * TICK            # host retransmit timeout (as on the Atari)
BEACON = 32 * TICK        # client START / HELLO repeat


class Player:
    """Lockstep bookkeeping for one side: mirrors the Atari's tick hook."""

    def __init__(self, host, delay, pilot):
        self.ep = P.Endpoint(host, delay)
        self.tick = 0
        self.pilot = pilot

    def advance(self):
        """Run every tick whose remote input has arrived; queue ours."""
        n = 0
        while self.tick < len(self.ep.remote) and \
                len(self.ep.local) - self.ep.l_base < 56:
            self.ep.push(self.pilot(self.tick + self.ep.delay))
            self.tick += 1
            n += 1
        return n


def wander(seed, press_start_at=None):
    """A blind pilot: mostly forward, some turns, the odd shot."""
    rnd = random.Random(seed)
    state = {"c": P.NEUTRAL, "until": 0}

    def pilot(t):
        if press_start_at is not None and press_start_at <= t < press_start_at + 8:
            return P.code(key="start")
        if t >= state["until"]:
            state["c"] = P.code(rnd.choice(["U", "U", "U", "UL", "UR", "L", "R", ""]),
                                trig=rnd.random() < 0.15)
            state["until"] = t + rnd.randint(10, 60)
        return state["c"]
    return pilot


def run(args):
    host = args.mode == "host"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", args.port))
    sock.settimeout(0.002)
    peer = (args.atari, args.port) if args.atari else None
    par = P.Parser()
    delay = args.delay
    seed = random.randrange(1, 65536)
    print("vpeer: %s on UDP %d%s" % (
        "hosting (PC = player 1)" if host else "joining (PC = player 2)",
        args.port, "" if peer else ", waiting for the Atari to call"))

    def send(pkt):
        if peer:
            sock.sendto(pkt, peer)

    # ---- lobby ------------------------------------------------------------
    last = 0.0
    welcomed = False
    while True:
        now = time.time()
        if not host and now - last > BEACON:
            send(P.packet(P.T_HELLO, bytes([P.VERSION, P.GAME_SUM & 255,
                                            P.GAME_SUM >> 8])))
            last = now
        try:
            data, src = sock.recvfrom(64)
        except socket.timeout:
            continue
        peer = src
        got = None
        for p in par.feed(data):
            got = p
        if got is None:
            continue
        kind = got[0] & 7
        if host and kind == P.T_HELLO:
            body = got[1:-1]
            if body[0] != P.VERSION or body[1] | body[2] << 8 != P.GAME_SUM:
                print("vpeer: the Atari runs a different version/image")
                continue
            send(P.packet(P.T_WELCOME, bytes([seed & 255 | 1, seed >> 8, delay])))
            welcomed = True
            print("vpeer: HELLO from %s - WELCOME sent (delay %d)" % (src[0], delay))
        elif host and kind == P.T_START and welcomed:
            break
        elif not host and kind == P.T_WELCOME:
            delay = got[3]
            send(P.packet(P.T_START))
            print("vpeer: WELCOME from %s (delay %d) - START sent" % (src[0], delay))
            break

    # ---- game -------------------------------------------------------------
    pl = Player(host, delay, wander(seed, press_start_at=600 if host else None))
    ep = pl.ep
    t0 = time.time()
    heard = 0.0 if host else time.time()
    beacon = time.time()
    stats = dict(rx=0, tx=0, resend=0)
    shown = time.time()
    last_byte = time.time()
    while True:
        now = time.time()
        # our clock: never run ahead of real time, never past the peer's inputs
        while pl.tick < (now - t0) / TICK:
            if not pl.advance():
                t0 += TICK          # stalled: wall time does not count
                break
        if host and now - heard > T_O:
            send(ep.kick())
            stats["tx"] += 1
            stats["resend"] += ep.tx is not None and heard > 0
            heard = now
        if not host and not ep.got_data and now - beacon > BEACON:
            send(P.packet(P.T_START))
            beacon = now
        try:
            data, src = sock.recvfrom(64)
        except socket.timeout:
            data = b""
        if data:
            if now - last_byte > 0.035:
                par.idle()
            last_byte = now
            for p in par.feed(data):
                stats["rx"] += 1
                reply = ep.on_packet(p)
                if reply:
                    send(reply)
                    stats["tx"] += 1
                    heard = now
        if now - shown > 2:
            print("vpeer: tick %6d  peer inputs to %6d  rx %d tx %d resent %d"
                  % (pl.tick, len(ep.remote), stats["rx"], stats["tx"],
                     stats["resend"]))
            shown = now


def selftest():
    """Two endpoints over a lossy, reordering-free pipe: each side must end up
    with exactly the other's inputs, in order."""
    rnd = random.Random(1)
    for loss in (0.0, 0.3):
        h = Player(True, 4, wander(11))
        c = Player(False, 4, wander(22))
        ph, pc = P.Parser(), P.Parser()
        wire_hc, wire_ch = [], []
        quiet = 99
        for step in range(40000):
            h.advance()
            c.advance()
            if wire_hc:
                for p in pc.feed(wire_hc.pop(0)):
                    r = c.ep.on_packet(p)
                    if r and rnd.random() >= loss:
                        wire_ch.append(r)
            elif wire_ch:
                for p in ph.feed(wire_ch.pop(0)):
                    r = h.ep.on_packet(p)
                    quiet = 0
                    if r and rnd.random() >= loss:
                        wire_hc.append(r)
            else:
                quiet += 1
                if quiet > 8:                      # host timeout
                    quiet = 0
                    if rnd.random() >= loss:
                        wire_hc.append(h.ep.kick())
            if h.tick > 3000 and c.tick > 3000:
                break
        n = min(len(h.ep.remote), len(c.ep.local), 3000)
        m = min(len(c.ep.remote), len(h.ep.local), 3000)
        ok = (h.ep.remote[:n] == c.ep.local[:n] and
              c.ep.remote[:m] == h.ep.local[:m] and n > 2900 and m > 2900)
        print("selftest loss %.0f%%: host has %d of client's inputs, client has "
              "%d of host's - %s" % (loss * 100, n, m, "PASS" if ok else "FAIL"))
        if not ok:
            return 1
    # wire format spot checks (must match src/netplay/resident.s)
    assert P.packet(P.T_DATA, bytes([0x8F])) == bytes([0x08, 0x8F, 0x0C])
    assert P.packet(0x80 | P.T_DATA, bytes([0x8F])) == bytes([0x88, 0x8F, 0x0E])
    assert P.unrle(P.rle([15] * 5 + [14] * 9)[0]) == [15] * 5 + [14] * 9
    print("wire format: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("mode", choices=["host", "join", "selftest"])
    ap.add_argument("atari", nargs="?", help="the Atari's FujiNet address (join)")
    ap.add_argument("--port", type=int, default=P.PORT)
    ap.add_argument("--delay", type=int, default=5,
                    help="input delay in frames when hosting (3-9)")
    args = ap.parse_args()
    if args.mode == "selftest":
        sys.exit(selftest())
    if args.mode == "join" and not args.atari:
        ap.error("join needs the Atari's address")
    try:
        run(args)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
