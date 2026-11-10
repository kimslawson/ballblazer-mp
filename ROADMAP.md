# Roadmap

Two-machine Ballblazer over FujiNet. Legend: `[x]` done and verified ·
`[ ]` open · `(hw)` needs real hardware.

## Done

- [x] **Tooling.** `tools/rig.py` drives the stock `atari800` frame by frame
      with real joystick/console/keyboard input, monitor access and
      screenshots. Disassembly harness with a byte-exact round-trip self-test.
- [x] **Reverse engineering** of everything lockstep needs
      (`docs/04-findings.md`): the load format, the tick and its two calling
      contexts, every hardware read inside it, the display kernels' interrupt
      behaviour, free memory, and a damaged byte in the supported dump.
- [x] **Design.** Deterministic lockstep over FujiNet NetStream at 2400 baud,
      half duplex, stop-and-wait (`docs/01`, `docs/02`, `docs/05`). The earlier
      state-overwrite design over the `N:` device was dropped: SIO cannot run
      while this game's display interrupts hold the CPU.
- [x] **Resident netplay code** (`src/netplay/resident.s`, 922 of 1024 bytes):
      tick gate, input virtualisation, seeded PRNG, per-tick facing latch,
      interrupt-driven serial driver, protocol, sound mixing.
- [x] **Lobby** (`src/netplay/lobby.s`): image check, own address, opponent
      address, host/join, input delay, handshake, RAM patching; plain RETURN
      plays the untouched local game.
- [x] **Disk builder** (`tools/mkdisk.py`) and **PC peer** (`tools/vpeer.py`).
- [x] **Lockstep proven in emulation** (`make nplock`): two linked emulators,
      30 % loss, all 64 KB compared on common ticks.
- [x] **Serial driver and lobby proven in emulation** (`make npserial`): the
      production code against a cassette image playing the remote machine,
      both roles, no packet lost.

## Next — on hardware

- [ ] `(hw)` One Atari + FujiNet against `vpeer.py`: do the two FujiNet
      commands behave as the firmware source reads? Does the handshake
      complete? Does `resent` stay near zero?
- [ ] `(hw)` Two Ataris: a full match. Find the smallest input delay that
      does not stutter on a normal home network.
- [ ] `(hw)` Listen to it. Decide whether the effect voices sharing voice 2
      is acceptable or needs a smarter mix.
- [ ] `(hw)` A PAL machine, and PAL against NTSC (the faster machine should
      simply wait for the slower).

## Later

- [ ] A visible "waiting for opponent" cue when the game stalls, and a way
      back to the lobby without a power cycle.
- [ ] A desync detector (a few bytes of state hash in the packet header's
      spare bit) — cheap insurance, not needed by any test so far.
- [ ] Full-duplex link (transmit clock on voice 2): halves the round trip and
      allows a delay of 3, at the cost of a second sound voice.
- [ ] A relay (`REGISTER` mode) for play across the internet without port
      forwarding.
- [ ] Support the "[a]" dump, if someone has it: check whether its byte at
      `$A43A` is intact and whether the patch addresses match.

## Known risks

- NetStream is used as read from the firmware source; nothing here has
  talked to a real FujiNet.
- The receive margin is 0.9 ms (4.16 ms byte time against a 3.26 ms display
  kernel). The emulator says it holds; real hardware has the last word.
- Older FujiNet firmware has the UDP-stream command but not baud selection;
  it will not work and the lobby can only show that by never connecting.
