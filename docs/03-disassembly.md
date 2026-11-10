# Disassembling Ballblazer (your own copy)

The goal of this phase is an **annotated, byte-exact** disassembly you can
modify and reassemble. "Byte-exact" is the objective correctness test: if the
reassembled image differs from your image by even one byte, you have not yet
correctly separated code from data.

No game image or disassembly is committed to this repo (see the `.gitignore` and
`LICENSE`). You do this locally on a copy you own. This project targets the
Atari 8-bit **`.atr` disk** release (Internet Archive "Regulation Certified"
dump); the cartridge path below is secondary.

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

## Step 5 — what the netplay patch needed to know

The patch does not need a full disassembly — lockstep only needs the places
where the simulation touches the outside world. Those are recorded as facts in
[`docs/04-findings.md`](04-findings.md), as equates in
`src/netplay/game.inc`, and as labels in
[`disasm/ballblazer-resident.info`](../disasm/ballblazer-resident.info) (run
`da65 -i` on it against your own `build/disk/ram_run.bin` for an annotated
local listing).

The generated listing (`build/disk/resident.s`) is **not** tracked — it is a
derivative of copyrighted code; the understanding lives in the `.info` file,
the findings and the patch sources.

## Working in the emulator

`tools/rig.py` wraps the stock `atari800` 5.0 for this kind of work:

```python
from rig import Rig
with Rig("rom/ballblazer.atr") as r:
    r.step(700)                    # exactly 700 frames
    r.step(8, start=True)          # START held for 8 frames -> a match begins
    r.step(120, joy0="U")          # player 1 pushes forward for two seconds
    r.shot("build/shots/x.png")    # what the screen looks like
    ram = r.dump()                 # all 64 KB
    r.until(0x4CBE)                # run to the next tick
    r.save("build/disk/match.a8s") # emulator save state
```

Input goes in through the emulator's `-playback` file (a pipe the rig feeds
frame by frame), so joysticks, triggers and console keys pass through the
emulated PIA/GTIA like real ones — no instruction patching. The stock monitor
has PC breakpoints (`BPC`) but no memory watchpoints or trace; to catch a
stray write, save a state every block, detect the change, restore, and step
tick by tick (that is how the damaged byte in `docs/04-findings.md` was found).

`atari800` does not emulate a FujiNet. The emulator tests therefore replace
the *wire* (two RAM mailboxes, or a cassette image standing in for the remote
machine); see `docs/06-playing.md` for what that does and does not prove.
