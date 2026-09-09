# Netcode design

The link protocol is fully implemented in `src/net/netgame.s` and
`src/net/ncio.s` and tested (`tests/test_netgame.s`, run under `sim65`). This
document explains *why* it works the way it does, so the Phase-3 integration
maps the game's variables onto it correctly.

## Why not lockstep

The obvious retro approach is deterministic **input lockstep**: exchange
joystick bytes each frame, simulate identically on both machines. It is tiny on
the wire and perfectly consistent — but it forces every machine to stall until
the *other* machine's input for frame N arrives. Over a FujiNet link, one
round-trip is many frames of a 60 Hz game, so lockstep either drops the frame
rate to the network rate or needs an input-delay buffer that makes a fast
momentum game feel like driving in syrup. Rollback (the modern fix) is not
realistic on a 6502 in the remaining ROM budget.

## The model we use: local authority + dead reckoning

Each endpoint is **authoritative over its own rotofoil** and simulates it from
the local joystick with **zero added latency** — so your own craft always feels
native. It periodically transmits that craft's true state; the peer mirrors it
and **extrapolates between updates** from the last known velocity ("dead
reckoning"), so the remote craft moves smoothly at 60 Hz even though packets
arrive at ~20 Hz. When a fresh packet lands, the mirror snaps (or, later, eases)
to the new truth.

This decouples *responsiveness* (local, instant) from *network latency* (only
the remote craft is ever slightly behind — exactly the tolerable case).

```
   local craft:   joystick ─► stock physics ─► render   (0 frames behind)
   remote craft:  packet ─► rem_* ─► dead-reckon each frame ─► render
                  ▲                                   ▲
                  └── snap to truth on arrival ───────┘  (≈ RTT/2 behind)
```

## The plasmorb needs one authority

Two machines cannot both own the ball or they will disagree about possession and
goals. So exactly one endpoint — the **host** (`FLAG_HOST`) — simulates the
plasmorb physics and scoring and broadcasts `ball_*`. The client renders the
ball from received state (and may predict between packets). `ng_apply_rx`
enforces this: it accepts `ball_*` **only** from a packet whose sender has
`FLAG_HOST` set. Possession changes and goals travel in the packet's event field
so both sides stay consistent; the host's view is the tiebreaker.

## The wire packet (16 bytes, fixed)

Fixed size means no framing or parsing: STATUS tells us bytes-waiting, we GET
whole `PKT_LEN` multiples, newest wins. Layout (see `fujinet.inc`):

| off | field       | meaning                                             |
|-----|-------------|-----------------------------------------------------|
| 0   | `MAGIC`     | `$B1` = protocol id + version 1                     |
| 1   | `SEQ`       | sender frame sequence (wraps 0–255)                 |
| 2   | `ACK`       | highest peer seq applied (loss/RTT stats)           |
| 3   | `FLAGS`     | host / have-ball / goal / start / end / pause / fire / hello |
| 4–5 | `RFX,RFXF`  | rotofoil X, 8.8 fixed point                         |
| 6–7 | `RFY,RFYF`  | rotofoil Y, 8.8 fixed point                         |
| 8   | `RFVX`      | rotofoil velocity X, signed 8-bit                   |
| 9   | `RFVY`      | rotofoil velocity Y, signed 8-bit                   |
| 10  | `RFHDG`     | heading, 0–255 = 0–360°                             |
| 11  | `BALLX`     | plasmorb X (authoritative from host)                |
| 12  | `BALLY`     | plasmorb Y                                          |
| 13  | `BALLST`    | ball state: bit7 in-flight, bits0–1 possessor       |
| 14  | `EVENT`     | goal side<<4 \| points, else 0                      |
| 15  | `CSUM`      | XOR of bytes 0–14                                   |

At 20 Hz that is ~320 B/s each way — trivial for FujiNet, and small enough that
the per-packet CIO cost stays negligible in the frame budget.

## The shared-state struct (the integration contract)

`netgame.s` owns these bytes; Phase-3 integration copies the game's real
variables in/out around `ng_tick`. **This is the entire integration surface.**

| netgame field           | write when          | read for               |
|-------------------------|---------------------|------------------------|
| `loc_xi/xf,yi/yf`       | before `ng_tick`    | (sent)                 |
| `loc_vx,loc_vy,loc_hdg` | before `ng_tick`    | (sent)                 |
| `loc_flags`             | set once (host bit) | (sent)                 |
| `loc_event`             | on local goal/fire  | (sent), then clear     |
| `rem_xi/xf,yi/yf,v*,hdg`| by `ng_tick`        | drive opponent rotofoil (**Seam A/B**) |
| `ball_x,ball_y,ball_st` | host sets; `ng_tick`| render ball (**Seam B**)|

Concrete addresses pinned on the disk image (see `docs/05-findings.md`;
disk-specific, verify against your build). Kinematics respond to controlled
joystick input via the control seam:

```
; --- control seam (primary hook) ---
; player-1 control selector   $23DE  (0=joystick, !=0=droid AI)   gate @ $5F27
; player-2 control selector   $33DE  (0=joystick, !=0=droid AI)   gate @ $5F64
; droid AI entry              $9A4A  (X=$00 P1, X=$14 P2)  <- redirect for remote
;
; --- player-1 rotofoil kinematics (forced-input confirmed) ---
; fwd/back (vertical) 16-bit  $F1:$F2 , $F4:$F5 , $F8 , $D6 , $D8
; lateral (left/right)        $12D1 (clean +/-8) , $089A
;
; --- player-2 rotofoil kinematics ---
; fwd/back                    $7E,$80,$8E,$90,$A5..$AD,$B2 , $F8
; lateral                     $FB (clean +/-8)
;
; --- still to pin ---
; ball_x / ball_y / possession   (host simulates a match; diff while in flight)
; exact position-vs-velocity split within each cluster
```

Map `rem_*` onto the *remote* player's cluster and `loc_*` onto the local
player's; the host also owns `ball_*`. The recommended hook redirects the remote
player's `JSR $9A4A` to apply `rem_*`, then hard-corrects the cluster from `rem_*`
every few frames to bound drift.

## Coordinate scaling — the one tuning knob

Position is 16-bit 8.8 fixed point; velocity is signed 8-bit "sub-units per
frame," sign-extended into the high byte during dead reckoning (verified by the
negative-velocity + borrow test). Ballblazer's internal coordinate units are
unknown until Seam B is found, so treat the fixed-point scale as a **calibration
constant**: once you know how many internal units the craft moves per frame,
scale `loc_v*`/`rem_v*` so the dead-reckoned remote position matches the
authoritative one at the next packet. Start 1:1 and adjust.

## Loss, ordering, and stale packets

- **Loss:** each packet is a full snapshot, so a dropped one costs one stale
  tick; dead reckoning covers the gap.
- **Reordering:** `SEQ` lets you ignore a packet older than the newest applied
  (an easy hardening step; the current drain simply keeps the last one read).
- **Disconnect:** `DVSTAT` connection status (`$02EC`) going to 0, or a long
  gap in inbound `SEQ`, signals a dropped link — surface it and pause.

## What is proven today

`tests/test_netgame.s` executes on `sim65` and asserts: packet build fills every
field, checksum is correct and self-consistent, a valid packet round-trips into
`rem_*` and raises `link_up`, a corrupted checksum and a bad magic are both
rejected, and dead reckoning advances position correctly including the
negative-velocity borrow. `tools/vpeer.py --selftest` re-checks the same wire
format from the PC side. Run everything with `make test`.
