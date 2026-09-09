# Architecture: turning single-player Ballblazer into a network match

This document explains what Ballblazer is doing internally (from public,
community knowledge — no ROM contents are reproduced here) and exactly where a
network opponent replaces the built-in droid AI.

## What Ballblazer is

Ballblazer (Lucasfilm Games, 1985) is a one-on-one sport played on a flat
checkerboard "grid plain." Each player pilots a *rotofoil* and tries to fire the
floating *plasmorb* through the opponent's goal. The screen is split
horizontally: each player sees a first-person 3-D view of the grid (the famous
fractal-smooth "Rotoscape"). The rotofoil auto-rotates ("snaps") to face the
ball or the goal.

Two game modes exist in the original:

- **One player vs. droid** — the human drives one rotofoil; a computer *droid*
  (skill 1–9) drives the other.
- **Two players** — two humans on the **same machine**, one per screen half. No
  networking existed in 1985.

The key structural fact for us: **the game already knows how to drive two
rotofoils and render both views.** Single-player mode simply feeds one
rotofoil's controls from the droid AI instead of a second joystick.

## The core idea

> Run the game as if it were the native two-player mode, but source the second
> rotofoil's state from the **network** instead of a local joystick or the
> droid, and transmit the local rotofoil's state out.

Concretely, each machine:

1. Reads its **local** joystick and runs the *unmodified* rotofoil physics for
   its own craft (zero input latency — feels native).
2. Sends that craft's authoritative state to the peer (`netgame.s`,
   ~20 packets/sec).
3. Receives the peer's craft state and writes it into the variables the game
   uses for "the other rotofoil," extrapolating between packets so motion stays
   smooth at 60 Hz.
4. Agrees on **one** authority for the shared plasmorb (the *host*), so the ball
   never forks into two contradictory truths.

This is the standard client/server-with-local-prediction model used by real
action games, adapted to a two-machine, two-object world. See
[`04-netcode.md`](04-netcode.md) for the full rationale (why not lockstep, how
dead reckoning works, how the ball authority resolves).

## The three integration seams in the ROM

Reverse engineering (see [`03-disassembly.md`](03-disassembly.md)) has to locate
three things. Everything else in `netgame.s`/`ncio.s` is already written and
tested against a defined `NETSTATE` struct; integration is *wiring*, not new
netcode.

### Seam A — the opponent input/AI hook (the important one)

Somewhere each frame the game decides the second rotofoil's intended motion.
In two-player mode that comes from joystick 1; in one-player mode from the
droid AI. **Find the branch that selects the droid**, and replace the droid's
per-frame decision with "apply the remote rotofoil state we received."

How to find it: set a breakpoint / trace reads of the joystick-1 shadow
(`STICK1`, `$0279`) and of `RANDOM` (`$D20A`) — a skill-scaled AI almost
certainly consults the hardware PRNG. The code path that consumes those and
writes the second craft's velocity/heading is Seam A.

### Seam B — the shared state variables

Identify the memory holding each rotofoil's **position (X,Y), velocity, and
heading**, and the **plasmorb's position + possession**. These map onto the
`loc_*` / `rem_*` / `ball_*` fields in `netgame.s`. Finding them: watch which
zero-page/RAM locations change as you move on the grid in an emulator's memory
view; positions change smoothly, heading tracks the snap-to-target.

### Seam C — the mode select + match lifecycle

Find the one/two-player mode flag and the "goal scored" / "match over" routines.
Add a third mode ("network match") that: initialises the link (`ng_init`, open
`N:`), forces the two-rotofoil rendering path, and routes goal/score events
through the packet's event field so both machines agree on the score.

## Per-frame control flow after integration

```
        ┌─────────────────────────── game VBLANK / main loop ──────────────────────────┐
        │                                                                               │
  read local joystick ──> unmodified rotofoil physics ──> loc_* (our craft: X,Y,V,hdg)  │
        │                                                                               │
        │   ng_tick():   drain inbound (non-blocking) ─> rem_* / ball_*                 │
        │                dead-reckon rem_* by last velocity                             │
        │                every 3rd frame: send loc_* (+ball_* if we are host)           │
        │                                                                               │
  Seam A: write rem_* into "opponent rotofoil" vars  (was: droid AI output)             │
  Seam B: host writes ball physics -> ball_*; client renders ball_* from packet         │
        │                                                                               │
  render both split-screen views exactly as the stock game does ─────────────────────────┘
```

Because `ng_tick` never blocks (it only ever GETs bytes CIO already has, per
[`02-fujinet-n-device.md`](02-fujinet-n-device.md)), dropping it into the frame
loop costs a bounded, small slice of CPU and never stalls a frame.

## What stays untouched

The renderer, the fractal-grid drawing, sound, and — crucially — **your own**
rotofoil's physics all run stock. We only (a) redirect the *opponent's* input
source and (b) pick a single authority for the ball. That keeps the port small
and the game feeling like Ballblazer.
