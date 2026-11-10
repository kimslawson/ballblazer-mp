; ============================================================================
; game.inc - Ballblazer (Atari 8-bit, "Regulation Certified" disk) facts
; ----------------------------------------------------------------------------
; Addresses established by reverse engineering (docs/05-findings.md). These are
; memory-map facts, not game code. They are specific to the supported image;
; the lobby refuses to patch anything unless the image checksum matches.
; ============================================================================
G_START      = $4C00     ; game cold start (the disk's run address)
G_IDLE_JMP   = $4C8A     ; main loop tail: JMP $4C72
G_IDLE       = $4C72     ; main loop (render scheduler); logic lives in the tick
G_TICK       = $4CBE     ; logic tick: INC $B6 / LDA #0 / STA $BA / ...
G_TICK_RESUME= $4CC2     ; first instruction after the 4 bytes we displace
G_BUSY       = $B4       ; tick guard: 0 idle, $FF running (tick ends INC $B4)
G_TICKCNT    = $B6       ; the game's own tick counter (first displaced insn)

; players' facing (0-3). The logic sets the REQUEST; the stock game copies it
; into CURRENT from a display interrupt when that view's frame has been drawn.
G_FACE_CUR1  = $0C
G_FACE_REQ1  = $11
G_FACE_CUR2  = $20
G_FACE_REQ2  = $25
G_FACE_FLAG  = $B7       ; DEC'd when a facing changes (drives a sound)

; sound staging (zero page), committed to POKEY once per tick at G_SND_COMMIT
G_SND_COMMIT = $797B
G_V1F = $F9              ; voice 1 -> AUDF1/AUDC1
G_V1C = $FA
G_V2F = $F6              ; voice 2 -> AUDF2/AUDC2
G_V2C = $F7
G_V3F = $F3              ; effect  -> AUDF3/AUDC3
G_V3C = $F4
G_V4F = $F0              ; effect  -> AUDF4/AUDC4
G_V4C = $F1

; identity of the supported image: 16-bit additive checksum of $4000-$BBFF as
; loaded (before the game runs). The lobby will not patch anything else.
G_SUM_LO     = $A5
G_SUM_HI     = $A4

; ---- patch sites (see lobby.s for what goes where) -------------------------
; controller / console / keyboard reads inside the tick
G_RD_PORTA_1 = $5F3D     ; LDA PORTA   (player 1 stick)
G_RD_PORTA_2 = $5F7A     ; LDA PORTA   (player 2 stick)
G_RD_TRIG0   = $5F46     ; LDX TRIG0
G_RD_TRIG1   = $5F85     ; LDX TRIG1
G_RD_CONSOL  = $5DBD     ; LDA CONSOL
G_RD_KBCODE  = $5DB7     ; LDA KBCODE
G_RD_IRQST   = $5DAB     ; BIT IRQST   (keyboard IRQ polled, never taken)
; writes that would fight the serial port
G_WR_IRQEN_A = $5DAE     ; STA IRQEN   (keyboard poll: acknowledge)
G_WR_IRQEN_B = $5DE4     ; STA IRQEN   (keyboard poll: re-arm)
G_WR_IRQEN_C = $4C60     ; STA IRQEN   (init)
G_WR_SKCTL   = $4C4F     ; STA SKCTL   (init)
G_WR_AUDCTL  = $79E0     ; STY AUDCTL  (sound init)
; display-interrupt facing latches (10 bytes each: LDA req/CMP cur/BEQ/STA/DEC)
G_LATCH_1    = $5A13
G_LATCH_2    = $5C76

; The main loop has four places where it runs a tick that the VBI had to skip
; (JSR G_TICK). In this image the operand of the fourth one reads $4C41 instead
; of $4CBE ($41 is $BE with every bit flipped - a damaged byte in the dump), so
; a VBI landing in that ~60-cycle window re-runs the tail of the game's start-up
; code: a rare, harmless glitch for a local game, but it reseeds a counter the
; simulation depends on, at a moment that differs per machine. Netplay puts the
; intended target back.
G_BAD_CATCHUP = $A439    ; JSR $4C41  (should be JSR G_TICK)
