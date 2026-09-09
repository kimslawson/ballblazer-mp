; ============================================================================
; netdemo.s  -  Standalone FujiNet link proof-of-concept for Ballblazer-MP
; ----------------------------------------------------------------------------
; NOT the game.  A tiny program that exercises the exact networking path the
; game will use, so the hard part (state exchange over FujiNet) can be proven
; on real hardware / an emulator with a FujiNet, independently of the ROM.
;
; It:
;   1. OPENs the N: link (URL/role from linkcfg.inc).
;   2. Each VBLANK: reads joystick 0, moves a local "rotofoil", runs ng_tick
;      to exchange state, and dead-reckons the remote one.
;   3. Prints a status line (tx/rx sequence, link flag, both positions) to the
;      E: screen once a second, and flashes the background green once a valid
;      packet has been received (red until then).
;   4. OPTION quits cleanly (CLOSE + return to DOS).
;
; Build two copies (ROLE_HOST 1 and 0), run one on each machine, and watch the
; remote position on each screen track the other machine's joystick.
; ============================================================================

        .include "atari.inc"
        .include "fujinet.inc"
        .include "linkcfg.inc"

        .importzp net_ptr
        .import   net_open, net_close
        .importzp ng_ptr
        .import   ng_init, ng_tick
        .import   loc_xi, loc_xf, loc_yi, loc_yf, loc_vx, loc_vy, loc_hdg
        .import   loc_flags
        .import   rem_xi, rem_yi
        .import   tx_seq, rx_seq, link_up

; --- Atari OS symbols used only here ---
STICK0  = $0278             ; joystick 0 shadow: bit0 up,1 down,2 left,3 right (0=on)
COLOR2  = $02C6             ; GR.0 background colour shadow (OS copies to hw each VBLANK)

        .segment "STARTUP"
; Entry point is the first byte of the loaded image -> XEX run address.
main:
        cld
        ; announce which role we are, then open the link
        lda #<msg_banner
        sta net_ptr
        lda #>msg_banner
        sta net_ptr+1
        jsr puts

        lda #<net_url
        sta net_ptr
        lda #>net_url
        sta net_ptr+1
        lda #OPEN_UPDATE
        jsr net_open
        beq opened
        ; open failed -> report and stop
        lda #<msg_openerr
        sta net_ptr
        lda #>msg_openerr
        sta net_ptr+1
        jsr puts
        rts                     ; back to DOS
opened:
        jsr ng_init
        ; set our persistent flags (host bit for the ball authority)
        .if ROLE_HOST
        lda #FLAG_HOST
        .else
        lda #0
        .endif
        sta loc_flags

        ; centre the local rotofoil
        lda #$80
        sta loc_xi
        sta loc_yi
        lda #0
        sta loc_xf
        sta loc_yf
        sta loc_vx
        sta loc_vy
        sta loc_hdg

        lda #0
        sta hud_div

; ---------------- main loop ----------------
loop:
        jsr wait_vblank

        jsr read_stick          ; -> updates loc_vx/vy, integrates loc pos
        jsr ng_tick             ; exchange state (non-blocking)

        ; heartbeat colour: green if we've seen a packet, else red
        lda link_up
        beq @red
        lda #$C4                ; green
        bne @setcol
@red:
        lda #$34                ; red
@setcol:
        sta COLOR2

        ; status HUD ~once per second
        dec hud_div
        bne @nohud
        lda #60
        sta hud_div
        jsr show_status
@nohud:

        ; OPTION quits
        lda CONSOL
        and #CONSOL_OPTION
        bne loop                ; not pressed -> keep looping

        jsr net_close
        lda #<msg_bye
        sta net_ptr
        lda #>msg_bye
        sta net_ptr+1
        jsr puts
        rts                     ; return to DOS

; --------------------------------------------------------------------------
; wait_vblank - block until RTCLOK low byte changes (one TV frame).
; --------------------------------------------------------------------------
.proc wait_vblank
        lda RTCLOK_LO
@w:     cmp RTCLOK_LO
        beq @w
        rts
.endproc

