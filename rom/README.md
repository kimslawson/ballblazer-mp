# rom/ — put your own Ballblazer cartridge dump here

This directory is where **you** place a Ballblazer ROM you legally own, so the
disassembly tools can read it. It is deliberately **git-ignored**: the ROM is
copyrighted (Lucasfilm Games / Atari) and must not be committed or shared.

## What to drop here

Either form of a copy you own:

- `ballblazer.atr` — an Atari **disk** image (what most Ballblazer dumps are,
  including the Internet Archive "k_file"). This is a custom-boot disk: a
  3-sector loader at `$0700` that SIO-loads the game and jumps via `RUNAD`.
  `disasm/disasm.sh` detects the ATR (magic `96 02`), unpacks it with
  `tools/atr.py`, and disassembles the boot loader.
- `ballblazer.rom` — a 16K **cartridge** image (raw 16384 bytes, or with a
  16-byte `CART` header, magic `43 41 52 54`, which is stripped automatically).

`disasm/disasm.sh` auto-detects which you have and picks the right workflow.

## Then

```sh
make disasm     # da65 -> build/ballblazer.s   (see docs/03-disassembly.md)
make rebuild    # reassemble and prove it is byte-identical to your ROM
```

Nothing you put here leaves your machine.
