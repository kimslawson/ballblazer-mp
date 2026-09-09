# Latency: network vs. local split-screen

Will networked play feel worse than the original same-machine two-player mode?
Short answer: **your own rotofoil feels identical to local**, the **opponent's
rotofoil is a little behind** (fine on a LAN, playable over the internet), and
the **plasmorb is the one latency-sensitive part** — mitigated, not eliminated,
by host authority. Reasoning and numbers below.

## Three separate costs (don't conflate them)

### 1. Netcode CPU cost — measured, negligible

Measured on the `sim65` cycle-accurate simulator (`tests/bench_netgame.s`,
`make bench`), per call, minus loop overhead:

| routine | cycles | share of an NTSC frame (29,868 cyc) |
|---|---:|---:|
| `ng_deadreckon` (every frame) | ~80 | 0.27% |
| `ng_build_tx` (send frames) | ~347 | 1.2% |
| `ng_apply_rx` (per packet) | ~347 | 1.2% |

Even on a send-and-receive frame that's **~2.5% of the frame budget**. The
netcode *logic* is not the concern.

### 2. Local player latency — zero, by design

The crucial design choice (`docs/04-netcode.md`, `src/game/netpatch.s`): the
local player stays on the **joystick path** and runs the game's stock physics
the same frame the stick is read — exactly as in local split-screen. **There is
no added latency on your own craft.** This is why the game will still feel like
Ballblazer to each player.

### 3. Remote player + ball latency — the real question

Only the *opponent's* motion crosses the wire. Its end-to-end delay is:

```
  SIO/FujiNet out  +  network transit  +  SIO/FujiNet in  +  up to one send
  (peer's BPUT)       (UDP over WiFi)     (our STATUS+GET)    interval (~50 ms)
```

- **SIO/FujiNet transport** is the platform-specific cost. Each `N:` operation
  is an SIO transaction (command frame + handshake + data frame), so it is
  dominated by protocol handshake, not the 16-byte payload. Rough estimates
  (to validate on real hardware — this emulator has no FujiNet):
  - standard SIO (~19.2 kbaud): a few ms up to ~10 ms per `N:` op;
  - FujiNet high-speed SIO: ~2–4 ms per op.
  This is exactly why the netcode **never does a blocking round-trip in the
  frame loop**: it sends at ~20 Hz (every 3rd frame) and only ever `GET`s bytes
  a non-blocking `STATUS` already reported waiting.
- **Network transit**: LAN ~1 ms; internet 20–80 ms one way.
- **Update quantization**: at 20 Hz, up to ~50 ms until the next packet — hidden
  by **dead reckoning** (the remote craft keeps moving on its last velocity and
  snaps to truth when a packet lands).

Putting it together:

| link | opponent rotofoil is ~behind | feel |
|---|---|---|
| LAN (high-speed SIO) | ~30–70 ms | very good; dead reckoning invisible in steady motion |
| Internet (typical) | ~100–200 ms | playable; small rubber-banding on sharp direction changes |

Ballblazer helps here: the rotofoil has **momentum and auto-snaps** to face the
ball/goal, so motion is smooth and predictable — the ideal case for dead
reckoning. It is not a twitch game.

## The plasmorb is the sensitive part

The ball is fast and its possession/shots are discrete events, so it tolerates
latency far less than the gliding rotofoils. The design makes **one machine
(the host) authoritative** for the ball and scoring; the client renders the
host's ball (and may predict between packets). Consequences:

- The **host** sees the ball perfectly.
- The **client** sees the ball ~½ RTT behind and will occasionally see a
  correction ("snap") when its prediction diverges from the host's truth —
  most noticeable right at a catch or a shot on a high-latency link.

This is the fundamental, unavoidable tradeoff of real-time netplay, and it is
concentrated in exactly one object rather than smeared across the whole game.

## Tuning knobs (all in `src/net/`)

- `SEND_EVERY` (default 3 → 20 Hz): lower for less quantization at higher `N:`
  cost; raise on slow links.
- Dead-reckon smoothing: hard snap today; ease-to-truth is a small refinement to
  hide corrections.
- Jitter buffer: holding one extra packet trades a little more latency for fewer
  extrapolation overshoots on jittery links.

## What still needs a real device to confirm

The CPU cost and the local-latency claim are established here. The SIO/FujiNet
per-op time and the resulting real RTT need a hardware (or `fujinet-pc`) run;
that measurement is the one open number in this analysis, and it sets where on
the "LAN … internet" spectrum a given setup lands.
