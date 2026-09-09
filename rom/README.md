# rom/ — put your own Ballblazer cartridge dump here

This directory is where **you** place a Ballblazer ROM you legally own, so the
disassembly tools can read it. It is deliberately **git-ignored**: the ROM is
copyrighted (Lucasfilm Games / Atari) and must not be committed or shared.

## What to drop here

- `ballblazer.rom` — a 16K Atari 8-bit Ballblazer cartridge image.

The tools accept either a raw 16384-byte image or a dump with a 16-byte
Atari `CART` header (magic `43 41 52 54`); `disasm/disasm.sh` detects the
header and strips it automatically into `build/ballblazer.raw`.

## Then

```sh
make disasm     # da65 -> build/ballblazer.s   (see docs/03-disassembly.md)
make rebuild    # reassemble and prove it is byte-identical to your ROM
```

Nothing you put here leaves your machine.
