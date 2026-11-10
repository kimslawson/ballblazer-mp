# Timing: what the player feels, and why the numbers are what they are

## Felt latency

The only delay a player experiences is the **input delay**: a stick movement
takes effect `delay` frames later, on both machines at once. The host chooses
it in the lobby (3–9, default 5 = 83 ms). Both craft, the ball and the score
are always consistent; there is no rubber-banding and no "who had the ball"
dispute, because there is only one game.

If an input has not arrived by the time its tick is due, that machine skips
frames until it has: a visible stutter, never an inconsistency. Too small a
delay shows up as stutter, too large as sluggish steering.

## Round trip (estimate)

A typical packet is 3 bytes. At 2400 baud:

| step | time |
|---|---|
| 3 bytes on the wire, Atari → FujiNet | 12.5 ms |
| FujiNet batches up to 3 ms, then UDP over Wi-Fi | ~3–6 ms |
| FujiNet → Atari, paced at the line rate | first byte lags ~4 ms; the packet completes ~12.5 ms after it started arriving |
| worst-case wait for a display kernel before the last byte is read | 3.3 ms |

One direction: roughly 20–25 ms. A full host → client → host cycle: 40–50 ms,
i.e. about three frames, during which each side accumulates three ticks of
input — still one run-length byte if the stick did not move.

An input sampled just after a packet left waits one cycle for the next packet
and one half-cycle to arrive: 60–75 ms. Hence the default delay of 5 frames;
4 may hold on a quiet network, 3 is optimistic.

These are computed from the firmware source and the baud rate, **not measured
on hardware**. The emulator's cassette model in `tests/np_serial.py` reproduces
the byte timing (one byte per 65 scanlines) but not Wi-Fi.

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
