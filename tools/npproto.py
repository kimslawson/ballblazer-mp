#!/usr/bin/env python3
"""npproto - reference implementation of the Ballblazer netplay link protocol.

Mirrors src/netplay/resident.s byte for byte. Used by the emulator tests and by
tools/vpeer.py (a PC stand-in for the second Atari).

Packet:  [hdr] [0-7 body bytes] [checksum]
  hdr   bit 7   sequence bit
        bit 5-3 body length
        bit 2-0 type (0 DATA, 1 START, 2 HELLO, 3 WELCOME, 4 PING)
  DATA body byte: bits 0-4 input code, bits 5-7 = repeat count - 1
  input code: bits 0-3 joystick nibble (PORTA style, 0 = pushed) or a key
              (1 START, 2 SELECT, 3 OPTION, 4 SPACE, 8 ESC, 12 RETURN);
              bit 4 = trigger pressed
"""
T_DATA, T_START, T_HELLO, T_WELCOME, T_PING = 0, 1, 2, 3, 4
NEUTRAL = 0x0F
VERSION = 3
DELAY_MIN, DELAY_MAX, DELAY_DEFAULT = 3, 20, 9
GAME_SUM = 0xA4A5
PORT = 6502

KEYS = {"start": 1, "select": 2, "option": 3, "space": 4, "esc": 8,
        "return": 12}
_DIR = {"U": 1, "D": 2, "L": 4, "R": 8}


def code(stick="", trig=False, key=None):
    """Input code from a stick string like 'UL', trigger and/or key name."""
    if key:
        return KEYS[key]
    v = 0x0F
    for c in stick.upper():
        v &= ~_DIR[c]
    return v | (0x10 if trig else 0)


PINGS = 16                 # round trips the lobby times
PING_BODY = bytes(2)       # a PING is the size of a typical DATA packet
T_O_DEFAULT, T_O_MIN = 30, 12


def delay_for(worst):
    """The input delay the lobby derives from the slowest of the round trips
    it timed, in frames (lobby.s `measure`).

    The link takes turns: each side hears from the other once per round trip
    RT, and what it hears was sampled RT/2 earlier. A packet built at time t
    carries inputs up to tick(t) + delay and must last until the next one
    arrives; for the host that is at t + 2 RT - RT/2, for the client the same
    by symmetry, so stall-free play needs delay >= 1.5 RT. Below that the
    game runs at 2/3 * delay / RT of full speed."""
    worst = min(worst, DELAY_MAX)
    return max(DELAY_MIN, min(DELAY_MAX, worst + (worst + 1) // 2 + 1))


def timeout_for(worst):
    """Host resend timeout in frames: three worst round trips of silence."""
    return max(T_O_MIN, min(T_O_DEFAULT, 3 * min(worst, DELAY_MAX)))


def csum(data):
    a = 0xA5
    for b in data:
        a ^= b
        c = a >> 7
        a = (a << 1) & 0xFF
        a = (a + 0x1D + c) & 0xFF
    return a


def packet(hdr, body=b""):
    p = bytes([hdr | (len(body) << 3)]) + bytes(body)
    return p + bytes([csum(p)])


class Parser:
    """Byte stream -> validated packets (same framing rules as the 6502)."""

    def __init__(self):
        self.buf = bytearray()

    def idle(self):
        self.buf.clear()

    def feed(self, data):
        out = []
        for b in data:
            self.buf.append(b)
            need = ((self.buf[0] >> 3) & 7) + 2
            if len(self.buf) >= need:
                p = bytes(self.buf)
                self.buf.clear()
                if csum(p[:-1]) == p[-1]:
                    out.append(p)
        return out


def rle(codes, max_items=4):
    """Pack consecutive input codes -> (body bytes, how many were consumed)."""
    body, i = bytearray(), 0
    while i < len(codes) and len(body) < max_items:
        c, run = codes[i], 1
        i += 1
        while i < len(codes) and codes[i] == c and run < 8:
            run += 1
            i += 1
        body.append(c | (run - 1) << 5)
    return bytes(body), i


def unrle(body):
    out = []
    for b in body:
        out += [b & 0x1F] * ((b >> 5) + 1)
    return out


class Endpoint:
    """One side of the in-game exchange (after the handshake)."""

    def __init__(self, host, delay):
        self.host = host
        self.delay = delay
        self.local = [NEUTRAL] * delay      # our inputs, indexed by tick
        self.remote = [NEUTRAL] * delay     # theirs
        self.l_base = delay                 # first tick the peer lacks
        self.seq = 0x00 if host else 0x80   # host: in flight; client: last seen
        self.tx = None                      # last packet (for retransmission)
        self.tx_cnt = 0
        self.got_data = False

    def push(self, c):
        """Queue our input for the next tick slot."""
        self.local.append(c)

    def build(self):
        body, n = rle(self.local[self.l_base:])
        self.tx_cnt = n
        self.tx = packet(self.seq | T_DATA, body)
        return self.tx

    def kick(self):
        """Host only: (re)send when nothing has been heard for a while."""
        return self.tx if self.tx else self.build()

    def on_packet(self, p):
        """Handle a valid packet; returns the packet to send back, or None."""
        if p[0] & 7 != T_DATA:
            return None
        s = p[0] & 0x80
        if self.host:
            if s != self.seq:
                return None
            self.seq ^= 0x80
        else:
            if s == self.seq:
                return self.tx              # duplicate: repeat our answer
            self.seq = s
            self.got_data = True
        self.l_base += self.tx_cnt
        self.remote += unrle(p[1:-1])
        return self.build()
