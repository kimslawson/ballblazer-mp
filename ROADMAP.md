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

## Phase 3 — Reverse-engineer the seams  `[x]` (headless dump + controlled input)
- [x] Headless capture path: `atari800` (SDL dummy) monitor dumps via
      `tools/dump_ram.sh` / `tools/drive_atari.py`; scanner `tools/scan_findings.py`.
- [x] Memory map established: engine resident `$4000–$BFFF`; VBI `$4CAB` runs the
      logic while the main PC idles at `$4C72`.
- [x] Seam A **fully located**: per-player control selectors `$23DE` (P1) /
      `$33DE` (P2), gates `$5F27` / `$5F64`; joystick reads `$5F3D`/`$5F7A`;
      **droid AI entry `$9A4A`** (X=`$00`/`$14`) — the remote player's `JSR $9A4A`
      is the primary net hook.
- [x] Seam C located: menu console read `$5DBD`; keyboard `$5DB7`.
- [x] Seam B **pinned by controlled input** (force gate + inject stick, keep
      sign-reversing bytes): P1 fwd/back `$F1:$F2,$F4:$F5,$F8`, lateral `$12D1`;
      P2 fwd/back `$7E/$80/$8E/$90/$A5–$AD`, lateral `$FB`. Remaining: ball vars,
      position-vs-velocity split. See docs/05.
- [x] Free RAM for injection identified (page 6, `$094A–$0B3D`, reclaimable AI).

## Phase 4 — Integration  `[~]` in progress
- [x] Integration patch written (`src/game/netpatch.s` + `gameaddr.inc`):
      net-match install, VBI-exit wedge, capture-local / apply-remote. Builds to
      a **667-byte** blob (`make patch`), continuously checked in `make test`.
- [x] **Hook proven in the real running game** (emulator loopback): a VBI-exit
      wedge driving player 2's kinematics from an injected "received" buffer —
      P2 vars took the injected values ($80/$8E/$FB). This is the netcode's
      apply-remote path minus the live `N:` transport.
- [x] Netcode CPU cost measured (`make bench`): ~80/347/347 cyc — <2.5% of a
      frame. Latency analysis in `docs/06-latency.md`.
- [ ] Refine the var mapping (position/velocity/heading split) and the
      capture/apply field wiring in `netpatch.s`.
- [ ] Ball authority: host drives `ball_*`; pin the ball variables.
- [ ] Live `N:` transport on hardware / `fujinet-pc`; route goals/possession
      through the packet event field; calibrate the fixed-point scale.

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
