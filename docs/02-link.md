# The link: FujiNet NetStream, POKEY serial, and the input protocol

## Why not the `N:` device

FujiNet's `N:` device is driven by SIO commands: every status poll, read and
write is a command frame, acknowledge, data frame and completion at 19200
baud. That is 8–20 ms per operation and at least three operations per
exchange — and worse, SIO cannot run *during* this game at all: Ballblazer's
display interrupts keep the CPU, with IRQs masked, for 3.3 ms per view (and,
unpatched, up to ~11 ms), while a 19200-baud byte lasts 0.52 ms and POKEY
buffers exactly one. The earlier design in this repo was built on `N:`; it
could not have worked on real hardware.

## NetStream

Current FujiNet firmware has a raw serial ⇄ network bridge, **NetStream**
(the descendant of the "UDP stream" mode made for MIDI Maze). Once enabled,
every byte the Atari shifts out of POKEY is forwarded in a UDP datagram to a
configured host, and every datagram received is clocked into the Atari's
serial input at the line rate. No command frames, no handshake.

The lobby issues two ordinary SIO commands to the FujiNet control device
(`$70`) while the OS is still alive:

| cmd | direction | bytes | purpose |
|---|---|---|---|
| `$E8` | read | 140 | adapter config; bytes 97–100 are this FujiNet's IP, shown so the players can tell each other |
| `$F0` | write | 64 | enable NetStream: host string, NUL, flags, AUDF3. `DAUX1:DAUX2` = port (6502), big-endian |

Flags: bit 0 = TCP (we use UDP, 0), bit 1 = send a REGISTER packet (0),
bits 2/3 = FujiNet supplies the serial clock (0), bit 4 = PAL machine. The
AUDF3 byte tells the firmware the baud rate (109 → 2405 baud NTSC, 106 →
2403 baud PAL, with AUDF4 = 1 implied).

Then:

- the cassette **motor line** is switched on (`PACTL = $34`) and left on —
  NetStream only relays while it is asserted;
- no further SIO command is ever issued: asserting the command line turns
  NetStream off.

Both FujiNets listen on UDP 6502 and send to the other's address on 6502, so
on a LAN each player simply types the other's IP. Across the internet both
sides need UDP 6502 forwarded.

Facts above are from the firmware source (`lib/device/sio/netstream.cpp`,
`lib/bus/sio/sio.cpp`, `lib/device/sio/sioFuji.cpp`); they have **not** been
exercised against a real FujiNet in this repository — see `docs/06-playing.md`.

## POKEY

| register | value | meaning |
|---|---|---|
| `AUDCTL` | `$28` | voice 3 clocked at 1.79 MHz, voices 3+4 joined: the baud generator |
| `AUDF3/AUDF4` | 109 (106 PAL) / 1 | 2400 baud |
| `AUDC3/AUDC4` | 0 | silent |
| `SKCTL` | `$13` to listen, `$23` to talk | the same two modes the OS uses |
| `IRQEN` | one of `$20` / `$10` / `$08` | receive ready / send next / send complete |

**2400 baud** is deliberate. With the patch the longest stretch with IRQs
masked is one display kernel, 51 scanlines = 3.26 ms. A byte at 2400 baud
lasts 4.16 ms, so the byte in POKEY's one-byte buffer is always collected
before the next one lands.

**Half duplex.** POKEY needs separate clocks to send and receive at once, and
only voices 3+4 are spare (the alternative costs a third sound voice). So the
line is turned around like the OS does it, and the protocol guarantees nobody
ever talks over the other.

Receive and transmit are interrupt driven (`irq`). Sound: voices 1 and 2 play
as before; the two effect voices that lived on 3 and 4 borrow voice 2 while
they sound (`mix`).

## Protocol

Strict ping-pong, host first. Each packet carries the sender's inputs the
other side has not yet acknowledged; receiving the next packet *is* the
acknowledgement.

```
packet = hdr, 0-7 body bytes, checksum

hdr    bit 7    sequence bit
       bit 5-3  body length
       bit 2-0  type: 0 DATA, 1 START, 2 HELLO, 3 WELCOME

DATA body byte:  bits 0-4 input code, bits 5-7 (repeat - 1)
                 one byte = up to 8 consecutive ticks of an unchanged controller

input code:      bits 0-3 joystick as PORTA reads it (0 = pushed), or a key
                 using stick positions that cannot physically occur:
                 1 START  2 SELECT  3 OPTION  4 SPACE  8 ESC  12 RETURN
                 bit 4    trigger pressed

checksum:        a = $A5; for each byte: a ^= byte; a = rol-less (a << 1) + $1D + carry
```

A typical packet is three bytes (12.5 ms on the wire).

- **Host** sends DATA with sequence bit *s* and waits. A valid answer carrying
  the same *s* acknowledges it: the host unpacks the client's inputs, flips
  *s*, and sends the next packet at once. If nothing valid arrives for 8
  frames it resends the identical packet.
- **Client** answers every DATA. A packet whose sequence bit differs from the
  last one it took is new: unpack, build the answer, send. One with the same
  bit means the answer was lost: resend the identical answer.
- Retransmissions are byte-identical, so it never matters which copy arrives.
- A fragment followed by two silent frames is discarded; a framing/overrun
  error poisons the packet in progress; neither side starts talking while a
  packet is arriving.

Handshake (lobby): the client sends `HELLO(version, image checksum)` every
⅔ s; the host answers `WELCOME(seed lo, seed hi, delay)`; the client answers
`START` and starts its game; the host starts on `START`. A client that has not
yet seen DATA repeats `START` every 32 frames, so a lost `START` is harmless.

`tools/npproto.py` is the same protocol in Python (used by the tests and by
`tools/vpeer.py`).
