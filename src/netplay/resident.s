; ============================================================================
; resident.s - Ballblazer netplay: the part that stays in memory during play.
; ----------------------------------------------------------------------------
; Original code (no game bytes). Loaded at $BC00-$BFFF, a block the running
; game never touches (it held the original loader). The lobby (lobby.s) fills
; in the configuration, patches a handful of operands in the game so it calls /
; reads the things below, then starts the game.
;
; MODEL: deterministic lockstep. Both machines run the *same* game simulation,
; tick for tick, and exchange nothing but controller inputs:
;
;   * The game's whole simulation is one routine (the "tick", G_TICK) normally
;     run once per frame. We wedge its entry (`hook`). A tick runs only when the
;     inputs of BOTH players for that tick are known; otherwise the frame is
;     skipped and the game simply waits (it never diverges).
;   * A local input sampled while tick T runs is scheduled for tick T+delay, and
;     sent to the peer in the meantime. `delay` hides the network round trip.
;   * Everything else the tick used to read from hardware is virtualised: the
;     joystick/trigger/console/keyboard reads now read the v_* bytes below, and
;     POKEY's RANDOM is replaced by a seeded generator (`prng`) that both sides
;     step identically.
;   * The one piece of simulation state the stock game updates from a display
;     interrupt (each craft's facing) is latched here instead, once per tick.
;
; LINK: FujiNet "NetStream" - a raw serial <-> UDP bridge. We talk to POKEY's
; serial port directly at 2400 baud, interrupt driven. The low rate is
; deliberate: the game's display kernels keep IRQs masked for ~3.5 ms at a
; time, and POKEY only buffers one byte, so bytes must be >3.5 ms apart.
; The port is half duplex (POKEY has one baud generator pair to spare, voices
; 3+4), so the protocol is a strict ping-pong: the host sends, the client
; answers, and nobody ever talks over the other. Each packet carries the
; sender's not-yet-acknowledged inputs, run-length coded; a 1-bit sequence
; number makes retransmission after a loss harmless.
;
; Packet:  [hdr] [0-7 body bytes] [checksum]
;   hdr   bit 7   sequence bit
;         bit 5-3 body length
;         bit 2-0 type (0 DATA, 1 START, 2 HELLO, 3 WELCOME)
;   DATA body byte: bits 0-4 input code, bits 5-7 (repeat count - 1), i.e. one
;         byte covers up to 8 consecutive ticks of an unchanged controller.
;   input code: bits 0-3 joystick (as PORTA reads it, 0 = pushed) or, using the
;         physically impossible stick combinations, a key: 1 START, 2 SELECT,
;         3 OPTION, 4 SPACE, 8 ESC, 12 RETURN.  bit 4 = trigger pressed.
;
; Build with -D TEST=1 for the emulator test rig: the serial port is replaced
; by two RAM mailboxes that the rig shuttles between two emulators.
; ============================================================================

        .include "hw.inc"
        .include "game.inc"

        .export cfg_role, cfg_delay, cfg_baud, rnd0, rnd1
        .export hook, idle, irq, prng, mix, dli_a, dli_b
        .export v_porta, v_trig0, v_trig1, v_consol, v_kbcode, v_irqst, sink
        .export net_mode, pkt_ready, txbuf, rxbuf, finish_pkt, tx_start, tx_busy
        .export hw_init, sample
        .export l_wr, l_base, r_wr, seq, tick, err_cnt

.ifndef TEST
TEST = 0
.endif

T_DATA    = 0
T_START   = 1
NEUTRAL   = $0F                 ; stick centred, trigger up

LRING     = $0100               ; our inputs,   indexed by tick & 63
RRING     = $0140               ; their inputs, indexed by tick & 63
                                ; (bottom of the stack page; the game's stack
                                ;  never comes within 100 bytes of it)
.if TEST
TXBOX     = $0AD0               ; [len][bytes..]  written here, rig collects
RXBOX     = $0AE0               ; [len][bytes..]  rig delivers, we consume
T_O       = 100                 ; host retransmit timeout, frames
TEST_STOP_EN = $0AF0            ; (a page the game clears and never uses)
TEST_STOP    = $0AF1
.else
T_O       = 8                   ; ~130 ms; a round trip is ~40 ms
.endif

        .segment "RESIDENT"

; ---- configuration, filled in by the lobby --------------------------------
cfg_role:   .byte 0             ; $00 = host (player 1), $80 = client (player 2)
cfg_delay:  .byte 4             ; input delay in ticks
cfg_baud:   .byte 109           ; AUDF3 for 2400 baud (109 NTSC / 106 PAL)
rnd0:       .byte $C3           ; shared random seed
rnd1:       .byte $5A

; ---------------------------------------------------------------------------
; idle - the game's main loop jumps here instead of straight back to its top.
; The stock game runs with IRQs masked forever; the serial port needs them.
; ---------------------------------------------------------------------------
idle:   cli
        jmp G_IDLE

; ---------------------------------------------------------------------------
; dli_a / dli_b - each view's display kernel (a display-list interrupt that
; owns the CPU for 51 scanlines, 3.3 ms) ends by calling a long table-update
; routine, still inside the interrupt and so with IRQs masked - on alternate
; frames that adds up to ~11 ms. A serial byte lasts 4.2 ms, so that would
; lose data. The kernel proper is over by then; let IRQs back in.
; (If the kernel happened to interrupt our own IRQ handler, enabling IRQs here
; would re-enter it; the routine is then handed to that handler to run on its
; way out - see the end of `irq`.)
; ---------------------------------------------------------------------------
dli_a:  ldx #0
        beq dli_go
