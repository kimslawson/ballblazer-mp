; ============================================================================
; fujinet.inc  -  FujiNet "N:" device constants + the Ballblazer link protocol
; ----------------------------------------------------------------------------
; The N: device is a CIO handler that FujiNet installs into HATABS.  You talk
; to it exactly like any other CIO device (E:, D:, ...): put a command in the
; IOCB and JSR CIOV.  The device name string carries a URL, e.g.
;
;     N:UDP://192.168.1.50:5000/      (connectionless, low latency  <- game)
;     N:TCP://192.168.1.50:5000/      (connection oriented          <- easy test)
;
; UDP is preferred for the live state stream: every packet is a full snapshot,
; so a dropped datagram just means one stale tick, and there is no head-of-line
; blocking.  TCP is offered only because it is trivial to test peer-to-peer.
;
; NOTE ON FIRMWARE DEPENDENCE: the exact SPECIAL command numbers used to set a
; UDP transmit destination have varied across FujiNet firmware revisions.  The
; helpers in ncio.s that touch those are isolated and marked; confirm the
; current numbers against the live FujiNet N:/NOS documentation for your build
; (docs/02-fujinet-n-device.md tracks what we relied on).
; ============================================================================

; ---- IOCB we dedicate to the network link ------------------------------
NET_IOCB    = 1              ; use IOCB #1 for N:  (X = NET_IOCB*16 = $10)
NET_IOCBX   = NET_IOCB*16    ; value to load into X for CIOV

; ---- The wire packet -----------------------------------------------------
; Fixed 16-byte snapshot exchanged both directions every network tick.
; Fixed size => no framing/parsing: STATUS tells us bytes-waiting, we GET a
; whole multiple of PKT_LEN, and apply the newest.  Fields are deliberately
; transport-agnostic; the game-integration step (Phase 3) maps the game's real
; variables onto this struct - see docs/04-netcode.md.
PKT_LEN     = 16

PKT_MAGIC   = 0              ; $Bx  - 'B'allblazer id + protocol version nibble
PKT_SEQ     = 1              ; sender frame sequence, wraps 0..255
PKT_ACK     = 2              ; highest peer seq we have applied (loss/RTT stats)
PKT_FLAGS   = 3              ; bit flags, see FLAG_* below
PKT_RFX     = 4              ; rotofoil X, integer part (world grid units)
PKT_RFXF    = 5              ; rotofoil X, fraction (8.8 fixed point)
PKT_RFY     = 6              ; rotofoil Y, integer part
PKT_RFYF    = 7              ; rotofoil Y, fraction
PKT_RFVX    = 8             ; rotofoil velocity X, signed 8-bit
PKT_RFVY    = 9             ; rotofoil velocity Y, signed 8-bit
PKT_RFHDG   = 10            ; rotofoil heading, 0..255 = 0..360 degrees
PKT_BALLX   = 11            ; plasmorb X   (meaningful only from ball authority)
PKT_BALLY   = 12            ; plasmorb Y
PKT_BALLST  = 13            ; ball state: bit7 in-flight, bits0-1 possessor, ...
PKT_EVENT   = 14            ; event payload (goal side<<4 | points), 0 = none
PKT_CSUM    = 15            ; XOR of bytes 0..14 (cheap integrity, belt+braces)

; protocol id / version: high nibble 'B'-ish tag, low nibble = version
PROTO_MAGIC = $B1            ; version 1

; ---- PKT_FLAGS bits ------------------------------------------------------
FLAG_HOST   = %00000001      ; sender is the match host (ball + scoring authority)
FLAG_HAVEBALL=%00000010      ; sender currently possesses the plasmorb
FLAG_GOAL   = %00000100      ; PKT_EVENT carries a goal event this tick
FLAG_START  = %00001000      ; match start handshake
FLAG_END    = %00010000      ; match over
FLAG_PAUSE  = %00100000      ; sender is paused
FLAG_FIRE   = %01000000      ; sender fired the plasmorb this tick
FLAG_HELLO  = %10000000      ; connection handshake / keep-alive

; ---- ball state (PKT_BALLST) --------------------------------------------
BALL_INFLIGHT = %10000000    ; ball is a free projectile
BALL_POSS_MASK= %00000011    ; 0 = none/loose, 1 = host, 2 = client

; ---- tuning --------------------------------------------------------------
; Send state every SEND_EVERY VBLANKs. At 60Hz, 3 => 20 packets/sec each way
; (~320 B/s), plenty for dead-reckoning while keeping CIO overhead low.
SEND_EVERY  = 3
