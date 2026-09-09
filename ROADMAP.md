# Roadmap

Turning single-player Ballblazer (Atari 8-bit) into a two-machine FujiNet
network match. This is the living plan and status board.

Legend: `[x]` done & verified · `[~]` in progress · `[ ]` not started · `(you)`
needs your own legally-owned ROM.

## Phase 0 — Foundation & tooling  `[x]`
- [x] Project scaffold, build orchestration (`Makefile`), CI entry point
      (`tools/run_tests.sh`).
- [x] Toolchain pinned: cc65 (`ca65`/`ld65`/`da65`/`sim65`) + `dasm` + `atari800`.
- [x] `.gitignore` / `LICENSE` establishing the ROM copyright boundary.

## Phase 1 — FujiNet networking layer  `[x]`
- [x] Low-level `N:` CIO wrapper — OPEN/CLOSE/STATUS/GET/PUT, all non-blocking
      (`src/net/ncio.s`).
- [x] Link protocol: 16-byte packet, checksum, non-blocking drain, dead
      reckoning, host/client ball authority (`src/net/netgame.s`).
- [x] Executable unit tests on `sim65` — 24 assertions, all passing
      (`tests/test_netgame.s`).
- [x] Standalone, bootable link demo `.xex` (host + client)
      (`src/demo/netdemo.s`).
- [x] PC-side virtual opponent + wire-format spec (`tools/vpeer.py`).

## Phase 2 — Disassembly harness  `[x]` scaffolding / `(you)` on the full game
- [x] ATR parser (`tools/atr.py`) — reads the boot record, unpacks sectors.
- [x] **Disk image analyzed**: custom-boot `.atr`, 128-byte sectors, 276
      sectors; 3-sector loader → `$0700`, exec `$0706`, init `$0714`; SIO reads
      the game and hands off via `JMP (RUNAD)`.
- [x] `da65` control files: disk boot loader (`disasm/disk-boot.info`) and 16K
      cart (`disasm/ballblazer.info`), with SIO/DCB + OS/hardware labels.
- [x] Auto-detecting disasm / rebuild drivers (`disasm/disasm.sh`,
      `disasm/rebuild.sh`) for both disk and cart.
- [x] **Boot loader disassembly verified byte-identical** on the real disk
      (round-trip), and a synthetic-cart self-test proves the pipeline in CI.
- [ ] `(you)` Map the SIO-loaded segments (follow the loader, or dump RAM from
      atari800), then disassemble the resident game and refine the info files
      until `make rebuild` stays IDENTICAL.

## Phase 3 — Reverse-engineer the seams  `[~]` (headless RAM-dump analysis)
- [x] Headless capture path: `atari800` (SDL dummy) monitor dumps via
      `tools/dump_ram.sh`; seam scanner `tools/scan_findings.py`. Findings in
      `docs/05-findings.md`.
- [x] Memory map established: engine resident `$4000–$BFFF`; main loop `$4C72`.
- [x] Seam A located: per-player input at `$5F3D`/`$5F7A` (+ triggers
      `$5F46`/`$5F85`); droid-AI PRNG cluster `$5E24–$5E61`.
- [x] Seam C located: menu console read at `$5DBD` (`CONSOL`).
- [~] Seam B: zero-page candidates found (`$00B5,$00F1,$00F4,$00F7…`); still
      need to **pin** rotofoil/ball vars with in-game motion diffs.
- [x] Free RAM for injection identified (page 6, `$094A–$0B3D`, reclaimable AI).

## Phase 4 — Integration  `(you, with this repo's code)`
- [ ] Add a "network match" mode: `ng_init` + open `N:`, force two-rotofoil
      rendering.
- [ ] Seam A: write `rem_*` into the opponent-rotofoil variables each frame in
      place of the droid output.
- [ ] Seam B: host drives `ball_*`; client renders from `ball_*`.
- [ ] Copy the game's real vars in/out around `ng_tick`; calibrate the
      fixed-point velocity scale (see docs/04 "one tuning knob").
- [ ] Route goals/possession through the packet event field.

## Phase 5 — Hardening & play  `(you)`
- [ ] Connection UI / lobby (enter host IP; or a small relay for internet play).
- [ ] Loss/latency polish: seq-ordering, easing instead of hard snap, jitter
      buffer sizing.
- [ ] Disconnect detection + pause/resume.
- [ ] Playtest on real Ataris + FujiNet; tune send rate and dead-reckoning.

## Known unknowns / risks
- Exact Ballblazer coordinate units (resolved at Seam B; scaling is a knob).
- FujiNet UDP transmit-destination SPECIAL command number varies by firmware —
  confirm against current FujiNet NOS docs (see `docs/02`).
- Free ROM/RAM budget for the added code (the net layer is small — ~0.5 KB — but
  measure once integrated).
- Internet (vs. LAN) play needs port-forwarding or a relay.