dli_b:  ldx #1
dli_go: lda in_irq              ; did this kernel interrupt our IRQ handler?
        bne @defer              ;   then IRQs must stay masked until it is
        cli                     ;   done - it runs the routine itself, later
        txa
        bne :+
        jmp G_DLI_WORK_1
:       jmp G_DLI_WORK_2
@defer: inx
        stx dli_pending         ; 1 / 2 = which routine is owed
        rts

; ---------------------------------------------------------------------------
; hook - replaces the first two instructions of the game's logic tick.
; Entered with G_BUSY = $FF (the game's own re-entrancy guard), from the VBI
; or from the main loop's catch-up path.
; ---------------------------------------------------------------------------
hook:   lda in_irq              ; did the VBI land inside our IRQ handler?
        bne @busy               ;   then leave IRQs masked for this tick
        cli
        lda hw_ready
        bne :+
        jsr hw_init
:
.if TEST
        jsr test_poll
.endif
        ; ---- link housekeeping (never while the IRQ handler is mid-flight)
        php                     ; a packet's bytes are <10 ms apart: two
        sei                     ; silent frames mean the fragment is dead
        inc rx_idle             ; (masked: a byte arriving in between must
        lda rx_idle             ;  not have its packet thrown away)
        cmp #2
        bcc :+
        lda #0
        sta rx_n
:       plp
        bit cfg_role
        bmi @client
        inc since_rx            ; host: nothing heard for a while -> (re)send
        lda since_rx
        cmp #T_O
        bcc @busy
        lda tx_busy             ; never talk over our own transmission ...
        ora rx_n                ; ... or a packet that is still arriving
        bne @busy
        sta since_rx            ; A = 0
        php
        sei
        lda tx_valid
        bne :+
        jsr build
:       jsr tx_start
        plp
        jmp @busy
@client:
        lda got_data            ; client: until the host's first packet
        bne @busy               ;   arrives, keep announcing we are ready
        inc since_rx
        lda since_rx
        and #$1F
        bne @busy
        lda tx_busy
        ora rx_n
        bne @busy
        php
        sei
        lda #T_START
        ldy #0
        jsr finish_pkt
        lda #0
        sta tx_valid
        jsr tx_start
        plp
@busy:
.if TEST
        lda TEST_STOP_EN        ; rig: freeze both machines on the same tick
        beq :+                  ;   so their memory can be compared
        lda tick
        cmp TEST_STOP
        beq @stall
:
.endif
        ; ---- may this tick run? we need the peer's input for it ...
        lda r_wr
        cmp tick
        bne :+
@stall: inc G_BUSY              ; what the end of a real tick does
        rts
:       lda l_wr                ; ... and room to queue ours
        sec
        sbc l_base
        cmp #56
        bcs @stall

        jsr sample              ; our controller now -> tick + delay
        pha
        lda l_wr
        and #$3F
        tax
        pla
        sta LRING,x
        inc l_wr

        lda tick                ; both players' inputs for THIS tick
        and #$3F
        tax
        lda LRING,x
        ldy RRING,x
        bit cfg_role
        bpl :+
        sta h_tmp               ; client: we are player 2
        tya
        ldy h_tmp
:       sta h_tmp               ; A = player 1, Y = player 2
        lda #7
        sta v_cons
        lda #$FF
        sta v_irqst
        tya
        ldx #1
        jsr one
        asl a
        asl a
        asl a
        asl a
        sta v_porta
        lda h_tmp
        ldx #0
        jsr one
        ora v_porta
        sta v_porta
        lda v_cons              ; console keys: either player may press them
        sta v_consol

        ; facing: the stock game latches request -> current from a display
        ; interrupt (timing differs per machine); do it per tick instead
        lda G_FACE_REQ1
        cmp G_FACE_CUR1
        beq :+
        sta G_FACE_CUR1
        dec G_FACE_FLAG
:       lda G_FACE_REQ2
        cmp G_FACE_CUR2
        beq :+
        sta G_FACE_CUR2
        dec G_FACE_FLAG
:
        jsr prng                ; stir once per tick
        inc tick
        inc G_TICKCNT           ; the two instructions we displaced
        lda #$00
        jmp G_TICK_RESUME

; ---------------------------------------------------------------------------
; prng - stands in for every `LDA RANDOM` in the game. 16-bit Galois LFSR.
; Returns A (flags set), preserves X and Y. rnd0/rnd1 double as the operands
; of the game's `CMP RANDOM` / `LDY RANDOM` sites.
; ---------------------------------------------------------------------------
prng:   lda rnd0
        asl a
        rol rnd1
        bcc :+
        eor #$2D
:       sta rnd0
        eor rnd1
        rts

; ---------------------------------------------------------------------------
; protocol - runs in IRQ context (or, in the test build, from the hook)
; ---------------------------------------------------------------------------
; rx_byte: A = received byte
rx_byte:
        ldx rx_n
        cpx #9                  ; overflow / "bad until idle" marker
        bcs @ret
        sta rxbuf,x
        inx
        stx rx_n
        ldy #0
        sty rx_idle
        cpx #1
        bne :+
        lsr a                   ; header: body length -> total length
        lsr a
        lsr a
        and #7
        clc
        adc #2
        sta rx_need
:       cpx rx_need
        bcc @ret
        sty rx_n                ; complete (Y = 0)
        dex
        stx tmp_n               ; index of the checksum byte
        txa
        tay
        ldx #rxbuf-txbuf
        jsr csum
        ldx tmp_n
        cmp rxbuf,x
        bne @bad
        lda net_mode
        bne pkt_rx
        inc pkt_ready           ; lobby: just flag it
@ret:   rts
@bad:   inc err_cnt             ; (diagnostic: damaged packets seen)
        rts

; pkt_rx: a valid packet is in rxbuf (game mode)
pkt_rx: lda rxbuf
        and #$07
        bne @out                ; only DATA matters once the game runs
        lda rxbuf
        and #$80
        bit cfg_role
        bmi @client
        cmp seq                 ; host: the answer to the packet in flight?
        bne @out
        eor #$80
        sta seq
        bpl @accept
        bmi @accept
@client:
        cmp seq                 ; client: seen this one already?
        bne @new
        lda tx_valid            ;   yes - our answer got lost, repeat it
        beq @out
        jmp tx_start
@new:   sta seq
        lda #1
        sta got_data
@accept:
        lda l_base              ; our last packet is acknowledged
        clc
        adc tx_cnt
        sta l_base
        ; ---- unpack the peer's inputs into RRING
        lda rxbuf
        lsr a
        lsr a
        lsr a
        and #7
        beq @sent
        sta tmp_n
        ldy #1
@item:  lda rxbuf,y
        and #$1F
        sta tmp_code
        lda rxbuf,y
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        sta tmp_run
@rep:   lda r_wr
        and #$3F
        tax
        lda tmp_code
        sta RRING,x
        inc r_wr
        dec tmp_run
        bpl @rep
        iny
        dec tmp_n
        bne @item
@sent:  lda #0
        sta since_rx
        jsr build               ; answer / carry on at once
        jmp tx_start
@out:   rts

; build: pack our unacknowledged inputs [l_base, l_wr) into txbuf
build:  ldy #0
        lda l_base
        sta tmp_x
@next:  lda tmp_x
        cmp l_wr
        beq @fin
        cpy #4                  ; at most 4 runs per packet
        bcs @fin
        and #$3F
        tax
        lda LRING,x
        sta tmp_code
        lda #0
        sta tmp_run
@run:   inc tmp_x
        lda tmp_x
        cmp l_wr
        beq @emit
        and #$3F
        tax
        lda LRING,x
        cmp tmp_code
        bne @emit
        lda tmp_run
        cmp #7
        bcs @emit
        inc tmp_run
        bne @run
@emit:  lda tmp_run
        asl a
        asl a
        asl a
        asl a
        asl a
        ora tmp_code
        sta txbuf+1,y
        iny
        bne @next
@fin:   lda tmp_x
        sec
        sbc l_base
        sta tx_cnt
        tya
        asl a
        asl a
        asl a
        ora seq                 ; type DATA = 0
        ; fall through

; finish_pkt: A = header, Y = body length (body already in txbuf+1..)
finish_pkt:
        sta txbuf
        iny
        sty tmp_n               ; bytes covered by the checksum
        ldx #0
        jsr csum
        ldx tmp_n
        sta txbuf,x
        inx
        stx tx_len
        lda #1
        sta tx_valid
        rts

; csum: X = offset into txbuf/rxbuf pair, Y = count -> A
csum:   lda #$A5
:       eor txbuf,x
        asl a
        adc #$1D
        inx
        dey
        bne :-
        rts

.if TEST
; ---------------------------------------------------------------------------
; test transport: RAM mailboxes instead of the serial port
; ---------------------------------------------------------------------------
tx_start:
        ldx tx_len
        stx TXBOX
:       lda txbuf-1,x
        sta TXBOX,x
        dex
        bne :-
        rts

test_poll:
        lda RXBOX
        beq @none
        lda #0
        sta tmp_i
:       ldx tmp_i
        lda RXBOX+1,x
        jsr rx_byte
        inc tmp_i
        lda tmp_i
        cmp RXBOX
        bcc :-
        lda #0
        sta RXBOX
@none:  rts

hw_init:
        inc hw_ready
        rts

irq:    rti

.else
; ---------------------------------------------------------------------------
; serial port (POKEY) - interrupt driven, half duplex
; ---------------------------------------------------------------------------
; tx_start: send txbuf[0..tx_len). Call with IRQs masked.
tx_start:
        lda #SK_SEND
        sta SKCTL
        sta tx_busy
        lda #1
        sta tx_pos
        lda #IRQ_SEROUT         ; arm the "next byte" interrupt BEFORE the
        sta irqen               ;   first byte goes out: POKEY raises it the
        sta IRQEN               ;   moment that byte enters the shifter, and
        lda txbuf               ;   an event that finds its enable bit clear
        sta SEROUT              ;   is lost for good
        rts

; hw_init: (re)claim POKEY after the game's own init wiped it
hw_init:
        lda #$28                ; voice 3 at 1.79 MHz, 3+4 joined: baud clock
        sta AUDCTL
        lda cfg_baud
        sta AUDF3
        lda #1
        sta AUDF4
        lda #0
        sta AUDC3
        sta AUDC4
        sta IRQEN
        sta tx_busy
        sta rx_n
        lda #SK_RECV
        sta SKCTL
        sta SKRES
        lda #IRQ_SERIN
        sta irqen
        sta IRQEN
        inc hw_ready
        rts

; irq: the only IRQ sources we enable are the three serial ones
irq:    inc in_irq
        pha
        txa
        pha
        tya
        pha
        lda #IRQ_SERIN
        bit irqen
        beq @n1
        bit IRQST               ; 0 = pending
        bne @n1
        lda #0                  ; acknowledge, re-arm
        sta IRQEN
        lda irqen
        sta IRQEN
        lda SKSTAT              ; framing (bit 7) / overrun (bit 5): 0 = error
        sta SKRES
        and #$A0
        cmp #$A0
        beq :+
        lda #$80                ; poison the packet until the line goes idle
        sta rx_n
        inc err_cnt
:       lda SERIN
        jsr rx_byte
        jmp @done
@n1:    lda #IRQ_SEROUT
        bit irqen
        beq @n2
        bit IRQST
        bne @n2
        ldx tx_pos
        cpx tx_len
        bcs @last
        lda #0
        sta IRQEN
        lda #IRQ_SEROUT
        sta IRQEN
        lda txbuf,x
        sta SEROUT
        inc tx_pos
        bne @done
@last:  lda #IRQ_XMTDON         ; last byte is in the shifter: wait for it
        sta irqen
        sta IRQEN
        bne @done
@n2:    lda #IRQ_XMTDON
        bit irqen
        beq @done
        bit IRQST
        bne @done
        lda #SK_RECV            ; line turnaround: back to listening
        sta SKCTL
        sta SKRES
        lda #IRQ_SERIN          ; (one write: drops XMTDON, arms receive)
        sta irqen
        sta IRQEN
        lda #0
        sta tx_busy
        sta rx_n
@done:  dec in_irq
        ldx dli_pending         ; a display kernel left its closing routine
        beq @exit               ;   to us (see dli_a): run it now, with IRQs
        lda #0                  ;   enabled - our own work is finished
        sta dli_pending
        cli
        dex
        bne :+
        jsr G_DLI_WORK_1
        jmp @exit
:       jsr G_DLI_WORK_2
@exit:  pla
        tay
        pla
        tax
        pla
        rti
.endif

; ===========================================================================
; Second resident chunk. Runs at $0224 (OS variable space that is dead once
; the game owns the machine); the lobby copies it there just before launch.
; ===========================================================================
        .segment "RES2"

; ---------------------------------------------------------------------------
; one - decode one player's input code.
;   in : A = code, X = player (0/1)
;   out: A = joystick nibble for the game; v_trig0,x set; keys -> v_cons /
;        v_kbcode + v_irqst
; ---------------------------------------------------------------------------
one:    tay
        and #$10
        eor #$10
        sta v_trig0,x           ; 0 = pressed, like TRIGn
        tya
        and #$0F
        cmp #4
        bcc @cons
        tay
        and #$03
        beq @key
        lda #0                  ; an ordinary stick position
        sta prev,x
        tya
        rts
@cons:  tay                     ; 1..3 = START / SELECT / OPTION held
        beq @none
        lda v_cons
        and consmask-1,y
        sta v_cons
@none:  lda #0
        sta prev,x
        lda #NEUTRAL
        rts
@key:   tya                     ; 4/8/12 = a key; report the press once
        cmp prev,x
        beq @held
        sta prev,x
        lsr a
        lsr a
        tay
        lda keytab-1,y
        sta v_kbcode
        lda #$BF                ; "keyboard IRQ pending" as IRQST shows it
        sta v_irqst
@held:  lda #NEUTRAL
        rts

consmask:   .byte %110, %101, %011      ; START, SELECT, OPTION (0 = pressed)
keytab:     .byte $21, $1C, $0C         ; SPACE, ESC, RETURN keycodes

; ---------------------------------------------------------------------------
; sample - read the local controller (always joystick port 1) -> input code
; ---------------------------------------------------------------------------
sample: lda CONSOL
        and #7
        cmp #7
        beq @nocon
        ldx #1
        lsr a
        bcc @sp                 ; START
        inx
        lsr a
        bcc @sp                 ; SELECT
        inx                     ; OPTION
@sp:    txa
        rts
@nocon: lda SKSTAT
        and #$04                ; 0 = a key is down
        bne @stick
        lda KBCODE
        and #$3F
        ldx #4
        cmp #$21
        beq @sp
        ldx #8
        cmp #$1C
        beq @sp
        ldx #12
        cmp #$0C
        beq @sp
@stick: lda PORTA
        and #$0F
        tax
        and #$03                ; up+down or left+right at once can't happen
        beq @bad                ; on a real stick; those codes mean keys
        txa
        and #$0C
        beq @bad
        txa
        bne @trig
@bad:   lda #NEUTRAL
@trig:  ldx TRIG0
        bne :+
        ora #$10
:       rts

; ---------------------------------------------------------------------------
; mix - replaces the game's 8-register sound commit. Voices 3+4 are the serial
; baud generator now, so the two effect voices borrow voice 2 when they sound.
; ---------------------------------------------------------------------------
mix:    lda G_V1F
        sta AUDF1
        lda G_V1C
        sta AUDC1
        lda G_V3C
        and #$0F
        beq :+
        lda G_V3F
        sta AUDF2
        lda G_V3C
        sta AUDC2
        rts
:       lda G_V4C
        and #$0F
        beq :+
        lda G_V4F
        sta AUDF2
        lda G_V4C
        sta AUDC2
        rts
:       lda G_V2F
        sta AUDF2
        lda G_V2C
        sta AUDC2
        rts

; ---- state: bottom of the stack page, zeroed and preset by the lobby --------
        .segment "STATE"
hw_ready:   .res 1
in_irq:     .res 1
irqen:      .res 1
net_mode:   .res 1         ; 0 = lobby (flag packets), 1 = game
pkt_ready:  .res 1
tick:       .res 1         ; next tick to run
l_wr:       .res 1         ; next free slot for our inputs
l_base:     .res 1         ; first of ours the peer has not acknowledged
r_wr:       .res 1         ; first tick whose peer input we lack
seq:        .res 1         ; host: seq in flight; client: last seq seen
got_data:   .res 1
since_rx:   .res 1
tx_valid:   .res 1
tx_busy:    .res 1
tx_cnt:     .res 1         ; ticks carried by the packet in txbuf
tx_len:     .res 1
tx_pos:     .res 1
rx_n:       .res 1
rx_need:    .res 1
rx_idle:    .res 1
prev:       .res 2         ; last key code per player (edge detect)
tmp_n:      .res 1
tmp_x:      .res 1
tmp_i:      .res 1
tmp_code:   .res 1
tmp_run:    .res 1
dli_pending:.res 1         ; display routine owed by the IRQ handler (0/1/2)
h_tmp:      .res 1         ; the hook's own scratch: tmp_* belong to the
                           ;   protocol code, which runs in IRQ context
v_cons:     .res 1
; what the patched game reads instead of the hardware
v_porta:    .res 1
v_trig0:    .res 1
v_trig1:    .res 1
v_consol:   .res 1
v_kbcode:   .res 1
v_irqst:    .res 1
err_cnt:    .res 1         ; damaged bytes/packets (diagnostic only)
sink:       .res 1         ; writes we do not want reach POKEY land here
txbuf:      .res 10
rxbuf:      .res 10
