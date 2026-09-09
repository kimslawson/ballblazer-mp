#!/usr/bin/env python3
"""netsim - simulate the Ballblazer-MP link and measure opponent display error.

Headless empirical companion to docs/06-latency.md. It models the *algorithm* in
src/net/netgame.s (NOT the literal 6502): each peer owns its rotofoil, samples it
at 60 fps, transmits (x, y, vx, vy) every SEND_EVERY=3 frames (~20 Hz), and the
receiver dead-reckons the mirror (pos += vel each frame) and snaps to truth when
a packet arrives. We then measure how far the *displayed* remote craft is from
its true position, under a range of one-way latencies and packet loss.

Key thing it demonstrates: with dead reckoning, steady motion is essentially
lag-free (the mirror extrapolates exactly); error appears only where the craft
*accelerates* (turns), and grows with latency + the send interval. So a gliding
Ballblazer rotofoil tolerates far more latency than a twitch game would.

Positions are in "grid units"; the rotofoil tops out near ~2.5 units/frame
(~150 units/s), and the playfield is a few hundred units across, so single-digit
errors are imperceptible and ~30+ would read as a visible correction.

Run: tools/netsim.py            (full sweep table)
     tools/netsim.py --csv      (machine-readable)
"""
import math
import random
import sys

FPS = 60
SEND_EVERY = 3                     # matches fujinet.inc SEND_EVERY (~20 Hz)
FRAME_MS = 1000.0 / FPS


def path_line_turns(n):
    """Straight glides with a hard 90-degree turn every 0.5 s (best/typical)."""
    vx = vy = 0.0
    xs = []
    x = y = 128.0
    seg = 0
    for f in range(n):
        if f % 30 == 0:                       # change direction sharply
            seg = (seg + 1) % 4
            vx, vy = [(2.4, 0), (0, 2.4), (-2.4, 0), (0, -2.4)][seg]
        x += vx; y += vy
        xs.append((x, y, vx, vy))
    return xs


def path_circle(n):
    """Continuous turning (worst case for dead reckoning: always accelerating)."""
    xs = []
    r, w = 60.0, 0.10                          # radius, angular vel (rad/frame)
    for f in range(n):
        a = w * f
        x = 128 + r * math.cos(a)
        y = 128 + r * math.sin(a)
        vx = -r * w * math.sin(a)              # exact per-frame velocity
        vy = r * w * math.cos(a)
        xs.append((x, y, vx, vy))
    return xs


def simulate(truth, one_way_ms, loss, seed=1):
    """Feed one peer's true path over the link; return per-frame display error
    of the receiver's dead-reckoned mirror vs the sender's true position."""
    rng = random.Random(seed)
    delay = max(0, round(one_way_ms / FRAME_MS))
    inflight = []                              # (arrival_frame, x, y, vx, vy)
    mx = my = mvx = mvy = 0.0
    have = False
    errs = []
    for f, (x, y, vx, vy) in enumerate(truth):
        # sender transmits a snapshot every SEND_EVERY frames
        if f % SEND_EVERY == 0:
            if not (loss and rng.random() < loss):
                inflight.append((f + delay, x, y, vx, vy))
        # deliver everything due this frame (snap mirror to authoritative state)
        due = [p for p in inflight if p[0] <= f]
        inflight = [p for p in inflight if p[0] > f]
        for _, px, py, pvx, pvy in due:
            mx, my, mvx, mvy = px, py, pvx, pvy
            have = True
        # dead reckon between packets (pos += vel), exactly like ng_deadreckon
        if have:
            mx += mvx; my += mvy
            errs.append(math.hypot(mx - x, my - y))
    return errs


def stats(errs):
    if not errs:
        return (0, 0, 0)
    s = sorted(errs)
    mean = sum(s) / len(s)
    p95 = s[min(len(s) - 1, int(0.95 * len(s)))]
    return (mean, p95, s[-1])


SCENARIOS = [("glide+turns", path_line_turns), ("continuous-turn", path_circle)]
LATENCIES = [8, 25, 50, 100, 150]              # one-way ms (LAN .. internet)


def main():
    csv = "--csv" in sys.argv
    frames = FPS * 20                          # 20 s runs
    if csv:
        print("scenario,one_way_ms,loss,mean_err,p95_err,max_err")
    else:
        print(f"Ballblazer-MP link simulation  ({frames//FPS}s runs, "
              f"{FPS}fps, send every {SEND_EVERY} frames = {FPS//SEND_EVERY}Hz)")
        print("error = grid units the opponent's craft is displayed off its true spot\n")
    for name, pathfn in SCENARIOS:
        truth = pathfn(frames)
        if not csv:
            print(f"  {name}:")
            print(f"    {'1-way ms':>8} {'loss':>5} {'mean':>7} {'p95':>7} {'max':>7}")
        for lat in LATENCIES:
            for loss in (0.0, 0.10 if lat >= 100 else None):
                if loss is None:
                    continue
                mean, p95, mx = stats(simulate(truth, lat, loss))
                if csv:
                    print(f"{name},{lat},{loss},{mean:.2f},{p95:.2f},{mx:.2f}")
                else:
                    tag = f"{lat:>8} {loss*100:>4.0f}% {mean:>7.1f} {p95:>7.1f} {mx:>7.1f}"
                    print("   " + tag)
        if not csv:
            print()
    if not csv:
        print("Reading it: 'glide+turns' ~ real play (long glides, occasional")
        print("hard turns); 'continuous-turn' is the pathological always-accelerating")
        print("case. Steady motion contributes ~0 error; the numbers are dominated by")
        print("the turns, and scale with latency + the 50 ms send interval.")


if __name__ == "__main__":
    main()
