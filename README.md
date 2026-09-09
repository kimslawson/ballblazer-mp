# Ballblazer-MP

**Head-to-head Ballblazer over the network, for Atari 8-bit + [FujiNet](https://fujinet.online).**

An effort to disassemble Lucasfilm Games' *Ballblazer* (1985, Atari 8-bit) and
replace the single-player droid AI with a **real human opponent on another
machine**, linked through FujiNet's `N:` network device — two Ataris, one grid
plain.

This repository contains the **original code and tooling** for that project: a
complete, tested FujiNet networking layer, a runnable link demo, a disassembly
harness, and a reverse-engineering map of the game's integration points. It does
**not** contain the game itself — you supply your own copy (see below).

## The image this targets

All reverse engineering here is against the **Atari 8-bit disk image (`.atr`)**
of Ballblazer — the "Regulation Certified" dump distributed on the Internet
Archive. Concretely it is a **single-density, 128-byte-sector, custom-boot
disk** (no DOS): a 3-sector loader at `$0700` SIO-loads the game into
`$4000–$BFFF` and starts it via `RUNAD`. It is **not** the cartridge release;
the tooling can still handle a 16K cart dump, but that is a secondary path and
the disassembly map (`disasm/ballblazer-resident.info`) describes the disk.

## Legal / scope

*Ballblazer* is copyrighted by Lucasfilm Games / Atari and their successors.
This project neither includes nor distributes the disk image or any disassembly
of it. The code here (MIT — see `LICENSE`) is original: it does networking and
provides tools you point at a copy **you legally own**. The image, RAM dumps,
and any generated disassembly stay on your machine (`.gitignore` enforces this).

## What works today (all verified headlessly — `make test`, no image needed)

- **FujiNet `N:` networking layer** (`src/net/`) — non-blocking CIO wrappers and
  a 16-byte state-exchange protocol with checksum, packet drain, dead reckoning,
  and host/client ball authority. Logic **executed and asserted** on the `sim65`
  6502 simulator (24 checks).
- **Bootable link demo** (`src/demo/netdemo.s`) — a standalone `.xex` (host and
  client builds) proving the whole `N:` path independently of the game.
- **Disassembly harness** — `make selftest` disassembles a synthetic 16K image
  and reassembles it **byte-identically**, proving the da65→ca65 pipeline; the
  real disk's boot loader also round-trips byte-identically.
- **Reverse-engineering map** (`disasm/ballblazer-resident.info`) — the three
  integration seams, pinned by controlled-input analysis in `atari800`
  (`docs/05-findings.md`): the opponent-AI control seam, both rotofoils' state
  variables, and the mode encoding.
- **Integration patch** (`src/game/netpatch.s`, 667-byte blob) — wires the
  netcode into the control seam; the opponent-drive hook is **proven in the real
  running game** via an emulator loopback.
- **Latency study** (`docs/06-latency.md`) — measured netcode CPU cost (<2.5% of
  a frame) plus a link simulation (`tools/netsim.py`).
- **Virtual opponent** (`tools/vpeer.py`) — a PC program speaking the exact wire
  protocol, to test one real Atari against your computer.

## What still needs a real device / a human at the emulator

The live `N:` transport (needs FujiNet hardware or `fujinet-pc`), and pinning the
**plasmorb** and **score/goal** variables — which require an in-flight match,
i.e. one keypress to start a game in a windowed `atari800`, then the automated
`dump_ram.sh` + `scan_findings.py` tools. See `docs/05-findings.md`.

## Quick start

```sh
sudo apt-get install cc65 dasm atari800      # toolchain

make test          # prove the netcode, pipeline, and patch all build/pass
make demo          # build/netdemo-{host,client}.xex (edit src/demo/linkcfg.inc)
make bench         # netcode CPU cost, in cycles
python3 tools/netsim.py                       # simulate the link latency/loss
```

On your own disk image (git-ignored; stays local):

```sh
cp /path/to/Ballblazer.atr rom/ballblazer.atr
make disasm        # unpack ATR + da65 the boot loader
make rebuild       # verify the loader disassembly is byte-identical
make dump-run      # capture the resident game to build/disk/ram_run.bin
make findings      # memory map + input/AI seam scan
# annotated listing with the RE map:
da65 -i disasm/ballblazer-resident.info       # -> build/disk/resident.s (local)
```

(If you instead have a **16K cartridge** dump, drop it as `rom/ballblazer.rom`;
`make disasm` auto-detects it and uses `disasm/ballblazer.info` + `cart16k.cfg`.)

## Layout

```
src/net/     ncio.s (N: CIO wrapper), netgame.s (protocol), *.inc (equates)
src/demo/    netdemo.s (bootable link PoC), linkcfg.inc (host IP / role)
src/game/    netpatch.s (integration glue), gameaddr.inc (confirmed addresses)
tests/       test_netgame.s (sim65 unit tests), bench_netgame.s, fakecart.info
tools/       atr.py, dump_ram.sh, drive_atari.py, scan_findings.py, vpeer.py,
             netsim.py, xex.py, mkfakecart.py, run_tests.sh, selftest_roundtrip.sh
disasm/      disk-boot.info + disk-boot.cfg   (the .atr boot loader)
             ballblazer-resident.info         (the resident game RE map)
             ballblazer.info + cart16k.cfg    (secondary: 16K cart path)
             disasm.sh, rebuild.sh            (auto-detect disk vs cart)
cfg/         atari-xex.cfg (demo), atari-inject.cfg (patch)
docs/        01 architecture · 02 FujiNet N: · 03 disassembly ·
             04 netcode · 05 findings · 06 latency
rom/         (git-ignored) your own .atr goes here
ROADMAP.md   phased plan + status
```

## How it plays

Each machine runs its own rotofoil at full speed from its local joystick (zero
input lag) and streams that craft's state to the other; each mirrors the remote
craft and smooths its motion between packets (dead reckoning). One machine (the
host) owns the shared plasmorb so the two views never disagree about the ball or
the score. Standard low-latency action-game netcode, sized for a 6502 and a
fixed 16-byte packet. Rationale in [`docs/04-netcode.md`](docs/04-netcode.md);
latency in [`docs/06-latency.md`](docs/06-latency.md).

## Status

Phases 0–3 complete (netcode, tooling, disassembly, and the three seams);
Phase 4 (integration) in progress — patch written and the hook proven in-game;
remaining work is the live transport and the in-match variables. See
[`ROADMAP.md`](ROADMAP.md).

## Credits & references

- FujiNet and its `N:` "Network-Only DOS" — <https://fujinet.online>.
- Built with the [cc65](https://cc65.github.io/) suite and
  [atari800](https://atari800.github.io/).
