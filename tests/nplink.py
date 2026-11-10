#!/usr/bin/env python3
"""nplink - two emulated Ataris running the netplay disk, linked in software.

Each emulator boots a TEST build of the patched disk (serial port replaced by
two RAM mailboxes); this harness plays postman between them and can freeze both
on the same simulation tick to compare their memory. It is the lockstep
determinism test: if the two machines ever disagree about the game state, the
netplay design is broken.

Needs your own rom/ballblazer.atr (git-ignored) and the stock atari800.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
from rig import Rig  # noqa: E402

TXBOX, RXBOX = 0x0AD0, 0x0AE0
STOP_EN, STOP = 0x0AF0, 0x0AF1


def labels(path):
    out = {}
    for line in open(path):
        _, a, n = line.split()
        out[n[1:]] = int(a, 16)
    return out


def build(delay, seed):
    """Assemble the TEST build and make a host and a client disk."""
    os.makedirs(os.path.join(ROOT, "build/np"), exist_ok=True)
    def sh(*a):
        subprocess.run(a, cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    for src, obj in (("resident", "res1"), ("lobby", "lob1")):
        sh("ca65", "-g", "-t", "none", "-D", "TEST=1", "-I", "src/netplay",
           "src/netplay/%s.s" % src, "-o", "build/np/%s.o" % obj)
    sh("ld65", "-C", "cfg/netplay.cfg", "-Ln", "build/np/np1.lbl",
       "-o", "build/np/np1", "build/np/res1.o", "build/np/lob1.o")
    for role in ("host", "client"):
        sh(sys.executable, "tools/mkdisk.py", "rom/ballblazer.atr",
           "build/np/np1", "build/np/test-%s.atr" % role, "--role", role,
           "--delay", str(delay), "--seed", str(seed))


class Link:
    def __init__(self, delay=24, seed=0x1234, video=False):
        build(delay, seed)
        self.L = labels(os.path.join(ROOT, "build/np/np1.lbl"))
        self.h = Rig(os.path.join(ROOT, "build/np/test-host.atr"),
                     display=":81", video=video)
        self.c = Rig(os.path.join(ROOT, "build/np/test-client.atr"),
                     display=":82", video=video)
        self.pending = {id(self.h): [], id(self.c): []}
        self.drop = None            # optional: fn(packet_bytes) -> True = lose it

    def __enter__(self):
        self.h.__enter__()
        self.c.__enter__()
        return self

    def __exit__(self, *a):
        self.h.__exit__(*a)
        self.c.__exit__(*a)

    def state(self, r):
        m = r.dump(0x0180, 0x01BF)
        b = r.dump(TXBOX, RXBOX)
        g = lambda n: m[self.L[n] - 0x180]
        return dict(tick=g("tick"), l_wr=g("l_wr"), l_base=g("l_base"),
                    r_wr=g("r_wr"), tx=b[0:11], rxlen=b[RXBOX - TXBOX])

    def exchange(self):
        """Move mailbox contents across. Returns (host state, client state)."""
        sh, sc = self.state(self.h), self.state(self.c)
        for src, s_src, dst, s_dst in ((self.h, sh, self.c, sc),
                                       (self.c, sc, self.h, sh)):
            n = s_src["tx"][0]
            if n:
                pkt = bytes(s_src["tx"][1:1 + n])
                src.poke(TXBOX, 0)
                if not (self.drop and self.drop(pkt)):
                    self.pending[id(dst)].append(pkt)
            q = self.pending[id(dst)]
            if q and s_dst["rxlen"] == 0:
                pkt = q.pop(0)
                dst.poke(RXBOX, [len(pkt)] + list(pkt))
        return sh, sc

    def run(self, blocks, hin=None, cin=None, verbose=False):
        """Advance both machines `blocks` x 16 frames, exchanging in between.
        hin / cin: dict of held inputs for the host's / client's joystick."""
        self.h.set(**(hin or dict(joy0="", trig0=False, start=False,
                                  select=False, option=False)))
        self.c.set(**(cin or dict(joy0="", trig0=False, start=False,
                                  select=False, option=False)))
        for _ in range(blocks):
            self.h.step(16)
            self.c.step(16)
            sh, sc = self.exchange()
            if verbose:
                print("host tick %3d  client tick %3d" % (sh["tick"], sc["tick"]))
        return sh, sc

    def freeze(self, ahead=40, max_blocks=200):
        """Stop both machines on one common tick; returns that tick."""
        sh, sc = self.exchange()
        d = (sh["tick"] - sc["tick"]) & 0xFF
        lead = sh["tick"] if d < 128 else sc["tick"]
        target = (lead + ahead) & 0xFF
        for r in (self.h, self.c):
            r.poke(STOP, target)
            r.poke(STOP_EN, 1)
        for _ in range(max_blocks):
            sh, sc = self.run(1)
            if sh["tick"] == target and sc["tick"] == target:
                return target
        raise RuntimeError("machines did not reach tick %d: host %d client %d"
                           % (target, sh["tick"], sc["tick"]))

    def thaw(self):
        for r in (self.h, self.c):
            r.poke(STOP_EN, 0)

    def diff(self, lo=0, hi=0xFFFF):
        """Addresses where the two machines' memory differs."""
        a, b = self.h.dump(lo, hi), self.c.dump(lo, hi)
        return [(lo + i, a[i], b[i]) for i in range(len(a)) if a[i] != b[i]]


def ranges(addrs):
    out, s, p = [], None, None
    for a in addrs:
        if s is None:
            s = p = a
        elif a == p + 1:
            p = a
        else:
            out.append((s, p))
            s = p = a
    if s is not None:
        out.append((s, p))
    return out
