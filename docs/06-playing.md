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

### On macOS

```sh
brew install cc65                 # ca65 / ld65; python3 and make come with Xcode tools
md5 rom/ballblazer.atr            # must print a37afb54b6edbd03c348efa0b714d37c
make test && make disk
md5 build/ballblazer-net.atr      # see `git log -1` - the commit message of the
                                  # last code change records the expected md5
```

The input image is the file
`Ballblazer_1985_Lucasfilm_Games_Regulation_Certified_k_file.atr` (35,344
bytes) from the Internet Archive item
`a8b_Ballblazer_1985_Lucasfilm_Games_Regulation_Certified_k_file` — not the
"[a]" item next to it. `mkdisk.py` refuses anything else.

If your output md5 differs but `make test` passes, compare
`build/np/np0.resident` and `build/np/np0.lobby` first: a different cc65
release could in principle assemble a byte differently (this was built with
cc65 2.18 / 2.19). `make test` and `make disk` are all a Mac needs to build;
the emulator tests run there too (see the end of this document).

## Play

1. Put `ballblazer-net.atr` on both FujiNets as D1: and boot both Ataris.
2. Each shows `THIS ATARI'S ADDRESS:` and its IP. Tell each other.
   (A FujiNet-PC — emulators, phone apps — does not know its host's
   address; the lobby then says so, and you look the address up in that
   device's network settings instead.)
3. Type the **opponent's** address and RETURN. (Just RETURN = the ordinary
   local game, completely unpatched.)
4. One player answers **H** (host, player 1, top view). At the delay prompt
   just press RETURN: the lobby times the link and picks the input delay
   (or type a number, 3-20). The other answers **J** (join, player 2,
   bottom).
5. `WAITING FOR OPPONENT` — when the handshake completes both machines start
   the game together. START on either machine begins a match; SELECT/OPTION
   and the host's stick set the options as usual. Each player uses the
   joystick in **port 1** of their own machine.

**Mistyped the address?** BACK SPACE works as usual while you type (some
emulator keyboards do not pass it on). After that there are two ways back
to the address prompt, neither of which needs an editing key: answer the
host/join question with just RETURN, or press START while the lobby says
`WAITING`. From the address prompt, plain RETURN starts a local game.

### What to expect

- Steering answers `delay` frames late. The lobby shows the round trip it
  measured (average and worst, in frames) and the delay it chose, which is
  one and a half times the worst plus one - what a turn-taking link needs
  to run without stopping. If play still stutters, host again and type a
  larger number; if it is smooth and you want it snappier, a smaller one.
  Emulators with a built-in FujiNet need roughly twice the delay real
  hardware should (see `docs/05-timing.md`).
- Sound: POKEY voices 3 and 4 are the serial clock, so each tick the two
  loudest of the game's four voices are played. Most of the time that is
  everything; in busy passages the quietest parts drop out.
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

## Emulators with a FujiNet

An emulator can stand in for a real Atari + FujiNet if **all three** hold:

1. its Atari core relays NetStream over NetSIO — current `atari800` does
   (raw serial bytes are forwarded once command `$F0` was acknowledged, the
   motor line is on, `AUDCTL` has voices 3+4 joined at 1.79 MHz, and `SKCTL`
   is in mode `$00`, `$10`, `$30` or `$40`; this patch uses `$13`/`$43`);
2. the FujiNet-PC it talks to is built from firmware v1.6.0 or later;
3. each emulated machine is on a **different IP address** — both ends listen
   on UDP 6502, so two instances on one computer collide.

FujiNet-PC always reports its own address as 127.0.0.1, so the lobby asks you
to look it up on the host device instead of showing it.

Fujisan (libatari800 + a bundled FujiNet-PC) fits that shape; whether a given
release has points 1 and 2 depends on what it bundles. Serving the `.atr`
from TNFS is fine: the game is fully loaded before NetStream starts and the
disk is never touched again. An emulator does not exercise real POKEY timing,
so it tests the FujiNet side and the protocol, not the 0.9 ms receive margin.

## What is verified, and how

