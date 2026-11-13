# Timing: what the player feels, and why the numbers are what they are

## Felt latency

The only delay a player experiences is the **input delay**: a stick movement
takes effect `delay` frames later, on both machines at once. Both craft, the
ball and the score are always consistent; there is no rubber-banding and no
"who had the ball" dispute, because there is only one game.

## How much delay a link needs

The link is a ping-pong, and what a packet says is "here are my inputs up to
my current tick + delay". So between two packets from the other side a
machine can run at most `delay` ticks: **full speed needs delay >= round trip,
in frames.** With less, the game runs at `delay / round trip` of full speed,
in bursts - it stutters, evenly on both machines, and the music with it.

The host's lobby therefore times the link (eight round trips) and sets the
delay to a quarter more than one round trip, plus one frame. A number typed at
the prompt overrides that: smaller is snappier but stutters if it is below the
round trip; larger is smooth but sluggish.

## Round trips, estimated and measured

A typical packet is 3 bytes: 12.5 ms on the wire at 2400 baud, each way.

| setup | round trip | delay chosen |
|---|---|---|
| two real Ataris + FujiNets (estimate from the firmware source; not measured) | 40-50 ms | 4-5 frames |
| two emulators with built-in FujiNet-PC on a LAN (first field test, an iPad and an iPhone) | about 130 ms | 11 frames |

The emulator figure comes from a screen recording of that test: with the then
fixed delay of 5 the match clock ran at 65 % of real time, i.e. 5 ticks per
round trip of ~130 ms. Emulators are slower than hardware here for a
structural reason: they run each frame in a burst and then sleep, so serial
bytes that the FujiNet side paces out in real time (one per 4.2 ms) are only
picked up at the next frame - each direction costs an extra frame or two.

That first test also showed why the retransmission timeout must be far above
the round trip: it was 8 frames (133 ms), right on top of the actual round
trip, so the host kept resending while answers were still in flight. It is
now 30 frames.

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
