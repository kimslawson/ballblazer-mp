# Ballblazer-MP

**Head-to-head Ballblazer over the network, for Atari 8-bit + [FujiNet](https://fujinet.online).**

An effort to disassemble Lucasfilm Games' *Ballblazer* (1985, Atari 8-bit) and
replace the single-player droid AI with a **real human opponent on another
machine**, linked through FujiNet's `N:` network device — two Ataris, one grid
plain.

This repository contains the **original code and tooling** for that project: a
complete, tested FujiNet networking layer, a runnable link demo, and a
disassembly harness. It does **not** contain the game ROM — you supply your own
(see below).

---

## Legal / scope

*Ballblazer* is copyrighted by Lucasfilm Games / Atari and their successors.
This project neither includes nor distributes the ROM or any disassembly of it.
The code here (MIT-licensed — see `LICENSE`) is original: it does networking and
provides tools you point at a copy **you legally own**. The ROM and any
generated disassembly stay on your machine (`.gitignore` enforces this).

## What works today (verified in CI)

Run everything with **`make test`** — no ROM required:

- **FujiNet `N:` networking layer** (`src/net/`) — non-blocking CIO wrappers and
  a 16-byte state-exchange protocol with checksum, packet drain, dead reckoning,
  and host/client ball authority. Logic is **executed and asserted** on the
  `sim65` 6502 simulator (24 checks).
- **Bootable link demo** (`src/demo/netdemo.s`) — a standalone `.xex` (built in
  host and client flavours) that opens the link, moves a rotofoil from the
  joystick, exchanges state, and shows the link live. Proves the whole network
  path independently of the game.
- **Disassembly round-trip** — `make selftest` disassembles a synthetic cart and
  reassembles it to a **byte-identical** image, proving the RE workflow before
  you use it on the real ROM.
- **Virtual opponent** (`tools/vpeer.py`) — a PC program that speaks the exact
  wire protocol, so you can test one real Atari against your computer.

## What needs your ROM (documented, deferred to you)

Disassembling the cartridge and finding three "seams" — the opponent-AI input
hook, the rotofoil/ball state variables, and the mode/scoring routines — then
wiring the (already-written) network state into them. The netcode does not
change for this; it is wiring against a defined contract. Full procedure in
[`docs/`](docs/).

## Quick start

```sh
# 1. tools (Debian/Ubuntu)
sudo apt-get install cc65 dasm atari800

# 2. prove everything builds and the protocol is correct
make test

# 3. build the FujiNet link demo (two .xex files)
make demo
#    -> build/netdemo-host.xex   (run on machine A; listens on UDP 5000)
#    -> build/netdemo-client.xex (run on machine B; edit the host IP in
#                                  src/demo/linkcfg.inc first)

# 4. test the link without a second Atari:
#    on your PC:            tools/vpeer.py --listen 5000 --host
#    build the demo as CLIENT pointing at your PC's IP, run it on the Atari.
#    Each side should see the other's position move (HUD line + green heartbeat).
```

Then, on your own copy (disk `.atr` or cart `.rom` — auto-detected):

```sh
cp /path/to/your/ballblazer.atr rom/ballblazer.atr   # disk (most common)
make disasm        # unpack ATR + da65 the boot loader (build/disk/boot.s)
make rebuild       # verify the loader is byte-identical, then start the RE
```

The disk is a custom-boot image: a 3-sector loader at `$0700` SIO-loads the
game and jumps via `RUNAD`. Mapping the loaded segments (or dumping RAM from
`atari800`) is the next step — see [`docs/03-disassembly.md`](docs/03-disassembly.md).

## Layout

```
src/net/       ncio.s (N: CIO wrapper), netgame.s (protocol), *.inc (equates)
src/demo/      netdemo.s (bootable link PoC), linkcfg.inc (host IP / role)
tests/         test_netgame.s (sim65 unit tests), fakecart.info
tools/         xex.py, vpeer.py, mkfakecart.py, run_tests.sh, selftest_roundtrip.sh
disasm/        ballblazer.info (da65 control file), disasm.sh, rebuild.sh, cart16k.cfg
cfg/           atari-xex.cfg (demo link config)
docs/          01 architecture · 02 FujiNet N: · 03 disassembly · 04 netcode
rom/           (git-ignored) drop your own ROM here
ROADMAP.md     phased plan + status
```

## How it will play

Each machine runs its own rotofoil at full speed from its local joystick (zero
input lag) and streams that craft's state to the other; each mirrors the remote
craft and smooths its motion between packets (dead reckoning). One machine (the
host) owns the shared plasmorb so the two views never disagree about the ball or
the score. This is the standard low-latency action-game model, sized for a 6502
and a fixed 16-byte packet. Rationale and the exact packet in
[`docs/04-netcode.md`](docs/04-netcode.md).

## Status

Phases 0–1 complete and tested; Phase 2 tooling complete (self-test passing);
Phases 2-on-your-ROM through 5 are the reverse-engineering and integration work,
laid out in [`ROADMAP.md`](ROADMAP.md).

## Credits & references

- FujiNet and its `N:` "Network-Only DOS" — <https://fujinet.online>.
- Built with the [cc65](https://cc65.github.io/) suite and
  [atari800](https://atari800.github.io/).
