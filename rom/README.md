# rom/ — put your own Ballblazer disk image here

This directory is where **you** place a Ballblazer copy you legally own. It is
deliberately **git-ignored**: the game is copyrighted (Lucasfilm Games / Atari)
and must not be committed or shared. Nothing you put here leaves your machine.

## The supported image

**`ballblazer.atr`** — the Atari 8-bit "Regulation Certified" disk image:

- 35,344 bytes (16-byte header + 276 sectors of 128 bytes)
- md5 `a37afb54b6edbd03c348efa0b714d37c`

`tools/mkdisk.py` checks the md5, and the lobby checks a checksum of the game
in memory before it patches anything: the patch is a list of addresses, and
they are only right for this dump. Other dumps of the same release (the
Internet Archive also has an "[a]" alternate) are refused.

Structurally it is three boot sectors holding a small binary-file loader,
followed by one ordinary Atari binary-load stream (`docs/04-findings.md`).

## Then

```sh
make disk        # build/ballblazer-net.atr - the netplay disk
make nptest      # the emulator tests (optional)
make disasm      # unpack + disassemble the boot loader (reverse engineering)
make dump-run    # capture the running game -> build/disk/ram_run.bin
```

(If you have a 16K **cartridge** dump instead, `rom/ballblazer.rom` still works
with the disassembly harness, but the netplay patch does not support it.)
