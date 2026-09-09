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

### Per-player control seam — the precise net hook (VBI, every frame)

The immediate VBI at **`$4CAB`** dispatches `JSR $5DA5` (keyboard/console poll —
`KBCODE $D209` at `$5DB7`, `CONSOL` at `$5DBD`) and `JSR $5F27` (player control).
`$5F27` decides each player's control **source** from a per-player selector:

| player | selector | gate (`LDY sel / BEQ joystick`) | joystick read | droid path |
|--------|----------|---------------------------------|---------------|------------|
| 1      | **`$23DE`** | `$5F27` | `$5F3D` (`PORTA` low nibble) | `JSR $9A4A`, X=`$00` |
| 2      | **`$33DE`** | `$5F64` | `$5F7A` (`PORTA` high nibble)| `JSR $9A4A`, X=`$14` |

- Selector `== 0` → that player is a **human** (reads the joystick); `!= 0` →
  the **droid AI** at **`$9A4A`** drives it. `$9A4A` is called per player with
  an **X index of stride `$14` (20)** — the game keeps a 20-byte per-player
  block. Trigger edge-detect state sits at `$23E1` (P2) and its P1 analog.
- **This is the cleanest integration point.** In net mode, route the *remote*
  player through the droid branch but replace `JSR $9A4A` with a call that
  produces the opponent's move from the received network state (`rem_*`); leave
  the *local* player on the joystick path. The game's own "apply move + physics"
  code downstream is reused unchanged.

## Candidate state variables (Seam B)

**Pinned by controlled input** (not just diffed). Using the control seam above,
`drive_atari.py` forces a player onto the joystick path (patch its gate to
`LDY #$00`), forces a stick direction (patch the `PORTA` read to `LDA #imm`),
and dumps. Bytes whose delta **reverses sign** between opposite directions are
that player's responding state variables — this correlates against music/timer
noise, which does not track stick direction.

Confirmed responders (zero page = fast kinematics):

| player (forced) | vertical (fwd/back) | lateral (left/right) |
|-----------------|---------------------|----------------------|
| P1 (`$5F3D`)    | `$F1:$F2`, `$F4:$F5` (16-bit lockstep pairs), `$F8`, `$D6`, `$D8` | `$12D1` (clean ±8), `$089A` (±5) |
| P2 (`$5F7A`)    | `$7E`,`$80`,`$8E`,`$90`,`$A5–$AD`,`$B2`, `$F8` | `$FB` (clean ±8) |

- The lockstep pairs (`$F1:$F2`, `$F4:$F5`) are **16-bit fixed-point** kinematics
  — the same shape as the netcode packet (`docs/04`). Held-input trajectories
  oscillate with net drift (momentum + grid friction), consistent with velocity
  or a position under damping.
- `$22F4`, `$32E1`, `$14D0` respond to **both** axes → derived screen-space
  values, **excluded** from the pure-coordinate set.
- Still open (a couple more targeted captures): the exact position-vs-velocity
  split within each cluster, and the plasmorb (ball) variables. But because the
  recommended hook is the **control seam** (`$9A4A` / `$23DE`/`$33DE`), the
  netcode reuses the game's physics and needs only periodic hard-correction of
  these clusters to bound drift — it does not require a perfect byte-by-byte map
  up front.

## How Seam-B was pinned — method and tooling

**Tooling:** `tools/drive_atari.py` drives the `atari800` monitor headlessly to
inject input by *patching instructions in RAM* — rewrite a read (`LDA $D300`,
3 bytes) to `LDA #imm; NOP`, or a control gate (`LDY $23DE`) to `LDY #$00; NOP`.
Boot → SIGINT-break → `C`-patch → run → `WRITE`-dump; all proven.

