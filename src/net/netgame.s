; ============================================================================
; netgame.s  -  Ballblazer link protocol: state exchange + dead reckoning
; ----------------------------------------------------------------------------
; Sits on top of ncio.s.  Owns a small shared-state block that both endpoints
; keep loosely synchronised:
;
;   loc_*   the LOCAL rotofoil - authoritative here, simulated with zero input
;           latency by whoever calls this module (the demo, or the game).
;   rem_*   the REMOTE rotofoil - a mirror driven by received packets and
;           extrapolated (dead-reckoned) from its last known velocity between
;           packets, so it keeps moving smoothly at 60 Hz on ~20 Hz updates.
;   ball_*  the plasmorb - single authority: whichever endpoint is host owns
;           it; the other mirrors what the host sends.
;
; The GAME INTEGRATION step (Phase 3) does not change this file.  It simply
; copies the game's real per-frame variables into loc_*/ball_* before calling
; ng_tick, and copies rem_*/ball_* back out into the variables the renderer and
; the (now removed) droid-AI input path used to drive.  See docs/04-netcode.md.
;
; Contract: caller writes loc_* for this frame, then `jsr ng_tick`, then reads
; rem_*/ball_*.  ng_tick never blocks on I/O.
; ============================================================================

        .include "atari.inc"
        .include "fujinet.inc"

        .importzp net_ptr
        .import   net_poll, net_get, net_put
        .import   net_bytes_waiting

        .exportzp ng_ptr
        .export   ng_init, ng_tick, ng_send, ng_recv
        ; shared state (read/written by the caller)
        .export   loc_xi, loc_xf, loc_yi, loc_yf, loc_vx, loc_vy, loc_hdg
        .export   loc_flags, loc_event
        .export   rem_xi, rem_xf, rem_yi, rem_yf, rem_vx, rem_vy, rem_hdg
        .export   rem_flags
        .export   ball_x, ball_y, ball_st
        .export   tx_seq, rx_seq, peer_ack, link_up

        ; white-box hooks for the sim65 unit tests (never exported in the
        ; production build; enable with -DUNIT_TEST when assembling for sim65)
        .ifdef UNIT_TEST
        .export   ng_build_tx, ng_apply_rx, ng_csum, ng_deadreckon
        .export   txbuf, rxbuf
        .endif

        .segment "ZEROPAGE"
ng_ptr:     .res 2              ; scratch pointer for checksum walk

        .segment "BSS"
; --- local rotofoil (authoritative here) ---
loc_xi:     .res 1
loc_xf:     .res 1
loc_yi:     .res 1
loc_yf:     .res 1
loc_vx:     .res 1
loc_vy:     .res 1
loc_hdg:    .res 1
loc_flags:  .res 1              ; caller sets FLAG_HOST / FLAG_FIRE / ... here
loc_event:  .res 1
; --- remote rotofoil (mirror) ---
rem_xi:     .res 1
rem_xf:     .res 1
rem_yi:     .res 1
rem_yf:     .res 1
rem_vx:     .res 1
rem_vy:     .res 1
rem_hdg:    .res 1
rem_flags:  .res 1
; --- plasmorb (host-authoritative) ---
ball_x:     .res 1
ball_y:     .res 1
ball_st:    .res 1
; --- link bookkeeping ---
tx_seq:     .res 1              ; our outgoing sequence
rx_seq:     .res 1              ; latest peer sequence we applied
peer_ack:   .res 1              ; latest ack the peer reported (our seq seen)
link_up:    .res 1              ; nonzero once a valid packet has arrived
frame_div:  .res 1              ; counts down to the next send

txbuf:      .res PKT_LEN
rxbuf:      .res PKT_LEN

        .segment "CODE"

; --------------------------------------------------------------------------
; ng_init  -  reset link state.  Caller still sets loc_flags (e.g. FLAG_HOST).
; --------------------------------------------------------------------------
.proc ng_init
        lda #0
        sta tx_seq
        sta rx_seq
        sta peer_ack
        sta link_up
        sta loc_event
        sta ball_st
        lda #1                  ; send on the very first tick
        sta frame_div
        rts
.endproc

; --------------------------------------------------------------------------
; ng_tick  -  once per game frame: drain inbound, extrapolate remote, and
; (every SEND_EVERY frames) transmit our state.  Never blocks.
; --------------------------------------------------------------------------
.proc ng_tick
        jsr ng_recv             ; apply newest inbound state
        jsr ng_deadreckon       ; extrapolate remote between packets
        dec frame_div
        bne :+
        lda #SEND_EVERY
        sta frame_div
        jsr ng_send
:       rts
.endproc

; --------------------------------------------------------------------------
; ng_recv  -  non-blocking drain: apply every full packet currently buffered,
; newest wins.  Bounded by the byte count STATUS reported, so it terminates.
; --------------------------------------------------------------------------
.proc ng_recv
        jsr net_poll            ; -> net_bytes_waiting
drain:
        lda net_bytes_waiting+1
        bne have                ; >= 256 bytes: definitely a full packet
        lda net_bytes_waiting
        cmp #PKT_LEN
        bcc done                ; fewer than one packet buffered
