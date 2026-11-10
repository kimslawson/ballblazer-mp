# Findings about the game image

Facts established by running the user's own disk image in `atari800` and
reading local disassembly. **Addresses and behaviour only** — no game code,
bytes or listings are stored in this repository.

## The image

- "Regulation Certified" `.atr`, 35,344 bytes (276 × 128-byte sectors),
  md5 `a37afb54b6edbd03c348efa0b714d37c`.
- Not a DOS disk and not a custom format either: three boot sectors hold a
  generic binary-file loader (`$0700`), and from sector 4 on the disk is one
  ordinary Atari binary-load stream, 34,866 bytes:

  | segment | purpose |
  |---|---|
  | `$4000–$4032` + `INITAD=$4000` | a small init stub (lowers `RAMTOP`, reopens the screen) |
  | `$3819–$BFFF` | the game |
  | `RUNAD=$4C00` | start |

  The stream length lives in the boot sector at `$0709–$070B`. Appending
  segments and bumping that length is all it takes to add code — that is what
  `tools/mkdisk.py` does.
- The game code never modifies itself (`$3819–$BFFF` is byte-identical between
  load and a running match).
- `$BC00–$BFFF` is a self-contained block — its own interrupt vectors, serial
  I/O, a jump to `$3000` — that nothing else references: the original tape/disk
  loader. Dead once the game runs.

## Structure

- `$4C00` cold start: `SEI`, silence the hardware, **clear zero page and
  `$0300–$3FFF`** (`$5FA4`), build tables, install the VBI, fall into the main
  loop. The game never executes `CLI`: it runs with IRQs masked for good and
  polls the keyboard's interrupt status bit by hand.
- `$4C72` main loop: waits for a flag (`$B3`) set at the end of a view's
  display kernel, then redraws one of the two views (`$9C28` / `$A08F`,
  alternating on `$B5`). It only draws.
- `$4CAB` immediate VBI → **`$4CBE`, the tick**: the whole simulation, once
  per frame. `$B4` is its guard: `0` idle, `$FF` running. The main loop brackets
  the few places where it copies a consistent snapshot with `INC $B4 … DEC $B4`;
  a VBI that arrives inside one skips the tick, and the main loop then runs the
  tick itself (`JSR $4CBE`) as it leaves the bracket. So the tick can run from
  either context — which is why the patch wedges the tick's entry rather than
  its call sites.
- One tick takes about 41 scanlines (2.6 ms) in ordinary play.

## Where the tick touches hardware

| what | where |
|---|---|
| joysticks `PORTA` | `$5F3D` (player 1, low nibble), `$5F7A` (player 2, high nibble) |
| triggers | `$5F46` (`TRIG0`), `$5F85` (`TRIG1`) |
| console keys | `$5DBD`; START/SELECT/OPTION are folded into key codes `$27`/`$6C`/`$2C` |
| keyboard | `$5DAB` tests the keyboard/break bits of `IRQST`, `$5DB7` reads `KBCODE`; `$5DAE`/`$5DE4` re-arm `IRQEN` |
| `RANDOM` | `LDA` at `$4CA1 $4CA6 $4CFA $4D08 $5232 $5E24 $5E30 $5E3A $5E4B $5E57 $5E61 $5FD1 $7774 $77D9 $77E1 $7A7E $9A58`; `CMP` at `$7754 $7A6B $7A70`; `LDY` at `$9A61` |
| sound | all eight AUDF/AUDC registers are written in one block at `$797B` from zero-page staging bytes; `AUDCTL` once at `$79E0` |

There are no reads of `VCOUNT`, the PAL flag, paddles or the collision
registers. Keys the game acts on: START (start a match), SELECT/OPTION
(options), SPACE, ESC, RETURN.

Player designation (HUMAN or DROID 1–9) is `$23DE` (player 1) / `$33DE`
(player 2), 0 = human; a droid's moves come from `$9A4A`.

## Simulation state that depended on display timing

Each craft's facing (0–3) exists twice: the value the simulation *asks for*
(`$11` player 1, `$25` player 2) and the *current* one it steers by (`$0C`,
`$20`). The stock game copies request → current inside a display interrupt
(`$5A13`, `$5C76`), and only when that view's freshly drawn frame has just
been put on screen, so the turn takes effect when the picture shows it. On
one machine that is fine. Across two machines the redraw finishes at
different moments, so the patch performs the copy once per tick instead.

Everything else that differs between two lockstepped machines is display
bookkeeping (buffer-flip counters, colour cycling, kernel temporaries, view
tables, sprite memory); the list is the `RENDER` table in `tests/np_soak.py`.

## A damaged byte in this dump

The main loop has four of the "run the tick I made the VBI skip" calls. Three
are `JSR $4CBE`. The fourth, at **`$A439`**, reads `JSR $4C41` — the operand's
low byte is `$41` where `$BE` belongs, i.e. every bit inverted. `$4C41` is in
the middle of the start-up code: when a VBI lands in that ~60-cycle bracket,
the stock game re-runs the tail of its initialisation (re-arming the VBI,
which then re-seeds two counters from `RANDOM`) and drops back into the main
loop, leaking a few bytes of stack. In the emulator it happened every minute
or two of play; on a single machine it is invisible.

For netplay it is fatal in the long run — one of the re-seeded counters
(`$B6`) decides the order in which the two craft are processed, and the event
happens at a different moment on each machine — so in network mode the lobby
writes the intended target back. This is how the soak test first failed, and
the only simulation desync found.

(Whether the alternate "[a]" dump of the same release has the byte intact was
not checked; it has a different checksum and is not supported.)

## Display interrupts

Per view: a short set-up interrupt, then a **kernel** that owns the CPU for 51
scanlines (3.26 ms), rewriting scroll and colour registers every line — the
checkerboard is prerendered line patterns, moved by per-line `LMS`/`HSCROL`.
At its end, on alternate frames, each kernel calls a long table-update routine
(`$7F56` / `$80CC`) while still inside the interrupt. Measured: with that
routine the stretch with IRQs masked reaches about 170 scanlines (10.8 ms),
because it is itself interrupted by the VBI and the other view's kernel.
The patch re-enables IRQs for those two routines.

Screen memory is `$1000–$3FFF` (48 pages of line patterns, the upper ones
part of the loaded image). Sprites use single-line player/missile memory at
`$0300–$07FF` and `$0B00–$0FFF` (the two views use different `PMBASE`s).
The display list is at `$0800`, the scoreboard text at `$094A`.

## Starting a match

The title/attract sequence runs by itself. **START** begins a match with the
current options (3:00, two humans by default). The trigger does not.
