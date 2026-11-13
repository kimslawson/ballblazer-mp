# Ballblazer-MP

**Head-to-head Ballblazer over the network, for Atari 8-bit + [FujiNet](https://fujinet.online).**

Two Ataris, two FujiNets, one game of Lucasfilm Games' *Ballblazer* (1985):
each player flies their own rotofoil on their own machine against the human
on the other one.

This repository holds the **original code and tooling** for that: a netplay
patch, the tool that applies it to your own disk image, and an emulator test
rig. It does **not** contain the game.

## Status

**Playable. First played over a real network between two emulators with
built-in FujiNets (an iPad and an iPhone); not yet run on real Ataris.**

- Two emulated Ataris running the patched disk play a full match in lockstep
  and stay bit-identical in every byte the simulation uses, under 30 % packet
  loss (`make nplock`).
- The production serial driver and the boot-time lobby run inside the live
  game in the emulator, with a cassette image playing the remote machine:
  every packet received, both roles (`make npserial`).
- What no emulator here can show is the FujiNet side (its *NetStream* mode is
  used as its firmware source describes it) and real POKEY timing. The first
  hardware test is one Atari against `tools/vpeer.py`; see
  [`docs/06-playing.md`](docs/06-playing.md).

## How it works, in one paragraph

Both machines run the *same* simulation, tick for tick, and exchange nothing
but joystick and key presses (**deterministic lockstep**). The game's whole
simulation is one routine called once per frame; the patch gates it so a tick
only runs when both players' inputs for it are known, feeds it those inputs
instead of the local hardware, and replaces POKEY's random numbers with a
seeded generator both sides share. There is only ever one game state, so the
ball, the score and every collision agree by construction. The link is
FujiNet's raw serial-to-UDP bridge at 2400 baud — slow on purpose, because
the game's display interrupts keep the CPU for 3.3 ms at a time. What a
player feels is a fixed input delay, which the lobby sets from the measured
round trip of the link.
[`docs/01-architecture.md`](docs/01-architecture.md) has the detail.

## Quick start

```sh
sudo apt-get install cc65 python3            # to build
make test                                    # checks that need no game image

cp /path/to/your/Ballblazer.atr rom/ballblazer.atr   # see rom/README.md
make disk                                    # -> build/ballblazer-net.atr

# optional: the emulator tests
sudo apt-get install atari800 xvfb imagemagick python3-pil
make nptest
```

Boot `ballblazer-net.atr` from both FujiNets, type each other's address, one
player answers **H**, the other **J**. Full instructions and troubleshooting:
[`docs/06-playing.md`](docs/06-playing.md).

## Requirements

- Atari 400/800 with 48K, or any XL/XE; NTSC or PAL (PAL untested).
- FujiNet firmware v1.6.0 or later (the first release with NetStream).
- The supported disk image — one specific dump, checked by checksum
  ([`rom/README.md`](rom/README.md)).

## Legal / scope

*Ballblazer* is copyrighted by Lucasfilm Games / Atari and their successors.
This project neither includes nor distributes the game or a disassembly of
it. The code here (MIT — see `LICENSE`) is original. The docs record
addresses and behaviour, not code. The disk you build contains your game and
stays with you, as do RAM dumps and local listings (`.gitignore` enforces it).

## Layout

```
src/netplay/   resident.s  the part that stays in memory: tick gate, inputs,
                           PRNG, serial driver, protocol, sound mixing
               lobby.s     boot-time front end: FujiNet set-up, handshake,
                           the RAM patch table
               game.inc    the game addresses the patch relies on
               hw.inc      Atari hardware equates
cfg/           netplay.cfg (ld65), plus the disassembly harness configs
tools/         mkdisk.py   build the netplay disk from your image
               vpeer.py    a PC stand-in for the second Atari (UDP)
               npproto.py  the link protocol in Python (reference)
               rig.py      scriptable atari800: frame-exact input, monitor,
                           screenshots
               atr.py, dump_ram.sh, scan_findings.py, mkfakecart.py, ...
tests/         nplink.py   two linked emulators (harness)
               np_soak.py  lockstep soak with memory comparison
               np_serial.py  serial driver + lobby against a "tape" peer
disasm/        da65 control files and scripts (boot loader, label map)
docs/          01 architecture · 02 link · 03 disassembly · 04 findings ·
               05 timing · 06 playing
rom/           (git-ignored) your own .atr goes here
ROADMAP.md     status and what is left
```

## Credits & references

- FujiNet — <https://fujinet.online>; NetStream as implemented in
  [fujinet-firmware](https://github.com/FujiNetWIFI/fujinet-firmware).
- Built with the [cc65](https://cc65.github.io/) suite and
  [atari800](https://atari800.github.io/).