have:
        lda #<rxbuf
        sta net_ptr
        lda #>rxbuf
        sta net_ptr+1
        lda #PKT_LEN
        jsr net_get
        bne done                ; read error -> stop this frame
        jsr ng_apply_rx
        ; net_bytes_waiting -= PKT_LEN
        lda net_bytes_waiting
        sec
        sbc #PKT_LEN
        sta net_bytes_waiting
        lda net_bytes_waiting+1
        sbc #0
        sta net_bytes_waiting+1
        jmp drain
done:
        rts
.endproc

; --------------------------------------------------------------------------
; ng_apply_rx  -  validate rxbuf and copy it into rem_*/ball_*.
; --------------------------------------------------------------------------
.proc ng_apply_rx
        lda rxbuf+PKT_MAGIC
        cmp #PROTO_MAGIC
        bne bad
        ; verify checksum
        lda #<rxbuf
        sta ng_ptr
        lda #>rxbuf
        sta ng_ptr+1
        jsr ng_csum             ; A = XOR of bytes 0..14
        cmp rxbuf+PKT_CSUM
        bne bad
        ; remote rotofoil
        lda rxbuf+PKT_RFX
        sta rem_xi
        lda rxbuf+PKT_RFXF
        sta rem_xf
        lda rxbuf+PKT_RFY
        sta rem_yi
        lda rxbuf+PKT_RFYF
        sta rem_yf
        lda rxbuf+PKT_RFVX
        sta rem_vx
        lda rxbuf+PKT_RFVY
        sta rem_vy
        lda rxbuf+PKT_RFHDG
        sta rem_hdg
        lda rxbuf+PKT_FLAGS
        sta rem_flags
        ; ball: trust it only from the ball authority (the host)
        and #FLAG_HOST
        beq skipball
        lda rxbuf+PKT_BALLX
        sta ball_x
        lda rxbuf+PKT_BALLY
        sta ball_y
        lda rxbuf+PKT_BALLST
        sta ball_st
skipball:
        lda rxbuf+PKT_SEQ
        sta rx_seq
        lda rxbuf+PKT_ACK
        sta peer_ack
        lda #1
        sta link_up
bad:
        rts
.endproc

; --------------------------------------------------------------------------
; ng_send  -  build txbuf from loc_*/ball_* and PUT it.
; --------------------------------------------------------------------------
.proc ng_send
        jsr ng_build_tx
        lda #<txbuf
        sta net_ptr
        lda #>txbuf
        sta net_ptr+1
        lda #PKT_LEN
        jsr net_put
        rts
.endproc

.proc ng_build_tx
        lda #PROTO_MAGIC
        sta txbuf+PKT_MAGIC
        inc tx_seq
        lda tx_seq
        sta txbuf+PKT_SEQ
        lda rx_seq              ; ack the newest packet we've applied
        sta txbuf+PKT_ACK
        lda loc_flags
        sta txbuf+PKT_FLAGS
        lda loc_xi
        sta txbuf+PKT_RFX
        lda loc_xf
        sta txbuf+PKT_RFXF
        lda loc_yi
        sta txbuf+PKT_RFY
        lda loc_yf
        sta txbuf+PKT_RFYF
        lda loc_vx
        sta txbuf+PKT_RFVX
        lda loc_vy
        sta txbuf+PKT_RFVY
        lda loc_hdg
        sta txbuf+PKT_RFHDG
        lda ball_x
        sta txbuf+PKT_BALLX
        lda ball_y
        sta txbuf+PKT_BALLY
        lda ball_st
        sta txbuf+PKT_BALLST
        lda loc_event
        sta txbuf+PKT_EVENT
        lda #<txbuf
        sta ng_ptr
        lda #>txbuf
        sta ng_ptr+1
        jsr ng_csum
        sta txbuf+PKT_CSUM
        rts
.endproc

; --------------------------------------------------------------------------
; ng_csum  -  A = XOR of bytes [0..PKT_CSUM-1] of the buffer at ng_ptr.
;             Walks indices PKT_CSUM-1 down to 0 (15 bytes: 0..14).
; --------------------------------------------------------------------------
.proc ng_csum
        lda #0
        ldy #PKT_CSUM
csloop:
        dey
        eor (ng_ptr),y
        cpy #0
        bne csloop
        rts
.endproc

; --------------------------------------------------------------------------
; ng_deadreckon  -  advance the remote rotofoil by its last known velocity.
; Position is 16-bit 8.8 fixed point (int:frac); velocity is signed 8-bit
; sub-units per frame, sign-extended into the high byte.  The scale factor
; is a Phase-3 tuning constant matched to the game's real coordinate units.
; --------------------------------------------------------------------------
.proc ng_deadreckon
        ; ---- X axis ----
        ldx #$00
        lda rem_vx
        bpl xpos
        ldx #$FF                ; sign-extend negative velocity
xpos:
        lda rem_xf
        clc
        adc rem_vx
        sta rem_xf
        txa
        adc rem_xi
        sta rem_xi
        ; ---- Y axis ----
        ldx #$00
        lda rem_vy
        bpl ypos
        ldx #$FF
ypos:
        lda rem_yf
        clc
        adc rem_vy
        sta rem_yf
        txa
        adc rem_yi
        sta rem_yi
        rts
.endproc