| claim | evidence | status |
|---|---|---|
| the netplay code assembles and fits; the protocol reference survives 30 % loss | `make test` (no image needed) | ✅ |
| two machines running the patched game stay bit-identical in everything the simulation uses | `make nplock`: two linked emulators, scripted joysticks, 30 % packet loss; both frozen on the same tick and all 64 KB compared, repeatedly | ✅ thousands of ticks, several seeds |
| the interrupt-driven serial driver receives and sends every packet while the game's display kernels run | `make npserial`: a 2400-baud cassette image plays the remote machine against the production code; the emulator models POKEY's one-byte buffer | ✅ 600 packets / 60 s, both roles, 0 damaged |
| the lobby's prompts, role and delay entry, both ways back to the address prompt, handshake, and game start | same test, typed through the real prompts | ✅ |
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
| `FUJINET REFUSED NETSTREAM MODE` | firmware without the `$F0` command, or an address it could not make sense of; the lobby asks for the address again |
| `WAITING FOR OPPONENT` forever | addresses swapped or mistyped (START goes back to the address prompt); both chose the same role; firmware NetStream without baud selection (it then talks 19200 to our 2400); UDP 6502 blocked |
| `THIS IS NOT THE GAME IMAGE…` | a different dump; only the one in `rom/README.md` is supported |
| `OPPONENT HAS A DIFFERENT VERSION` (host) | the two disks were built from different images or revisions of this code |
| play stutters evenly, music drags | the input delay is below one and a half round trips: let the host time the link (RETURN at the delay prompt) or type a larger delay. `vpeer.py` shows the round trip |
| game starts, then freezes for a moment now and then | packets are being lost or damaged: vpeer's `resent` counter will show it; check Wi-Fi, and on a real FujiNet try a larger NetStream `rx_depth` (see `docs/05-timing.md`) |
| the two screens show different games | a desync — should not happen; please note what was going on and report it |

## Running the emulator tests yourself

They need `rom/ballblazer.atr` and the stock `atari800` emulator, and take
about five minutes.

**Linux**

```sh
sudo apt-get install atari800 xvfb imagemagick python3-pil
python3 tools/rig.py selfcheck     # is the rig stable and frame-exact here?
make nptest
```

**macOS**

```sh
brew install atari800 cc65
python3 tools/rig.py selfcheck
make nptest
```

### Watching a run

```sh
make watch              # or: make watch ROLE=host
```

runs the serial test as usual and then **replays it in an ordinary emulator
window, at real speed and with sound**: the disk loading (about half a
minute), the lobby being typed into, the handshake, and a minute of play
against the scripted remote machine. The rig keeps a copy of every frame of
input it fed; the emulator is deterministic, so playing that file back shows
exactly the session the test just judged. The small `C` that flickers in the
corner is the emulator's cassette indicator - that is the "remote Atari"
talking. The window closes by itself at the end.

The tests themselves cannot run in a visible window: the emulator closes its
window whenever the rig stops it to look at memory, which happens several
times a second. The two-machine soak (`nplock`) has no replay because the rig
pokes the link's mailboxes from outside; what it would show is what the
replay above shows anyway - in lockstep both machines display the same game.

`selfcheck` prints the emulator version and how the rig detects that the
emulator is idle, then runs the same scripted session twice and compares
memory; run it first on a new machine. Three knobs, all environment
variables:

| variable | effect |
|---|---|
| `ATARI800=/path/to/atari800` | use a specific emulator binary |
| `RIG_VIDEO=0` | no screenshots even if Xvfb is installed |
| `RIG_IDLE=count` | on Linux, use the portable idle test (the one macOS always uses) instead of `/proc` |

Differences between the two systems:

- Screenshots (`build/shots/`) need Xvfb and are Linux-only. On macOS the
  emulator runs with SDL's dummy video driver; the tests' verdicts do not
  depend on pictures.
- To know when the emulator has run everything it was fed, the rig asks
  `/proc` on Linux (exact). Elsewhere it counts the line the emulator logs
  for every frame and then waits for 60 ms of silence — slower (the soak
  takes about twice as long) but it needs nothing from the OS. That method
  passes every test on Linux (`RIG_IDLE=count`); on macOS itself it has only
  been run by whoever is reading this.
- The rig was developed against atari800 5.0.0 (what Debian/Ubuntu ship).
  Homebrew has a newer release. The input-playback file format the rig
  writes is the same in every release up to 7.2.1; it changed on the
  emulator's development branch after that. Newer emulator versions may also
  time the serial port slightly differently, which is worth knowing about if
  `npserial` disagrees between the two systems.

The rig runs the emulator with a private, empty configuration, so it uses the
built-in Altirra OS regardless of your `~/.atari800.cfg`. See `tools/rig.py`.
