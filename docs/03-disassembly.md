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

## Step 5 — find the three seams

For the **disk** build this is done; the shared map lives in
[`disasm/ballblazer-resident.info`](../disasm/ballblazer-resident.info) (run it
against your own `build/disk/ram_run.bin` — see that file's header). Rather than
a memory watch, the seams were pinned by **controlled input injection** in
`atari800` (`tools/drive_atari.py`): force a player's control gate onto the
joystick path, inject a stick direction, and keep the bytes whose delta reverses
sign — see [`docs/05-findings.md`](05-findings.md). Status:

- **Seam A — opponent AI/input hook.** ✅ Located. Per-player control selectors
  `$23DE`/`$33DE` (0 = joystick, ≠0 = droid), gates `$5F27`/`$5F64`, droid AI
  `$9A4A` (X=`$00`/`$14`), called at `$5F37`/`$5F74`. The remote player's
  `JSR $9A4A` (`$5F74`) is where network state is applied instead.
- **Seam B — state variables.** ✅ Rotofoils pinned. P1 fwd/back
  `$F1:$F2`/`$F4:$F5`/`$F8`, lateral `$12D1`; P2 fwd/back
  `$7E/$80/$8E/$90`, lateral `$FB`. ⏳ The **plasmorb** vars are not active in
  the title state (both selectors 0, no ball) — capture them from a real
  in-flight match and diff.
- **Seam C — mode select + scoring.** ◐ Partial. 1P/2P mode is encoded in the
  selectors themselves and set up around `$5E02–$5E91`; input reads are labelled
  (`$5DB7` keyboard, `$5DBD` console). ⏳ The **score vars** and **goal / match-
  over** routines still need an in-match capture (leads: a "first to 10"
  `CMP #$0A`, and the match countdown timer).

Every confirmed address is recorded as a `LABEL` in the tracked resident map, so
it becomes the shared understanding of the ROM. The generated listing
(`build/disk/resident.s`) is **not** tracked — it is a derivative of copyrighted
code; your understanding lives in the `.info` file and the patch sources.

## Useful `atari800` monitor commands

Launch with the monitor available and use, e.g.:

- `SHOW` — registers; `C` — continue; `S` — step.
- watchpoints on the addresses above to catch the AI and state reads.

## Emulator note

`atari800` (5.x) does not emulate a FujiNet `N:` device, so it can run the game
and the RE, but not the live link. Test networking with `tools/vpeer.py` against
real FujiNet hardware or a FujiNet-aware setup (see the README).
