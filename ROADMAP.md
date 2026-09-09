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

## Phase 2 — Disassembly harness  `[x]` scaffolding / `(you)` on the real ROM
- [x] `da65` control file with Atari cart structure + OS/hardware labels
      (`disasm/ballblazer.info`).
- [x] Disassemble / rebuild drivers (`disasm/disasm.sh`, `disasm/rebuild.sh`).
- [x] Byte-identical round-trip **self-test** on a synthetic cart
      (`tools/selftest_roundtrip.sh`) — proves the methodology.
- [ ] `(you)` Run on your ROM; refine the info file until `make rebuild` says
      IDENTICAL.

## Phase 3 — Reverse-engineer the seams  `(you)`
- [ ] Seam A: locate the droid-AI / opponent-input hook (trace `RANDOM $D20A`,
      `STICK1 $0279`).
- [ ] Seam B: locate rotofoil position/velocity/heading and plasmorb
      position/possession; fill the mapping table in `docs/04-netcode.md`.
- [ ] Seam C: locate the 1P/2P mode flag and goal/match-over routines.

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
