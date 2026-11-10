# Architecture

Two Ataris, each with a FujiNet, play one game of Ballblazer. Both boot the
same patched disk. The top view is the host's rotofoil, the bottom view the
joining player's; each machine shows both, exactly like the stock game.

## Deterministic lockstep

Nothing about the *game state* ever crosses the wire. Both machines run the
identical simulation, tick for tick, and exchange only controller inputs:

- Ballblazer's whole simulation — both craft, the plasmorb, goals, clock,
  droids, music — is one routine, the **tick** (`$4CBE`), which the game calls
  once per frame from its vertical-blank interrupt. The main loop only redraws
  the two views.
- The patch wedges the tick's entry (`hook` in `src/netplay/resident.s`). A
  tick runs **only when both players' inputs for that tick are known**. If the
  opponent's input has not arrived, the frame is skipped: the game waits, it
  never guesses and never diverges.
- A local input sampled while tick *T* runs is scheduled for tick *T + delay*
  and sent to the peer in the meantime. `delay` (3–9 frames, chosen by the
  host, default 5) hides the network round trip; it is the only latency the
  player feels.
- Everything else the tick reads from hardware is virtualised so that both
  machines see the same values:
  - joystick, trigger, console keys and keyboard reads are redirected to
    bytes filled in from the two input streams;
  - every read of POKEY's `RANDOM` becomes a call to a seeded generator that
    both sides step identically (the host picks the seed at connect time);
  - each craft's facing, which the stock game latches from a display
    interrupt whenever that view happens to have been redrawn, is latched once
    per tick instead.

Because lockstep starts with the very first tick, everything is mirrored:
title screen, option selection (HUMAN/DROID, game length), the match, pause.
START, SELECT, OPTION, SPACE, ESC and RETURN travel in the input stream, so
either player can press them.

Why not synchronise state (the earlier design in this repo)? It needs every
gameplay variable understood and split by authority, and it still disagrees
whenever two craft or a craft and the ball interact. Lockstep needs only the
tick's inputs to be equal — and that can be *proven*: `tests/np_soak.py`
freezes two linked emulators on the same tick and compares all 64 KB.

## What is changed in the game

Nothing on disk is altered. The disk builder appends two segments of original
code to the game's load stream; at boot the lobby patches the copy in RAM:

| where | what | why |
|---|---|---|
| `$4CBE` tick entry | `JMP hook` | the lockstep gate |
| `$4C8A` main loop | `JMP idle` (`CLI`, back to the loop) | the stock game runs with IRQs masked; the serial port needs them |
| controller/console/keyboard reads | operands → `v_*` bytes | inputs come from the streams |
| 17 × `LDA RANDOM`, 3 × `CMP`, 1 × `LDY` | `JSR prng` / operands → PRNG state | shared randomness |
| two display-interrupt facing latches | `NOP`s | facing is latched per tick |
| `$797B` sound commit | `JMP mix` | POKEY voices 3+4 are the serial clock |
| IRQEN / SKCTL / AUDCTL writes | operands → a dummy byte | hands off the serial port |
| end of each display kernel | `JSR` → `dli_a` / `dli_b` | re-enable IRQs for a long routine |
| `$A439` | `JSR $4C41` → `JSR $4CBE` | repair a damaged byte in the image (see findings) |

Choosing "local game" in the lobby (just RETURN) applies none of this.

## Memory

| region | use |
|---|---|
| `$BC00–$BFFF` | resident code. Held the original tape loader; dead once the game runs. 922 of 1024 bytes used. |
| `$0224–$02F8` | second resident chunk, copied there at launch. OS variables, unused after the game takes over (it never calls the OS). |
| `$0180–$01B9` | link state. Bottom of the stack page; the lowest stack pointer seen in play is `$EE`. |
| `$0100–$017F` | the two input rings (64 ticks each). |
| `$2000–…` | the lobby. Free at load time; reclaimed by the game afterwards. |

The game clears zero page and `$0300–$3FFF` at start and uses most of it
(`$0300–$07FF` and `$0B00–$0FFF` are sprite memory), which is why none of the
obvious "free" pages are usable.

## Limits

- One supported image (checked by checksum at boot). See `docs/04-findings.md`.
- If the link dies, both games freeze waiting; there is no reconnect. Power
  cycle (System Reset is not safe once the game runs — the OS's page-2
  variables have been reused).
- No desync detector in the shipped code. The evidence that none occurs is the
  emulator soak; if one ever did, the two screens would simply drift apart.
