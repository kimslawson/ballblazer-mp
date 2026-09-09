# Disassembling Ballblazer (your own copy)

The goal of this phase is an **annotated, byte-exact** disassembly you can
modify and reassemble. "Byte-exact" is the objective correctness test: if the
reassembled image differs from your ROM by even one byte, you have not yet
correctly separated code from data.

No ROM or disassembly is committed to this repo (see the `.gitignore` and
`LICENSE`). You do this locally on a copy you own.

## Prerequisites

```sh
sudo apt-get install cc65 dasm atari800      # ca65, ld65, da65, sim65 + emu
```

## Step 1 — place your ROM

Put your 16K Ballblazer cartridge dump at `rom/ballblazer.rom` (a `CART`-headered
dump is fine — the header is stripped automatically). See `rom/README.md`.

## Step 2 — first disassembly

```sh
make disasm          # == disasm/disasm.sh
```

This strips any `CART` header to `build/ballblazer.raw`, checks the size, and
runs `da65` with `disasm/ballblazer.info`, producing `build/ballblazer.s`.

The info file already knows:

- the 16K cartridge maps to `$8000–$BFFF`;
- the control block at `$BFFA–$BFFF` (run vector, present flag, options, init
  vector);
- the standard OS/hardware register names (so you read `sta STICK1`, not
  `sta $0279`).

Everything else starts as *code*. That is the raw material to refine.

## Step 3 — iterate: code vs. data

`da65` disassembles linearly, so it will mis-decode data (graphics, tables,
text, music) as instructions. Each pass:

1. Read `build/ballblazer.s`. Spot regions that are clearly data (long runs of
   nonsensical instructions, obvious bitmap/greyscale patterns, text).
2. Add a `RANGE { START $..; END $..; TYPE ByteTable; };` (or `WordTable`,
   `AddrTable`, `TextTable`) to `disasm/ballblazer.info`.
3. Name things you understand with `LABEL { NAME "..."; ADDR $..; };`.
4. `make disasm` again.

## Step 4 — prove it

```sh
make rebuild         # == disasm/rebuild.sh
```

Reassembles `build/ballblazer.s` with `ca65`/`ld65` and compares to
`build/ballblazer.raw`. Keep refining the info file until it prints
**IDENTICAL**. That pipeline is proven end-to-end (on a synthetic cart, so it
runs anywhere) by:

```sh
make selftest        # byte-identical round-trip, no ROM required
```

## Step 5 — find the three seams

With a clean listing, locate (see [`01-architecture.md`](01-architecture.md)):

- **Seam A — opponent AI/input hook.** In `atari800`'s monitor, break on reads
  of `RANDOM` (`$D20A`) and `STICK1` (`$0279`). The routine that consumes them
  to steer the second rotofoil is the droid AI. Label it; this is where the
  network opponent's state gets applied instead.
- **Seam B — state variables.** Use the emulator's memory watch while you glide
  around the grid: the bytes that change smoothly are your rotofoil's
  position/velocity; the one tracking the snap-to-target is heading. Do the same
  for the plasmorb. Label them and note them in `docs/04-netcode.md`'s mapping
  table.
- **Seam C — mode select + scoring.** Find the 1P/2P mode flag and the
  goal-scored / match-over routines.

Record every address you identify as `LABEL`s in `disasm/ballblazer.info` — that
file is tracked in git and becomes the shared map of the ROM. The generated
`build/ballblazer.s` is not tracked (it is a derivative of copyrighted code);
your **understanding** of it lives in the info file and in the patch sources.

## Useful `atari800` monitor commands

Launch with the monitor available and use, e.g.:

- `SHOW` — registers; `C` — continue; `S` — step.
- watchpoints on the addresses above to catch the AI and state reads.

## Emulator note

`atari800` (5.x) does not emulate a FujiNet `N:` device, so it can run the game
and the RE, but not the live link. Test networking with `tools/vpeer.py` against
real FujiNet hardware or a FujiNet-aware setup (see the README).
