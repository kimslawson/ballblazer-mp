#!/usr/bin/env python3
"""np_soak - long lockstep soak: two linked emulators play a scripted, lossy
match; every so often both are frozen on the same tick and their memory is
compared. Prints every address that ever differed (after the renderers have
settled), so anything that is not display bookkeeping stands out.

    python3 tests/np_soak.py [rounds] [seed] [loss]
"""
import random
import sys
import time

from nplink import Link, ranges, ROOT

IGNORE = [(0x0100, 0x01FF),      # stack page: link state, rings
          (0x0AD0, 0x0AFF),      # the test build's mailboxes
          (0xBC00, 0xBC00)]      # cfg_role

# Display bookkeeping. Each machine redraws its two views whenever its own
# main loop gets round to it, so these legitimately differ at a given tick;
# nothing here is read back by the simulation (if it were, the machines would
# drift apart and other addresses would start to differ).
RENDER = [(0x0300, 0x07FF), (0x0B00, 0x0FFF),      # player/missile bitmaps
          (0x000F, 0x0010), (0x0012, 0x0012),      # P1 buffer flip, colour cycle
          (0x0023, 0x0024), (0x0026, 0x0026),      # P2 likewise
          (0x00A2, 0x00B3), (0x00B5, 0x00B5),      # kernel temporaries, view turn
          (0x00DC, 0x00EF),                        # renderer work area
          (0x11D0, 0x11DF),
          (0x21D0, 0x21FF), (0x22D0, 0x22FF), (0x23D2, 0x23D8),   # P1 view tables
          (0x31D0, 0x31FF), (0x32D0, 0x32FF), (0x33D2, 0x33D8)]   # P2 view tables


def render_only(addr):
    return any(lo <= addr <= hi for lo, hi in RENDER)


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    loss = float(sys.argv[3]) if len(sys.argv) > 3 else 0.25
    rnd = random.Random(seed)
    t0 = time.time()
    ever = {}
    bad = []
    ticks = 0
    with Link(delay=24, seed=seed * 7919 + 1, video=True) as k:
        k.run(30)
        k.run(2, hin=dict(start=True))
        k.run(8)
        k.drop = lambda p: rnd.random() < loss
        last = None
        for n in range(rounds):
            def pick():
                j = rnd.choice(["U", "U", "U", "UL", "UR", "L", "R", "D", ""])
                return dict(joy0=j, trig0=rnd.random() < 0.25)
            hin, cin = pick(), pick()
            for _ in range(rnd.randint(4, 16)):
                sh, sc = k.run(1, hin=hin, cin=cin)
                if last is not None:
                    ticks += (sh["tick"] - last) & 0xFF
                last = sh["tick"]
            if n % 4 == 3:
                t = k.freeze()
                k.run(4)                       # let both renderers finish
                d = [x for x in k.diff()
                     if not any(lo <= x[0] <= hi for lo, hi in IGNORE)]
                for a, _, _ in d:
                    ever[a] = ever.get(a, 0) + 1
                bad += [a for a, _, _ in d if not render_only(a)]
                print("round %3d  tick %3d  ~%5d ticks  %3d bytes differ  %s"
                      % (n, t, ticks, len(d),
                         " ".join("%04X-%04X" % r
                                  for r in ranges([a for a, _, _ in d])[:14])),
                      flush=True)
                if n % 20 == 19:
                    k.h.shot(ROOT + "/build/shots/soak_h_%03d.png" % n)
                    k.c.shot(ROOT + "/build/shots/soak_c_%03d.png" % n)
                k.thaw()
                last = None
        k.h.shot(ROOT + "/build/shots/soak_h_end.png")
        k.c.shot(ROOT + "/build/shots/soak_c_end.png")
    print("ever-differing addresses (count):")
    for s, e in ranges(sorted(ever)):
        print("  %04X-%04X  %s" % (s, e, " ".join(str(ever[a])
                                                  for a in range(s, e + 1))))
    print("done in %.0fs, ~%d ticks" % (time.time() - t0, ticks))
    if bad:
        print("FAIL: simulation state differed at:",
              " ".join("%04X" % a for a in sorted(set(bad))))
        sys.exit(1)
    if ticks < rounds * 20:
        print("FAIL: the match barely advanced (%d ticks)" % ticks)
        sys.exit(1)
    print("PASS: both machines agreed on every byte of game state at %d "
          "checkpoints" % (rounds // 4))


if __name__ == "__main__":
    main()
