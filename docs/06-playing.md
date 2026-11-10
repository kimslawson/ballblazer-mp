# Building, playing, and what has been proven

## You need

- Two Atari 8-bit computers (48K 800 or any XL/XE), NTSC or PAL, each with a
  **FujiNet** on firmware **v1.6.0 or later** (released 2026-05-01). That is
  the release where the old fixed-19200 "UDP stream" became *NetStream*, with
  the baud-rate byte and motor-line gating this patch relies on. On v1.5.x
  and earlier the `$F0` command exists but the FujiNet talks 19200 baud to
  our 2400, so the lobby's handshake never completes; update it.
- Both FujiNets on the same network (or UDP port 6502 forwarded to each).
- Your own copy of the Ballblazer disk image this patch supports (see
  `rom/README.md`). Both players must use the same image.

## Build the disk

```sh
sudo apt-get install cc65 python3
cp /path/to/your/Ballblazer.atr rom/ballblazer.atr
make disk          # -> build/ballblazer-net.atr  (and .xex)
```

The output contains your game plus about 3 KB of this project's code. Treat
it like the original: it stays on your machines.

## Play

1. Put `ballblazer-net.atr` on both FujiNets as D1: and boot both Ataris.
2. Each shows `THIS ATARI'S ADDRESS:` and its IP. Tell each other.
3. Type the **opponent's** address and RETURN. (Just RETURN = the ordinary
   local game, completely unpatched.)
4. One player answers **H** (host, player 1, top view) and picks an input
   delay — RETURN for 5. The other answers **J** (join, player 2, bottom).
5. `WAITING FOR OPPONENT` — when the handshake completes both machines start
   the game together. START on either machine begins a match; SELECT/OPTION
   and the host's stick set the options as usual. Each player uses the
   joystick in **port 1** of their own machine.

START during `WAITING` gives up and starts a local game.

### What to expect

- Steering answers `delay` frames late (83 ms at the default). Raise the
  delay if the picture stutters; lower it if it feels sluggish and does not.
- Sound: the two music/engine voices are there; the two effect voices share
  the second one while they sound. Voices 3 and 4 are the serial clock.
- If the link drops, both games freeze. Power-cycle to start over. Do not use
  System Reset once the game is running.

## One Atari and a PC

`tools/vpeer.py` speaks the same protocol over UDP and stands in for the
other machine. Its "player" just wanders and shoots, but it exercises the
whole link:

```sh
python3 tools/vpeer.py host              # then answer J on the Atari
python3 tools/vpeer.py join 192.168.1.50 # the Atari's address; answer H there
```

On the Atari, enter the PC's IP as the opponent's address. vpeer prints a
status line every two seconds (ticks, packets, resends).

## What is verified, and how

| claim | evidence | status |
|---|---|---|
| the netplay code assembles and fits; the protocol reference survives 30 % loss | `make test` (no image needed) | ✅ |
| two machines running the patched game stay bit-identical in everything the simulation uses | `make nplock`: two linked emulators, scripted joysticks, 30 % packet loss; both frozen on the same tick and all 64 KB compared, repeatedly | ✅ thousands of ticks, several seeds |
| the interrupt-driven serial driver receives and sends every packet while the game's display kernels run | `make npserial`: a 2400-baud cassette image plays the remote machine against the production code; the emulator models POKEY's one-byte buffer | ✅ 600 packets / 60 s, both roles, 0 damaged |
| the lobby's prompts, role and delay entry, handshake, and game start | same test, typed through the real prompts | ✅ |
| a full match plays — ball, goals, score, clock | screenshots from the above (`build/shots/`) | ✅ |
| the two FujiNet commands and NetStream's behaviour | read from the firmware source only | ⏳ **needs real hardware** |
| byte timing against a real POKEY and a real FujiNet UART | — | ⏳ **needs real hardware** |
| how it sounds, how the delay feels | — | ⏳ **needs real hardware** |
| PAL machines | divisor and flag are set; never run | ⏳ |

What the emulator cannot tell us is whether NetStream behaves as its source
reads, and whether 0.9 ms of margin on the receive side is enough on real
silicon. The first hardware test should be **one Atari against `vpeer.py`**:
if vpeer reports HELLO, the tick counter climbs and `resent` stays near zero,
the link is sound.

## If it does not work

| symptom | likely cause |
|---|---|
| `NO FUJINET ANSWERED` | no FujiNet on the bus, or it did not answer command `$E8` |
| `FUJINET REFUSED NETSTREAM MODE` | firmware without the `$F0` command |
| `WAITING FOR OPPONENT` forever | addresses swapped or mistyped; both chose the same role; firmware NetStream without baud selection (it then talks 19200 to our 2400); UDP 6502 blocked |
| `THIS IS NOT THE GAME IMAGE…` | a different dump; only the one in `rom/README.md` is supported |
| `OPPONENT HAS A DIFFERENT VERSION` (host) | the two disks were built from different images or revisions of this code |
| game starts, then freezes or crawls | packets are being lost: vpeer's `resent` counter will show it; try a larger delay, check Wi-Fi |
| the two screens show different games | a desync — should not happen; please note what was going on and report it |

## Running the emulator tests yourself

```sh
sudo apt-get install atari800 xvfb imagemagick python3-pil
make nptest
```

They need `rom/ballblazer.atr` and take a few minutes. The rig runs the stock
`atari800` 5.0 under a private Xvfb display; see `tools/rig.py`.
