; ============================================================================
; test_netgame.s  -  Executable unit tests for the link protocol logic.
; Runs under cc65's sim65 (a real 6502 simulator).  _main returns 0 if every
; assertion passes, else the id of the first failing check (visible as the
; process exit code, which tools/run_tests.sh checks).
;
; Only the pure, non-I/O routines are exercised (checksum, packet build/parse,
; dead reckoning); nothing here touches CIO, so no FujiNet/OS is needed.
; ============================================================================

        .include "fujinet.inc"

        .import   ng_build_tx, ng_apply_rx, ng_csum, ng_deadreckon
        .importzp ng_ptr
        .import   txbuf, rxbuf
        .import   loc_xi, loc_xf, loc_yi, loc_yf, loc_vx, loc_vy, loc_hdg
        .import   loc_flags, loc_event
        .import   rem_xi, rem_xf, rem_yi, rem_yf, rem_vx, rem_vy, rem_hdg
        .import   rem_flags, ball_x, ball_y, ball_st
        .import   tx_seq, rx_seq, peer_ack, link_up

        .export   _main

        .segment "ZEROPAGE"
failcode:   .res 1

        .segment "CODE"

; record_fail: first failure wins; A = check id.
.proc record_fail
        ldx failcode
        bne :+                  ; already recorded one
        sta failcode
:       rts
.endproc

; check_eq: compare A with the byte at (address in checkptr); on mismatch
; record failure id in Y. Simpler inline macro instead:
.macro EXPECT sym, val, id
        lda sym
        cmp #val
        beq :+
        lda #id
        jsr record_fail
:
.endmacro

.proc _main
        lda #0
        sta failcode

        ; ---- fixture: known local state ----
        jsr zero_state
        lda #PROTO_MAGIC        ; (not needed, ng sets it) - keep tidy
        lda #$11
        sta loc_xi
        lda #$22
        sta loc_xf
        lda #$33
        sta loc_yi
        lda #$44
        sta loc_yf
        lda #$05
        sta loc_vx
        lda #$FB                ; -5
        sta loc_vy
        lda #$40
        sta loc_hdg
        lda #FLAG_HOST
        sta loc_flags
        lda #$00
        sta tx_seq              ; ng_build_tx pre-increments -> seq becomes 1

        ; ======== Test 1: ng_build_tx fills the packet ========
        jsr ng_build_tx
        EXPECT txbuf+PKT_MAGIC, PROTO_MAGIC, 1
        EXPECT txbuf+PKT_SEQ,   $01,         2
        EXPECT txbuf+PKT_RFX,   $11,         3
        EXPECT txbuf+PKT_RFXF,  $22,         4
        EXPECT txbuf+PKT_RFY,   $33,         5
        EXPECT txbuf+PKT_RFVX,  $05,         6
        EXPECT txbuf+PKT_RFVY,  $FB,         7
        EXPECT txbuf+PKT_RFHDG, $40,         8
        EXPECT txbuf+PKT_FLAGS, FLAG_HOST,   9

        ; ======== Test 2: checksum is self-consistent ========
        ; recompute XOR of bytes 0..14 over txbuf and compare to stored csum
        lda #<txbuf
        sta ng_ptr
        lda #>txbuf
        sta ng_ptr+1
        jsr ng_csum
        cmp txbuf+PKT_CSUM
        beq :+
        lda #10
        jsr record_fail
:

        ; ======== Test 3: valid packet round-trips into rem_* ========
        ; copy txbuf -> rxbuf (a "received" packet from the host peer)
        ldy #PKT_LEN-1
@cp:    lda txbuf,y
        sta rxbuf,y
        dey
        bpl @cp
        lda #0
        sta link_up
        jsr zero_remote
        jsr ng_apply_rx
        EXPECT rem_xi,  $11, 11
        EXPECT rem_xf,  $22, 12
        EXPECT rem_yi,  $33, 13
        EXPECT rem_vx,  $05, 14
        EXPECT rem_vy,  $FB, 15
        EXPECT rem_hdg, $40, 16
        EXPECT link_up, $01, 17

        ; ======== Test 4: corrupt checksum is rejected ========
        inc rxbuf+PKT_CSUM      ; break integrity
        lda #0
        sta link_up
        jsr zero_remote
        jsr ng_apply_rx
        EXPECT link_up, $00, 18 ; must NOT have accepted
        EXPECT rem_xi,  $00, 19 ; rem left untouched

        ; ======== Test 5: bad magic is rejected ========
        dec rxbuf+PKT_CSUM      ; restore good checksum
        lda #$00
        sta rxbuf+PKT_MAGIC     ; wrong magic
        lda #0
        sta link_up
        jsr ng_apply_rx
        EXPECT link_up, $00, 20

        ; ======== Test 6: dead reckoning, positive velocity ========
        lda #$10
        sta rem_xi
        lda #$00
        sta rem_xf
        lda #$02
        sta rem_vx
        lda #$00                ; freeze Y
        sta rem_vy
        lda #$20
        sta rem_yi
        lda #$00
        sta rem_yf
        jsr ng_deadreckon
        EXPECT rem_xf, $02, 21
        EXPECT rem_xi, $10, 22

        ; ======== Test 7: dead reckoning, negative velocity + borrow ========
        lda #$10
        sta rem_xi
        lda #$01
        sta rem_xf
        lda #$FE                ; -2
        sta rem_vx
        lda #$00
        sta rem_vy
        jsr ng_deadreckon
        EXPECT rem_xf, $FF, 23  ; $1001 - 2 = $0FFF
        EXPECT rem_xi, $0F, 24

        ; ---- done: return failcode as exit status ----
        lda failcode
        ldx #0
        rts
.endproc

; zero all shared state bytes we rely on
.proc zero_state
        lda #0
        sta loc_xi
        sta loc_xf
        sta loc_yi
        sta loc_yf
        sta loc_vx
        sta loc_vy
        sta loc_hdg
        sta loc_flags
        sta loc_event
        sta ball_x
        sta ball_y
        sta ball_st
        sta tx_seq
        sta rx_seq
        sta peer_ack
        sta link_up
        ; fall through to zero_remote
.endproc
.proc zero_remote
        lda #0
        sta rem_xi
        sta rem_xf
        sta rem_yi
        sta rem_yf
        sta rem_vx
        sta rem_vy
        sta rem_hdg
        sta rem_flags
        rts
.endproc
