# The FujiNet `N:` device from assembly

FujiNet exposes networking as a normal Atari CIO device named `N:`. You use it
exactly like `E:` (screen) or `D:` (disk): fill in an IOCB and `JSR CIOV`
(`$E456`) with `X = IOCB# * 16`. FujiNet's handler installs itself into the OS
handler table (HATABS) at boot, so no special linkage is needed.

This project uses **IOCB #1** for the link (`NET_IOCB` in `fujinet.inc`).

## Opening a connection

Point the IOCB buffer at an EOL(`$9B`)-terminated URL and issue `OPEN` (`$03`):

```
    N:UDP://:5000/                 host: listen for datagrams on UDP 5000
    N:UDP://192.168.1.50:5000/     client: send to that host, receive replies
    N:TCP://192.168.1.50:5000/     connection-oriented (easy to test)
```

`ICAX1` (aux1) carries the direction: `$04` read, `$08` write, `$0C`
read+write. Ballblazer-MP opens **read+write** (`OPEN_UPDATE = $0C`) because the
link is bidirectional. See `net_open` in `src/net/ncio.s`.

Protocol choice: the live state stream uses **UDP**. Every packet is a full
snapshot, so a lost datagram just means one stale tick — no retransmit stall,
no head-of-line blocking. TCP is supported by the demo only to make a quick
two-endpoint reliability check trivial.

## The non-blocking read pattern (this is the important part)

A 60 Hz game must **never** spin waiting on the network. FujiNet supports this
directly: a CIO `STATUS` (`$0D`) call makes the `N:` handler write how many
bytes are waiting into the 4-byte `DVSTAT` block at `$02EA`:

| addr    | meaning                         |
|---------|---------------------------------|
| `$02EA` | bytes waiting, low              |
| `$02EB` | bytes waiting, high             |
| `$02EC` | connection status (0 = closed)  |
| `$02ED` | extended error                  |

So each frame we:

1. `STATUS` → refresh `DVSTAT` (`net_poll`).
2. While bytes-waiting ≥ one packet, `GETCHR` exactly one packet (`net_get`) and
   apply it. Because we only ever ask for bytes STATUS already reported, the GET
   returns immediately and never blocks.

`netgame.s : ng_recv` implements exactly this drain loop, newest packet wins.

## Sending

Set the buffer to the packet, length to `PKT_LEN`, issue `PUTCHR` (`$0B`) —
`net_put`. We throttle sends to every `SEND_EVERY` (3) frames ≈ 20 Hz.

## CIO command / mode quick reference

| symbol        | value | use here                     |
|---------------|-------|------------------------------|
| `CMD_OPEN`    | `$03` | open the `N:` URL            |
| `CMD_GETCHR`  | `$07` | block read (BGET)            |
| `CMD_PUTCHR`  | `$0B` | block write (BPUT)           |
| `CMD_CLOSE`   | `$0C` | close the link               |
| `CMD_STATUS`  | `$0D` | refresh `DVSTAT` bytes-waiting |
| `OPEN_UPDATE` | `$0C` | aux1: read+write             |

(These are standard Atari CIO values; the Gemini summary in the task used the
same `BPUT $0B` / `BGET $07` / `CLOSE $0C` codes.)

## Firmware-dependent detail to confirm on real hardware

For **connectionless UDP**, some FujiNet firmware revisions want the transmit
destination set via a CIO/SIO `SPECIAL` command (≥ `$0E`) rather than purely
from the URL. This project keeps every such call isolated so it is easy to
adjust:

- If your firmware sends UDP to the address in the OPEN URL (common), the demo
  works as-is.
- If it needs an explicit "set destination" SPECIAL, add it in `net_open`
  behind a clearly marked block and confirm the command number against the
  current **FujiNet NOS / `N:` "Network-Only DOS"** documentation for your
  build. (That reference — `fujinet.online/.../fujinet-nos-a-network-only-dos/`
  — is the authority; it could not be fetched from this build environment, so
  verify against it directly before shipping to hardware.)

## Where to test without two Ataris

`tools/vpeer.py` is a PC-side virtual opponent that speaks this exact packet
format over UDP. Run it and point one real Atari (or an emulator with FujiNet)
at it to validate the whole `N:` path end to end. See the README.
