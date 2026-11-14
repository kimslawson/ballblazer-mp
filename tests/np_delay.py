#!/usr/bin/env python3
"""np_delay - how much input delay does the turn-taking link need?

No emulator, no game image: two protocol endpoints (tools/npproto.py, the
reference for resident.s) on a simulated line with a fixed latency, each
running one tick per frame whenever the other side's input for that tick has
arrived - exactly what the tick gate does.

Checks the rule the lobby relies on (npproto.delay_for):

    stall-free play needs   delay >= 1.5 * round trip
    below that the game runs at about   2/3 * delay / round trip

and prints the table, which is also the quickest way to see what a given
link will feel like.
"""
import heapq
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "tools"))
import npproto as P  # noqa: E402

FRAMES, WARMUP = 3000, 300


def stalled(rt, delay):
    """Share of frames (%) in which the host / the client had to wait."""
    eps = [P.Endpoint(True, delay), P.Endpoint(False, delay)]
    tick, stalls = [0, 0], [0, 0]
    line, n = [], 0                    # (arrival time, serial, to whom, packet)

    def send(t, to, p):
        nonlocal n
        heapq.heappush(line, (t + rt / 2, n, to, p))
        n += 1

    send(0, 1, eps[0].kick())
    for f in range(FRAMES):
        for i in (0, 1):
            now = f + 0.37 * i         # the two machines are not in phase
            while line and line[0][0] <= now and line[0][2] == i:
                at, _, _, p = heapq.heappop(line)
                answer = eps[i].on_packet(p)
                if answer:
                    send(at, 1 - i, answer)
            e = eps[i]
            if len(e.remote) <= tick[i]:
                stalls[i] += f >= WARMUP
                continue
            e.push(P.code("U" if (tick[i] // 7) % 2 else "UL"))
            tick[i] += 1
    return [100.0 * s / (FRAMES - WARMUP) for s in stalls]


def main():
    ok = True
    print("round trip   stalled % of the time at input delay ...")
    print("  (frames)   " + " ".join("%3d" % d for d in range(3, 21)))
    for rt in range(2, 13):
        row = [max(stalled(rt, d)) for d in range(3, 21)]
        chosen = P.delay_for(rt)
        print("     %2d      %s   lobby picks %d"
              % (rt, " ".join("%3.0f" % v for v in row), chosen))
        need = -(-3 * rt // 2)                         # ceil(1.5 * rt)
        for d, v in zip(range(3, 21), row):
            if d >= need and v > 0:
                print("FAIL: round trip %d, delay %d stalls" % (rt, d))
                ok = False
            if d < need - 1 and v == 0:
                print("FAIL: round trip %d, delay %d does not stall - the "
                      "rule is too pessimistic" % (rt, d))
                ok = False
            if d < need - 1:                          # speed = 2/3 * d / rt
                want = 100 - 100 * 2 * d / (3 * rt)
                if abs(v - want) > 6:
                    print("FAIL: round trip %d, delay %d: stalled %.0f%%, "
                          "expected about %.0f%%" % (rt, d, v, want))
                    ok = False
        if max(stalled(rt, chosen)) > 0 and chosen < P.DELAY_MAX:
            print("FAIL: the lobby's choice for round trip %d stalls" % rt)
            ok = False
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
