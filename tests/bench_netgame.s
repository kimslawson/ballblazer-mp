; ============================================================================
; bench_netgame.s - cycle-cost microbench for the per-frame netcode logic.
; Runs one routine ITERS times under sim65 (--cycles); divide the reported
; cycles by ITERS (minus a tiny loop overhead) for per-call cost.
; Select the routine with -DBENCH=1|2|3 :  1=deadreckon 2=build_tx 3=apply_rx
; ============================================================================
        .include "fujinet.inc"
        .import   ng_build_tx, ng_apply_rx, ng_csum, ng_deadreckon
        .importzp ng_ptr
        .import   txbuf, rxbuf
        .import   rem_vx, rem_vy, loc_xi, loc_flags, tx_seq
        .export   _main

ITERS = 1000

        .segment "ZEROPAGE"
cnt:    .res 2

        .segment "CODE"
.proc _main
        ; set up a valid packet in rxbuf (for apply_rx) and some velocity
        lda #5
        sta rem_vx
        lda #$FB
        sta rem_vy
        lda #FLAG_HOST
        sta loc_flags
        jsr ng_build_tx            ; fills txbuf incl. checksum
        ldy #PKT_LEN-1
:       lda txbuf,y
        sta rxbuf,y
        dey
        bpl :-

        lda #<ITERS
        sta cnt
        lda #>ITERS
        sta cnt+1
loop:
.ifdef BENCH_DR
        jsr ng_deadreckon
.endif
.ifdef BENCH_TX
        jsr ng_build_tx
.endif
.ifdef BENCH_RX
        jsr ng_apply_rx
.endif
        ; cnt--
        lda cnt
        bne :+
        dec cnt+1
:       dec cnt
        lda cnt
        ora cnt+1
        bne loop

        lda #0
        ldx #0
        rts
.endproc
