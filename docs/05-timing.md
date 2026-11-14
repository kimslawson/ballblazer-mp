# Timing: what the player feels, and why the numbers are what they are

## Felt latency

The only delay a player experiences is the **input delay**: a stick movement
takes effect `delay` frames later, on both machines at once. Both craft, the
ball and the score are always consistent; there is no rubber-banding and no
"who had the ball" dispute, because there is only one game.

## How much delay a link needs

The link takes turns, and what a packet says is "here are my inputs up to my
current tick + delay". Each side hears from the other once per round trip,
and what it hears was sampled half a round trip earlier. For a tick always
to find its inputs waiting, a packet has to last one and a half round trips:

**smooth play needs delay >= 1.5 x round trip, in frames.**

With less, the game runs at `2/3 x delay / round trip` of full speed, in a
stop-and-go rhythm - it stutters, evenly on both machines, and the music with
it. `tests/np_delay.py` runs the protocol on a simulated line and prints the
whole table; it is part of `make test`.

The host's lobby therefore times the link: sixteen round trips with packets
the size of a typical input packet, one by one. It shows the average and the
worst, and sets the delay to 1.5 x the worst, rounded up, plus one frame. A
number typed at the prompt overrides that: smaller is snappier but stutters;
larger is smooth but sluggish.

This is the price of turn-taking on one serial line. A link that could send
in both directions at once, every frame, would need only about half a round
trip plus a frame or two - a third of the delay (see ROADMAP).

## Round trips, estimated and measured

A typical packet is 3 bytes: 12.5 ms on the wire at 2400 baud, each way.

| setup | round trip | delay chosen |
|---|---|---|
| two real Ataris + FujiNets (estimate from the firmware source; not measured) | 40-50 ms, 3 frames | 6 frames |
| two emulators with built-in FujiNet-PC on a LAN (field tests, an iPad and an iPhone) | 85-115 ms, 5-7 frames | 9-12 frames |

The emulator figure comes from a screen recording of the first test: with the
then fixed delay of 5 the match clock ran at 65 % of real time, which by the
rule above is a round trip of about 5 frames. (An earlier version of this
document read the same recording as "5 ticks per round trip", i.e. 130 ms,
and had the lobby pick 1.25 round trips. That is two frames short of what
turn-taking needs, and input packets are longer than the two-byte pings it
timed with - so the second field test still stuttered.) Emulators are slower
than hardware here for a structural reason: they run each frame in a burst
and then sleep, so serial bytes that the FujiNet side paces out in real time
(one per 4.2 ms) are only picked up at the next frame - each direction costs
an extra frame or two.

The first test also showed why the retransmission timeout must be well above
the round trip: it was 8 frames, close to the actual round trip, so the host
kept resending while answers were still in flight. It is now three times the
worst round trip the lobby measured (at least 12 frames), or 30 frames if
the link was not timed.

### What FujiNet does to the bytes

Read from the firmware source (`lib/device/sio/netstream.cpp`), not measured:

- Outgoing serial bytes are sent as a UDP datagram once the batch is 3 ms
  old. At 2400 baud a byte takes 4.2 ms, so on real hardware **every byte
  travels as its own datagram**. (An emulator emits a frame's worth of bytes
  in a burst, so there they travel together.)
- Since firmware of 2026-06-27, incoming UDP datagrams wait in a queue of at
  most four (`rx_depth` in the FujiNet configuration), and when a fifth
  arrives the oldest is discarded. Four one-byte datagrams are 17 ms of
  line time: a network hiccup longer than that, in the middle of one of our
  packets, costs bytes. The checksum catches it and the host resends after
  its timeout - a visible freeze.

Both points argue for short packets and for raising `rx_depth` on a real
FujiNet if freezes occur.

`tools/vpeer.py` prints the round trip, the achieved tick rate and the share
of time spent waiting, every two seconds - the instrument for any link that
misbehaves.

## Why 2400 baud and not faster

POKEY holds one received byte. If the next one finishes before the CPU has
fetched the first, it is gone. With the patch, the longest time the CPU cannot
take an IRQ is one display kernel: 51 scanlines, 3.26 ms. So:

| baud | byte time | survives a 3.26 ms blackout? |
|---|---|---|
| 19200 | 0.52 ms | no (6 bytes lost) |
| 4800 | 2.08 ms | no |
| **2400** | **4.16 ms** | **yes, with 0.9 ms to spare** |

Taking the interrupt *inside* the kernel is not an option: the kernel has about
7 cycles of slack per scanline, so any detour shifts the rest of that view down
a line for a frame.

## CPU budget

Per second, roughly 100 received/sent bytes × ~100 cycles plus ~50 packets ×
~600 cycles ≈ 40,000 cycles — about 2 % of the CPU. The tick itself is
unchanged apart from ~250 cycles of gate/decode per frame.

## Interrupt nesting, for the record

- The tick (VBI or main-loop context) runs with IRQs enabled, so bytes are
  collected during its 2.6 ms.
- If the VBI interrupts the IRQ handler itself, that tick runs with IRQs
  masked instead (re-entering the handler would corrupt it); 2.6 ms is still
  inside the 4.16 ms window.
- If a display kernel interrupts the IRQ handler, the kernel's closing routine
  is not run there but handed to the IRQ handler, which runs it on its way out
  with IRQs enabled.
- The tick hook and the IRQ-context protocol code share no scratch variables.
  (They once did; `tests/np_serial.py` caught it.)
