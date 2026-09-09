; ============================================================================
; ncio.s  -  Low-level FujiNet "N:" access through CIO
; ----------------------------------------------------------------------------
; Thin, allocation-free wrappers around the six CIO operations the game link
; needs: OPEN, CLOSE, STATUS (bytes-waiting), block GET, block PUT.
;
; Design rules that matter for a 60 Hz game:
;   * Nothing here ever spins waiting for the network.  net_poll returns
;     immediately with however many bytes are currently buffered.
;   * net_get only ever asks for bytes STATUS already reported as waiting, so
;     the GET returns at once and never stalls the frame.
;   * All routines preserve the caller's discipline of "params in ZP + A",
;     and clobber only A/X/Y.
;
; Calling convention:
;   net_ptr (ZP word) points at the URL string (net_open) or the data buffer
;   (net_get / net_put).  A carries the byte count for get/put.  On return A
;   holds the CIO status byte (STAT_OK = success) and the CPU Z flag is set
;   when A = STAT_OK, so callers can `jsr net_x` / `bne error`.
; ============================================================================

        .include "atari.inc"
        .include "fujinet.inc"

        .exportzp net_ptr
        .export   net_open, net_close, net_poll, net_get, net_put
        .export   net_bytes_waiting

; ---- zero page -----------------------------------------------------------
        .segment "ZEROPAGE"
net_ptr:            .res 2      ; pointer param (URL or buffer)

; ---- state ---------------------------------------------------------------
        .segment "BSS"
net_bytes_waiting:  .res 2      ; last STATUS result, low/high

        .segment "CODE"

; --------------------------------------------------------------------------
; net_open  -  OPEN the N: link.
;   in : net_ptr -> EOL($9B)-terminated URL, A = open mode (e.g. OPEN_UPDATE)
;   out: A = CIO status, Z set on success
; --------------------------------------------------------------------------
.proc net_open
        pha                     ; save mode
        ldx #NET_IOCBX
        ; buffer address = URL pointer
        lda net_ptr
        sta IOCB0+ICBAL,x
        lda net_ptr+1
        sta IOCB0+ICBAH,x
        ; a generous length; CIO parses the name up to EOL regardless
        lda #$FF
        sta IOCB0+ICBLL,x
        lda #$00
        sta IOCB0+ICBLH,x
        pla                     ; restore mode
        sta IOCB0+ICAX1,x       ; aux1 = direction
        lda #$00
        sta IOCB0+ICAX2,x       ; aux2 = 0 (no translation)
        lda #CMD_OPEN
        sta IOCB0+ICCMD,x
        jsr CIOV
        ; return status: CIO leaves it in Y and in ICSTA; normalise into A
        lda IOCB0+ICSTA,x
        cmp #STAT_OK            ; sets Z when OK
        rts
.endproc

; --------------------------------------------------------------------------
; net_close  -  CLOSE the N: link (safe to call even if not open).
;   out: A = CIO status
; --------------------------------------------------------------------------
.proc net_close
        ldx #NET_IOCBX
        lda #CMD_CLOSE
        sta IOCB0+ICCMD,x
        jsr CIOV
        lda IOCB0+ICSTA,x
        cmp #STAT_OK
        rts
.endproc

; --------------------------------------------------------------------------
; net_poll  -  refresh DVSTAT and cache bytes-waiting.
;   Non-blocking.  After the call, net_bytes_waiting (word) and A/X = lo/hi
;   hold how many bytes the N: device currently has buffered for us.
;   Z flag reflects (bytes_waiting_low == 0 && we did the status ok)?  No -
;   callers should test net_bytes_waiting; A/X carry the count for convenience.
; --------------------------------------------------------------------------
.proc net_poll
        ldx #NET_IOCBX
        lda #CMD_STATUS
        sta IOCB0+ICCMD,x
        jsr CIOV
        ; N: handler has now written bytes-waiting into DVSTAT
        lda DVSTAT_BW_L
        sta net_bytes_waiting
        lda DVSTAT_BW_H
        sta net_bytes_waiting+1
        ldx net_bytes_waiting+1
        lda net_bytes_waiting
        rts
.endproc

; --------------------------------------------------------------------------
; net_get  -  block GET of A bytes into net_ptr buffer.
;   in : net_ptr -> buffer, A = byte count (1..255)
;   out: A = CIO status, Z set on success.  ICBLL after the call holds the
;        count actually transferred (CIO convention).
;   Only call for counts STATUS already reported waiting, so it never blocks.
; --------------------------------------------------------------------------
.proc net_get
        pha                     ; save count
        ldx #NET_IOCBX
        lda net_ptr
        sta IOCB0+ICBAL,x
        lda net_ptr+1
        sta IOCB0+ICBAH,x
        pla
        sta IOCB0+ICBLL,x
        lda #$00
        sta IOCB0+ICBLH,x
        lda #CMD_GETCHR         ; get characters / block (no EOL processing)
        sta IOCB0+ICCMD,x
        jsr CIOV
        lda IOCB0+ICSTA,x
        cmp #STAT_OK
        rts
.endproc

; --------------------------------------------------------------------------
; net_put  -  block PUT of A bytes from net_ptr buffer.
;   in : net_ptr -> buffer, A = byte count (1..255)
;   out: A = CIO status, Z set on success
; --------------------------------------------------------------------------
.proc net_put
        pha
        ldx #NET_IOCBX
        lda net_ptr
        sta IOCB0+ICBAL,x
        lda net_ptr+1
        sta IOCB0+ICBAH,x
        pla
        sta IOCB0+ICBLL,x
        lda #$00
        sta IOCB0+ICBLH,x
        lda #CMD_PUTCHR         ; put characters / block (no EOL added)
        sta IOCB0+ICCMD,x
        jsr CIOV
        lda IOCB0+ICSTA,x
        cmp #STAT_OK
        rts
.endproc
