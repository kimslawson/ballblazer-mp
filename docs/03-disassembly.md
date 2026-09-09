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

## Two image types

Ballblazer exists as both a **disk** (`.atr`) and a **cartridge** (`.rom`). Most
dumps — including the Internet Archive "k_file" — are disks. `disasm/disasm.sh`
auto-detects which you have.

- **Disk (`.atr`)** — a custom-boot disk (no DOS). The OS loads a 3-sector boot
  loader to `$0700` and runs it; that loader programs an SIO control block at
  `$0300–$030B` and calls `SIOV` (`$E459`) to read the rest of the game from
  disk, then hands off with `JMP (RUNAD)` (`$02E0`). See the **Disk version**
  steps below.
- **Cartridge (`.rom`)** — a 16K image mapped at `$8000–$BFFF` with a control
  block at `$BFFA`. See the **Cartridge version** steps further down.

## Step 1 — place your image

Put your own copy at `rom/ballblazer.atr` (disk) or `rom/ballblazer.rom` (cart).
See `rom/README.md`. It is git-ignored and stays on your machine.

---

## Disk version

### D1 — unpack + disassemble the loader

```sh
make disasm            # detects the .atr, runs tools/atr.py, da65 the loader
```

This writes `build/disk/sectors.img` (all sector bytes) and `build/disk/boot.bin`
(the 384-byte loader), then disassembles the loader with
`disasm/disk-boot.info` to `build/disk/boot.s`.

```sh
make rebuild           # reassemble boot.s -> byte-identical to boot.bin
```

When that says **IDENTICAL**, your loader disassembly is faithful.

### D2 — follow the loader to map the segments

Read `build/disk/boot.s`. Trace how it fills the SIO DCB (`DAUX1/DAUX2` = sector
number, `DBUFLO/HI` = destination, `DBYTLO/HI` = length) and loops `SIOV` to pull
sector groups into RAM. Each group's destination address tells you where a chunk
of the game lands. Record those addresses as `LABEL`/`RANGE` entries in
`disasm/disk-boot.info` (or a new per-segment info file).

### D3 — get the whole resident game (recommended: memory dump)

Statically following a multi-segment SIO loader is tedious, and some loaders
relocate or decompress. The pragmatic route is dynamic:

1. Boot the disk in `atari800` and let the game load to its title/menu.
2. Drop into the built-in monitor and save RAM to a file (e.g. dump the main
   RAM range `$0700–$BFFF` — adjust once D2 tells you the real extents).
3. Disassemble that dump at its true origin with a new `.info` file, and iterate
   code/data ranges exactly as in the cartridge steps below.

The dumped image is the *actual* code executing, so the seam hunt in Step 5
happens against it. (Keep the dump local — it is derived from copyrighted code.)

---

## Cartridge version

### Step 1c — place your ROM

Put your 16K Ballblazer cartridge dump at `rom/ballblazer.rom` (a `CART`-headered
dump is fine — the header is stripped automatically).

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