; --------------------------------------------------------------------------
; read_stick - translate joystick 0 into velocity, integrate into position.
; A tiny stand-in for the game's real momentum model; enough to make the
; transmitted state visibly change so the peer's mirror moves.
; --------------------------------------------------------------------------
.proc read_stick
        lda STICK0
        tax                     ; keep raw

        ; X axis: bit2 left (=0 pressed), bit3 right
        lda #0
        sta loc_vx
        txa
        and #%00000100          ; left
        bne @noleft
        lda #$FE                ; -2
        sta loc_vx
@noleft:
        txa
        and #%00001000          ; right
        bne @noright
        lda #$02                ; +2
        sta loc_vx
@noright:

        ; Y axis: bit0 up, bit1 down
        lda #0
        sta loc_vy
        txa
        and #%00000001          ; up
        bne @noup
        lda #$FE                ; -2
        sta loc_vy
@noup:
        txa
        and #%00000010          ; down
        bne @nodown
        lda #$02                ; +2
        sta loc_vy
@nodown:

        ; integrate: loc_x(int:frac) += signext(loc_vx); same for Y
        ldx #0
        lda loc_vx
        bpl @xp
        ldx #$FF
@xp:    lda loc_xf
        clc
        adc loc_vx
        sta loc_xf
        txa
        adc loc_xi
        sta loc_xi

        ldx #0
        lda loc_vy
        bpl @yp
        ldx #$FF
@yp:    lda loc_yf
        clc
        adc loc_vy
        sta loc_yf
        txa
        adc loc_yi
        sta loc_yi
        rts
.endproc

; --------------------------------------------------------------------------
; show_status - print "T=xx R=xx L=x LX=xx LY=xx RX=xx RY=xx" to E:.
; --------------------------------------------------------------------------
.proc show_status
        lda tx_seq
        ldx #hb_tx-statbuf
        jsr put_hex
        lda rx_seq
        ldx #hb_rx-statbuf
        jsr put_hex
        lda link_up
        ldx #hb_lk-statbuf
        jsr put_hex
        lda loc_xi
        ldx #hb_lx-statbuf
        jsr put_hex
        lda loc_yi
        ldx #hb_ly-statbuf
        jsr put_hex
        lda rem_xi
        ldx #hb_rx2-statbuf
        jsr put_hex
        lda rem_yi
        ldx #hb_ry-statbuf
        jsr put_hex
        lda #<statbuf
        sta net_ptr
        lda #>statbuf
        sta net_ptr+1
        jmp puts
.endproc

; put_hex: write A as two ATASCII hex digits into statbuf+X (X,X+1).
.proc put_hex
        pha
        lsr a
        lsr a
        lsr a
        lsr a
        jsr @nyb
        sta statbuf,x
        inx
        pla
        and #$0F
        jsr @nyb
        sta statbuf,x
        rts
@nyb:   cmp #10
        bcc @dig
        clc
        adc #'A'-10
        rts
@dig:   clc
        adc #'0'
        rts
.endproc

; --------------------------------------------------------------------------
; puts - print the EOL($9B)-terminated string at net_ptr to E: (IOCB #0).
; --------------------------------------------------------------------------
.proc puts
        ldx #0                  ; IOCB #0 = E:
        lda net_ptr
        sta IOCB0+ICBAL,x
        lda net_ptr+1
        sta IOCB0+ICBAH,x
        lda #$FF                ; up to 255 chars; PUTREC stops at the EOL
        sta IOCB0+ICBLL,x
        lda #0
        sta IOCB0+ICBLH,x
        lda #CMD_PUTREC
        sta IOCB0+ICCMD,x
        jmp CIOV
.endproc

        .segment "RODATA"
net_url:
        emit_url
msg_banner:
        .if ROLE_HOST
        .byte "BALLBLAZER-MP LINK DEMO  [HOST]", $9B
        .else
        .byte "BALLBLAZER-MP LINK DEMO  [CLIENT]", $9B
        .endif
msg_openerr:
        .byte "N: OPEN FAILED - CHECK FUJINET/URL", $9B
msg_bye:
        .byte "LINK CLOSED.", $9B

        .segment "DATA"
; status line template; the hb_* fields are patched with hex each second.
statbuf:
        .byte "T="
hb_tx:  .byte "00 R="
hb_rx:  .byte "00 L="
hb_lk:  .byte "00 LX="
hb_lx:  .byte "00 LY="
hb_ly:  .byte "00 RX="
hb_rx2: .byte "00 RY="
hb_ry:  .byte "00", $9B

        .segment "BSS"
hud_div:    .res 1