**The key that unlocked it.** The main loop at `$4C72` is a passive VBI-driven
spinner (`LDA $B3 / BPL`, `INC $B5`); the game logic — including player control
— runs entirely in the immediate VBI (`$4CAB`). So the PC *never leaves* `$4C72`
whether in menu or match, and watching the PC was the wrong signal. `$5F27`
(player control) **does run every frame**, gated per player by the `$23DE` /
`$33DE` selectors above. Forcing a selector's gate to the joystick path and
patching the `PORTA` read lets us move a rotofoil on demand — **no need to
navigate the menu or start a match** — and the sign-reversal test isolates the
responding variables cleanly. (The earlier attempt failed only because it forced
console/trigger "pressed" and watched the PC; the selector-gate method is the
right lever.)

**Music-engine noise, for reference.** Ballblazer's algorithmic music churns
zero page every frame; bytes that change large-and-continuous *without* tracking
stick direction (`$B6,$C6,$CB,$D4`; mirror pairs `$D9`≡`$FE`, `$DA`≡`$FF`) are
music state and are correctly rejected by the sign-reversal correlation.

**Remaining refinements (optional, a couple more captures each):** split
position vs velocity within each cluster (hold one direction across ~8 frames
and classify ramp vs plateau), and pin the plasmorb (ball) variables (let the
host simulate a match and diff while the ball is in flight). Neither blocks the
patch:
turns that cluster from "the `$F0–$FC` neighbourhood" into exact addresses.

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
   and starts a 2-player game. Set the remote player's selector (`$23DE` or
   `$33DE`) to the droid value and the local player's to `0` (joystick).
2. **Hook the control seam (the confirmed integration point).** The remote
   player's droid branch calls `JSR $9A4A`; in net mode redirect that call to a
   small dispatch that instead applies the opponent's move from the received
   state. The local player stays on the joystick path (`$5F3D`/`$5F7A`). The
   game's own move+physics code downstream is reused unchanged — this is the
   input-level path but at the game's *own* AI seam, so latency is one packet,
   not a full-frame lockstep.
3. **Correct drift with the pinned Seam-B vars.** Every few frames, hard-write
   the remote rotofoil's kinematic cluster (P2: `$7E/$80/$8E/$90/$A5–$AD`,`$FB`;
   P1: `$F1:$F2/$F4:$F5/$F8`,`$12D1`) from `rem_*`, and copy the local player's
   cluster into `loc_*` before `ng_tick`. Host drives the ball cluster (still to
   be pinned). This keeps the two machines convergent despite momentum/friction.
4. **Call `ng_tick` once per frame** from the VBI (`$4CAB`) or the main loop
   (`$4C72`); set `loc_*` before / read `rem_*`,`ball_*` after (the `docs/04`
   contract).
5. **Place the net code** in reclaimed droid-AI space (`$9A4A` and the
   `$5E24–$5E61` seed code) + page 6 buffers. If it outgrows that, add sectors to
   the disk image and have a boot-loader tweak read them into a free region.

The transport, protocol, checksum, and dead reckoning already exist and are
tested (`src/net/`, `tests/`); this plan is the wiring, now with real target
addresses instead of placeholders.

## Reproduce

Needs your own `rom/ballblazer.atr` locally (never committed):

```sh
make dump            # handoff image  -> build/disk/ram.bin
make dump-run        # running image  -> build/disk/ram_run.bin
make findings        # memory map + I/O seam scan of the running image

# pin Seam-B by forcing a player onto the joystick path and injecting a
# direction (no menu/match navigation needed). P1 up vs down:
D=rom/ballblazer.atr
python3 tools/drive_atari.py $D boot run:3 patch:5F27:A0,00,EA \
  patch:5F3D:A9,FE,EA run:1 dump:build/disk/u1.bin run:1 dump:build/disk/u2.bin \
  patch:5F3D:A9,FD,EA run:1 dump:build/disk/d1.bin run:1 dump:build/disk/d2.bin quit
# then diff u1/u2 vs d1/d2 and keep bytes whose delta reverses sign.
# For P2, force gate $5F64 and read $5F7A instead (see the pinned table above).
```
