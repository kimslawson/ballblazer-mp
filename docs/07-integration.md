# Integration recipe: from here to two Ataris playing

What's left to turn this repo into a playable network match, and how to do each
step. It assumes your own `rom/ballblazer.atr` locally, the toolchain
(`cc65 dasm atari800`), and — for the live link — a FujiNet (hardware) or a
`fujinet-pc` setup. Everything marked ✅ is already done and verified headlessly.

## What is already proven

- ✅ Netcode (transport contract, protocol, checksum, dead reckoning) — unit
  tested on `sim65` (`make test`).
- ✅ The three seams located and, for the rotofoils, pinned by controlled input
  (`disasm/ballblazer-resident.info`, `docs/05`).
- ✅ Integration patch built to a **667-byte blob** (`make patch`).
- ✅ The **actual** `netp_apply_remote` hooked into the game's VBI drives the
  opponent from the netcode's `rem_*` fields (emulator loopback).
- ✅ Latency understood analytically and by simulation (`docs/06`, `make sim`).

## Remaining work

### 1. Pin the plasmorb and score variables (needs one in-match capture)

Start a match once in a windowed `atari800` (the only human-in-the-loop step —
see `docs/05` "Match-start"), then, headless again:

```sh
tools/dump_ram.sh run rom/ballblazer.atr build/disk/a.bin 5
tools/dump_ram.sh run rom/ballblazer.atr build/disk/b.bin 6   # ball in flight
tools/scan_findings.py diff build/disk/a.bin build/disk/b.bin
```

The bytes that track the ball are the plasmorb X/Y; add them (and the score
vars, found the same way as a goal is scored) as `LABEL`s in
`disasm/ballblazer-resident.info` and to the `gameaddr.inc` table.

### 2. Finish the field mapping in `src/game/netpatch.s`

`netp_capture_local` / `netp_apply_remote` currently map the confirmed responder
clusters 1:1. Once the position/velocity/heading split is pinned (hold one
direction for ~8 frames and classify ramp vs plateau — `docs/05`), refine the
mapping so `loc_*`/`rem_*` carry true position + velocity, letting dead reckoning
work at full fidelity. Set the host to drive `ball_*`.

### 3. Choose the code's home and relocate

The blob needs ~667 bytes + a few BSS bytes + 2 ZP bytes (`ng_ptr`). Options,
in order of preference:

- **Reclaim the droid AI.** Net mode removes it; `$9A4A` and the seed code around
  `$5E24–$5E61` become free. Point `cfg/atari-inject.cfg`'s origin there.
- **Extra disk sectors.** The `.atr` has room; add sectors and a few bytes in the
  boot loader (`disasm/disk-boot.info` shows its SIO loop) to read the blob into
  a confirmed-free region.
- Find 2 free ZP bytes for `ng_ptr` (the only ZP the netcode needs) that the
  game leaves alone; update the `ZP` window in `cfg/atari-inject.cfg`.

### 4. Install the hooks (what `netp_install` does on real code)

Net mode is the manual's **regulation two-human game**: both designations HUMAN,
so both selectors `$23DE`/`$33DE` = 0 and the droid AI `$9A4A` is *never called*.
Therefore:

1. Keep the **VBI-exit wedge** at `$4CBB` (proven by `make hooktest`) as the
   hook: `netp_post` runs every frame, captures the local player into `loc_*`,
   `ng_tick`s, and overwrites the remote player's kinematics from `rem_*`. This
   is robust because it does not depend on which control path runs.
2. Leave both designations HUMAN; the remote player's local (right-joystick)
   input is simply ignored — the wedge is the authority for its state.
3. `ng_init`, then `net_open` the URL. Put the URL + role where `netp_install`
   reads them (a `linkcfg`-style include per machine, like the demo).

(The alternative "redirect `JSR $9A4A`" hook only applies if you instead run the
opponent as a **DROID** and want to reuse the game's integrator — not needed for
the two-human regulation game.)

### 5. Bring up the link incrementally

1. **One Atari vs PC.** Run `tools/vpeer.py --listen 5000 --host` on your
   computer and build/run the patched game as the client pointing at it. vpeer
   speaks the exact wire format, so you can confirm the opponent moves before you
   have two Ataris.
2. **Two Ataris.** One built/configured host, one client (host's LAN IP). Start a
   match on both.
3. Tune `SEND_EVERY` (`src/net/fujinet.inc`) and the dead-reckon smoothing per
   `docs/06`; confirm the FujiNet SIO per-op time on your hardware (the one
   number the headless work couldn't measure).

## Validation ladder (what proves what)

| level | how | status |
|---|---|---|
| protocol logic correct | `sim65` unit tests | ✅ `make test` |
| pipeline byte-exact | synthetic-cart round-trip | ✅ `make selftest` |
| seams correct | controlled-input correlation | ✅ `docs/05` |
| opponent-drive hook works in-game | emulator loopback (real code) | ✅ |
| netcode holds up under latency | link simulation | ✅ `make sim` |
| live `N:` transport | FujiNet / fujinet-pc | ⏳ hardware |
| full match feel | two Ataris | ⏳ hardware |
