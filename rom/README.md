# rom/ — put your own Ballblazer disk image here

This directory is where **you** place a Ballblazer copy you legally own, so the
disassembly tools can read it. It is deliberately **git-ignored**: the game is
copyrighted (Lucasfilm Games / Atari) and must not be committed or shared.

## What to drop here

- **`ballblazer.atr`** — the Atari 8-bit **disk image** this project targets
  (the "Regulation Certified" dump on the Internet Archive). It is a
  single-density, 128-byte-sector, **custom-boot** disk: a 3-sector loader at
  `$0700` SIO-loads the game into `$4000–$BFFF` and starts it via `RUNAD`.
  `disasm/disasm.sh` detects the ATR (magic `96 02`), unpacks it with
  `tools/atr.py`, and disassembles the boot loader.

Secondary (only if you happen to have the cartridge release instead):

- `ballblazer.rom` — a 16K **cartridge** image (raw 16384 bytes, or with a
  16-byte `CART` header, magic `43 41 52 54`, stripped automatically). Handled
  by `disasm/ballblazer.info` + `cart16k.cfg`.

`disasm/disasm.sh` auto-detects which you have and picks the right workflow.

## Then

```sh
make disasm      # unpack + da65 the boot loader (disk) or the cart image
make rebuild     # reassemble and prove it is byte-identical
make dump-run    # capture the resident game (disk) -> build/disk/ram_run.bin
```

Nothing you put here leaves your machine.
