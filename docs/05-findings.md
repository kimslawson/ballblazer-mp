# Findings from the disk image

Reverse-engineering notes extracted by running the user's own `.atr` in
`atari800` (headless) and analysing RAM dumps. **This file records only facts —
addresses, a memory map, and which instructions touch which I/O registers.** No
game code, ROM bytes, or disassembly listings are stored here or in the repo;
the dumps and listings stay local (git-ignored `build/`, `rom/`).

Everything below is reproducible with the committed tooling (see the bottom).

## How the dumps were produced

`atari800` 5.0 runs fully headless with SDL's dummy driver
(`SDL_VIDEODRIVER=dummy`), dropping into its terminal monitor (`-monitor`). Two
captures via `tools/dump_ram.sh`:

- **handoff** — breakpoint `BPC $07AB` (the loader's `JMP (RUNAD)`), then
  `WRITE $0000 $BFFF` — the game the instant before it runs.
- **run** — `CONT`, run ~N s in `-turbo`, `SIGINT` into the monitor, `WRITE` —
  a live title/attract state.

## Boot / load (disk)

- Custom 3-sector boot → `$0700`, exec `$0706`; SIO-reads the game via a DCB at
  `$0300–$030B` / `SIOV $E459`; hands off with `JMP (RUNAD)` at **`$07AB`**.
- By the handoff, the **engine is already resident in `$4000–$BFFF`** (~95%+
  full — 32 KB of code/data). `$1000–$3FFF` is empty at handoff but fills at
  runtime (screen memory, display lists, work buffers), so it is **not** free.

## Memory map

| region        | at handoff | running | notes                                  |
|---------------|-----------:|--------:|----------------------------------------|
| `$0000–$0FFF` | partial    | partial | ZP vars, stack, OS pages, boot loader  |
| `$1000–$3FFF` | empty      | in use  | runtime screen/DL/buffers (NOT free)   |
| `$4000–$BFFF` | ~full      | ~full   | **resident game engine (code + data)** |

Main loop / attract spins around **`$4C72`** (observed PC `$4C8A: JMP $4C72`).

## The control module (Seam A + C) — `$5D00–$5F90`

Instruction sites that read input / PRNG / console (from `scan_findings.py io`):

| what                     | address(es)                          | meaning                          |
|--------------------------|--------------------------------------|----------------------------------|
| `LDA PORTA ($D300)`      | **`$5F3D`**, **`$5F7A`**             | read raw joystick directions     |
| `LDX TRIG0 ($D010)`      | `$5F46`                              | fire button, player using trig 0 |
| `LDX TRIG1 ($D011)`      | `$5F85`                              | fire button, player using trig 1 |
| `CONSOL ($D01F)`         | **`$5DBD`**                          | Start/Select/Option (menu/mode)  |
| `RANDOM ($D20A)` cluster | **`$5E24,$5E30,$5E3A,$5E4B,$5E57,$5E61`** | droid-AI randomised decisions |

Reading of the whole module:

- **`$5F3D…$5F46`** and **`$5F7A…$5F85`** are the **two per-player input
  routines** (each pairs a `PORTA` read with its trigger). They are distinct
  handlers (only ~12% byte-identical), not copies — expect different processing
  per side. → **Seam A input half.**
- The six back-to-back `RANDOM` reads at **`$5E24–$5E61`** are the **droid AI**
  making randomised choices. Other `RANDOM` sites ($4CA1, $77xx, $7Axx, $9A5x,
  $BCD5–$BD34) are elsewhere (music/effects/attract). → **Seam A AI half.**
- **`$5DBD`** (`CONSOL`) is where the menu reads Start/Select/Option. → **Seam C
  (mode select / match start).**

## Candidate state variables (Seam B)

Diffing two running dumps 4 s apart (`scan_findings.py diff`) — changing bytes,
mostly zero page (fast game vars):

`$00B5`(2), `$00C6`, `$00CB`, `$00D4`, `$00D6`, `$00D8`, `$00F1`(2),
`$00F4`(2), **`$00F7`(6-byte block)**, and `$01FE`.

These are candidates for rotofoil/plasmorb position/velocity/heading (plus some
music/timer noise). Attract mode moves little, so **pin them with in-game
motion**: start a match, capture two dumps a few frames apart while a rotofoil
glides, and diff — the bytes that track the glide are the position/velocity
vars. `tools/dump_ram.sh run` + `scan_findings.py diff` is that workflow.

## Free RAM for injected code

From the running image (`scan_findings.py` zero-run analysis):

- **Page 6 `$0600–$06FF`** — essentially free (6/256 bytes set). Classic user
  scratch page; good for the small N: IOCB/DCB glue and the 16-byte packet
  buffers.
- **`$094A–$0B3D`** — 500 contiguous free bytes (verify it stays free *during a
  match*, not just attract, before trusting it).
- **The droid-AI routine itself** — since net mode *replaces* the AI, its code
  region (around `$5E24–$5E61` and the routine containing it) is reclaimable for
  the network dispatch. This is the cleanest home for the state-apply code.

`$1000–$2FFF` looked free at handoff but is used at runtime — **do not** inject
there.

## Patch plan, anchored to these addresses

Net mode = the game's native **two-player** path with player 2 driven by the
network instead of the droid, using the tested state-sync layer (`src/net/`).

1. **Add a net-match mode (Seam C, `$5DBD`).** Extend the menu so one console
   choice starts a network match: it `JSR`s `ng_init`, opens `N:` (URL/role),
   and forces the two-rotofoil path (not the 1P/droid path).
2. **Neutralise the droid (Seam A AI, `$5E24–$5E61`).** In net mode, branch
   around the AI routine so it no longer drives player 2. Reclaim its bytes for
   the network dispatch.
3. **Feed player 2 from the network (Seams A input + B).** Two equivalent
   implementations; pick per what the code makes easy:
   - *State-level (preferred, matches `docs/04-netcode.md`):* each frame, after
     the game's physics, overwrite player 2's position/velocity/heading vars
     (the pinned Seam-B addresses) with `rem_*`, and copy the local player's
     vars into `loc_*` before `ng_tick`. Host also drives `ball_*`.
   - *Input-level (simpler, more latency):* at the player-2 input routine
     (`$5F7A`/`$5F85`) substitute a `PORTA`/trigger byte synthesised from the
     received state. Falls back to lockstep-style latency; only if state vars
     prove hard to pin.
4. **Call `ng_tick` once per frame** from the main loop (near `$4C72`), and set
   `loc_*` before / read `rem_*`,`ball_*` after (the `docs/04` contract).
5. **Place the net code** in reclaimed AI space + page 6 (buffers). If it
   outgrows that, add sectors to the disk image and have a boot-loader tweak
   read them into a confirmed-free region.

The transport, protocol, checksum, and dead reckoning already exist and are
tested (`src/net/`, `tests/`); this plan is the wiring, now with real target
addresses instead of placeholders.

## Reproduce

Needs your own `rom/ballblazer.atr` locally (never committed):

```sh
make dump            # handoff image  -> build/disk/ram.bin
make dump-run        # running image  -> build/disk/ram_run.bin
make findings        # memory map + I/O seam scan of the running image
# pin Seam-B vars:
tools/dump_ram.sh run rom/ballblazer.atr build/disk/a.bin 5
tools/dump_ram.sh run rom/ballblazer.atr build/disk/b.bin 8
tools/scan_findings.py diff build/disk/a.bin build/disk/b.bin
```
