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

While the game runs vpeer prints, every two seconds: the tick it has reached
and how many ticks per second it managed (60 = full speed), how much of the
time it stood still waiting for the Atari's inputs, the round-trip time of the
link, and how often it had to resend. That is the place to look when play
stutters: the link takes turns, so smooth play needs an input delay of 1.5
round trips (npproto.delay_for); less means stop-and-go. Resends mean packets
are being lost.
"""
import argparse
import math
import random
import socket
import sys
import time

import npproto as P

TICK = 1 / 59.92          # NTSC frame
T_O = P.T_O_DEFAULT * TICK  # host retransmit timeout (as on the Atari)
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

    def recv():
        """One valid packet or None."""
        nonlocal peer
        try:
            data, src = sock.recvfrom(64)
        except socket.timeout:
            return None
        peer = src
        got = None
        for p in par.feed(data):
            got = p
        return got

    def ping(timeout=2.0):
        """Round-trip time in seconds, or None."""
        t = time.time()
        send(P.packet(P.T_PING, P.PING_BODY))
        while time.time() - t < timeout:
            p = recv()
            if p and p[0] & 7 == P.T_PING:
                return time.time() - t
        return None

    # ---- lobby ------------------------------------------------------------
    timeout = T_O
    last = 0.0
    welcomed = False
    while True:
        now = time.time()
        if not host and now - last > BEACON:
            send(P.packet(P.T_HELLO, bytes([P.VERSION, P.GAME_SUM & 255,
                                            P.GAME_SUM >> 8])))
            last = now
        got = recv()
        if got is None:
            continue
        kind = got[0] & 7
        if host and kind == P.T_HELLO:
            body = got[1:-1]
            if body[0] != P.VERSION or body[1] | body[2] << 8 != P.GAME_SUM:
                print("vpeer: the Atari runs a different version/image "
                      "(it says version %d)" % body[0])
                continue
            if not welcomed and delay is None:
                ping()                                  # one to settle
                trips = [ping() for _ in range(P.PINGS)]
                if None in trips:
                    delay = P.DELAY_DEFAULT
                    print("vpeer: could not time the link; delay %d" % delay)
                else:
                    worst = math.ceil(max(trips) / TICK)
                    delay = P.delay_for(worst)
                    timeout = P.timeout_for(worst) * TICK
                    print("vpeer: round trip %.0f ms (min %.0f, max %.0f = %d "
                          "frames) -> delay %d frames"
                          % (1000 * sum(trips) / len(trips),
                             1000 * min(trips), 1000 * max(trips), worst,
                             delay))
            send(P.packet(P.T_WELCOME, bytes([seed & 255 | 1, seed >> 8, delay])))
            welcomed = True
            print("vpeer: HELLO from %s - WELCOME sent (delay %d)" % (peer[0], delay))
        elif host and kind == P.T_START and welcomed:
            break
        elif not host and kind == P.T_PING:
            send(P.packet(P.T_PING, P.PING_BODY))       # the host is timing us
            last = time.time() + 1.5                    # ... keep quiet meanwhile
        elif not host and kind == P.T_WELCOME:
            delay = got[3]
            send(P.packet(P.T_START))
            print("vpeer: WELCOME from %s (delay %d) - START sent" % (peer[0], delay))
            break

    # ---- game -------------------------------------------------------------
    pl = Player(host, delay, wander(seed, press_start_at=600 if host else None))
    ep = pl.ep
    t0 = time.time()
    heard = 0.0 if host else time.time()
    beacon = time.time()
    shown = last_byte = sent_at = time.time()
    st = dict(rx=0, tx=0, resend=0, rtt=[], stall=0.0, tick0=0)
    while True:
        now = time.time()
        # our clock: never ahead of real time, never past the peer's inputs
        while pl.tick < (now - t0) / TICK:
            if not pl.advance():
                t0 += TICK          # stalled: this frame of wall time is lost
                st["stall"] += TICK
                break
        if host and now - heard > timeout:
            first = ep.tx is None
            send(ep.kick())
            st["tx"] += 1
            st["resend"] += not first
            heard = sent_at = now
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
                st["rx"] += 1
                before = ep.seq
                reply = ep.on_packet(p)
                if reply:
                    if ep.seq != before or not host:
                        # host: time from our packet to its answer;
                        # client: time between the host's packets
                        st["rtt"].append(now - sent_at)
                        sent_at = now
                    send(reply)
                    st["tx"] += 1
                    heard = now
        if now - shown > 2:
            r = st["rtt"]
            span = now - shown
            print("vpeer: tick %6d (%2.0f/s, stalled %2.0f%%)  %s %3.0f ms "
                  "(max %3.0f)  rx %d tx %d resent %d"
                  % (pl.tick, (pl.tick - st["tick0"]) / span,
                     100 * st["stall"] / span,
                     "round trip" if host else "host cycle",
                     1000 * sum(r) / len(r) if r else 0,
                     1000 * max(r) if r else 0,
                     st["rx"], st["tx"], st["resend"]))
            st.update(rtt=[], stall=0.0, tick0=pl.tick)
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
    ap.add_argument("--delay", type=int, default=None,
                    help="input delay in frames when hosting (3-20); "
                         "default: time the link and choose")
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
