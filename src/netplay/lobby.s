; ============================================================================
; lobby.s - Ballblazer netplay: boot-time front end (runs once, then is gone).
; ----------------------------------------------------------------------------
; Original code. Loaded at $2000 by the patched disk and run INSTEAD of the
; game's own start address. The OS is still alive here, so the screen editor
; does the talking. It:
;   1. checks that the game image in memory is the supported one;
;   2. asks FujiNet for this machine's address and shows it;
;   3. asks for the opponent's address (empty = play the stock local game) and
;      who hosts;
;   4. switches FujiNet into NetStream mode towards the opponent and performs
;      the HELLO / WELCOME / START handshake (which also carries the shared
;      random seed and the input delay);
;   5. patches the game in RAM so its tick goes through resident.s, and starts
;      the game. From the very first tick both machines are in lockstep, so
;      title screen, options and the match itself are all mirrored.
;
; -D TEST=1 skips 1-4 (the rig sets role/seed directly and plays postman).
; ============================================================================

        .include "hw.inc"
        .include "game.inc"

        .import cfg_role, cfg_delay, cfg_baud, rnd0, rnd1
        .import hook, idle, irq, prng, mix, dli_a, dli_b
        .import v_porta, v_trig0, v_trig1, v_consol, v_kbcode, v_irqst, sink
        .import net_mode, pkt_ready, txbuf, rxbuf, finish_pkt, tx_start, tx_busy
        .import hw_init
        .import __STATE_RUN__, __STATE_SIZE__
        .import __RES2_LOAD__, __RES2_RUN__, __RES2_SIZE__
        .import l_wr, l_base, r_wr, seq

.ifndef TEST
TEST = 0
.endif
.ifndef NOFUJI
NOFUJI = 0                      ; 1 = serial-driver test build: no FujiNet
.endif                          ;     commands, role taken from cfg_role

VERSION   = 1                   ; protocol version (HELLO)
PORT      = 6502                ; UDP port, both ends
T_START   = 1
T_HELLO   = 2
T_WELCOME = 3
NEUTRAL   = $0F
LRING     = $0100
RRING     = $0140
EOL       = $9B
RTCLOK    = $14                 ; OS frame counter (low byte)

ptr       = $CB                 ; free zero page while the OS owns the machine
cnt       = $CD

        .segment "LOBBY"

start:
.if TEST = 0
        jsr imgsum
        cmp #G_SUM_LO
        bne @bad
        cpx #G_SUM_HI
        beq @good
@bad:   lda #<m_bad
        ldx #>m_bad
        jsr print
        jsr pause
        jmp G_START
@good:  lda #<m_banner
        ldx #>m_banner
        jsr print

        lda PAL                 ; PAL machines need a different divisor
        and #$0E                ;   for the same 2400 baud
        bne :+
        lda #106
        sta cfg_baud
:
.if NOFUJI = 0
        ; ---- who are we? ask FujiNet for the adapter configuration
        lda #$E8                ; GET ADAPTER CONFIG -> 140 bytes
        ldy #$40                ; read
        ldx #140
        jsr fuji
        bpl :+
        lda #<m_nofuji
        ldx #>m_nofuji
        jsr print
        jsr pause
        jmp G_START
:       lda #<m_myip
        ldx #>m_myip
        jsr print
        ldx #0
:       stx cnt
        lda fbuf+97,x           ; localIP[4]
        jsr decimal
        ldx cnt
        cpx #3
        beq :+
        lda #'.'
        jsr putc
        ldx cnt
        inx
        bne :-
:       lda #EOL
        jsr putc

        ; ---- opponent address
@askip: lda #<m_askip
        ldx #>m_askip
        jsr print
        jsr input
        lda line
        cmp #EOL
        bne :+
        jmp G_START             ; nothing typed: the stock game, untouched
:
        ; ---- role
@askrole:
        lda #<m_askrole
        ldx #>m_askrole
        jsr print
        jsr input2
        lda line2
        ldx #$00
        cmp #'H'
        beq :+
        ldx #$80
        cmp #'J'
        bne @askrole
:       stx cfg_role

        ; ---- NetStream towards the opponent: host string, NUL, flags, AUDF3
        ldx #63
        lda #0
:       sta fbuf,x
        dex
        bpl :-
        ldx #0
:       lda line,x
        cmp #EOL
        beq :+
        sta fbuf,x
        inx
        cpx #60
        bcc :-
:       inx                     ; skip the NUL
        lda PAL
        and #$0E
        bne @ntsc
        lda #$10                ; tell FujiNet this is a PAL machine
        sta fbuf,x
@ntsc:  lda cfg_baud
        sta fbuf+1,x
        lda #>PORT
        sta DAUX1
        lda #<PORT
        sta DAUX2
        lda #$F0                ; ENABLE NETSTREAM <- 64 bytes
        ldy #$80                ; write
        ldx #64
        jsr fuji1
        bpl :+
        lda #<m_nostream
        ldx #>m_nostream
        jsr print
        jsr pause
        jmp G_START
:
.endif
        lda #<m_wait
        ldx #>m_wait
        jsr print

        ; ---- bring the serial link up (lobby mode: packets are just flagged)
        sei
        jsr clear_state
        lda #<irq
        sta VIMIRQ
        lda #>irq
        sta VIMIRQ+1
        lda #$34                ; cassette motor line on: FujiNet's NetStream
        sta PACTL               ;   only relays while it is asserted
        jsr hw_init
        cli
        bit cfg_role
        bmi client

; ---- host: answer HELLO with WELCOME, start on START ----------------------
host:   jsr getpkt              ; -> A = type (waits; START key cancels)
        cmp #T_HELLO
        bne @nothello
        lda rxbuf+1
        cmp #VERSION
        bne @differ
        lda rxbuf+2
        cmp #G_SUM_LO
        bne @differ
        lda rxbuf+3
        cmp #G_SUM_HI
        bne @differ
        lda welcomed            ; seed once; a repeated HELLO gets the same
        bne :+
        lda RANDOM
        ora #1                  ; never an all-zero seed
        sta rnd0
        lda RANDOM
        sta rnd1
        inc welcomed
:       lda rnd0
        sta txbuf+1
        lda rnd1
        sta txbuf+2
        lda cfg_delay
        sta txbuf+3
        lda #T_WELCOME | (3 << 3)
        ldy #3
        jsr send
        jmp host
@differ:
        lda #<m_differ
        ldx #>m_differ
        jsr print
        jmp host
@nothello:
        cmp #T_START
        bne host
        lda welcomed
        beq host
        jmp launch

; ---- client: HELLO until WELCOME arrives, then START ----------------------
client: lda #VERSION
        sta txbuf+1
        lda #G_SUM_LO
        sta txbuf+2
        lda #G_SUM_HI
        sta txbuf+3
        lda #T_HELLO | (3 << 3)
        ldy #3
        jsr send
        lda RTCLOK
        clc
        adc #40                 ; listen ~2/3 s, then say HELLO again
        sta cnt
@listen:
        lda pkt_ready
        bne @got
        jsr cancel
        lda RTCLOK
        cmp cnt
        bne @listen
        beq client
@got:   jsr getpkt
        cmp #T_WELCOME
        bne @listen
        lda rxbuf+1
        sta rnd0
        lda rxbuf+2
        sta rnd1
        lda rxbuf+3
        sta cfg_delay
        lda #T_START
        ldy #0
        jsr send
        lda RTCLOK              ; let it leave the wire
        clc
        adc #3
:       cmp RTCLOK
        bne :-
        ; fall through
.endif

; ---------------------------------------------------------------------------
; launch - arm the lockstep state, patch the game, start it
; ---------------------------------------------------------------------------
launch: sei
        lda #0                  ; the OS is done: no more VBIs through its
        sta NMIEN               ;   page-2 variables, which we now reuse
        ldx #<__RES2_SIZE__     ; second resident chunk -> dead OS variables
:       lda __RES2_LOAD__-1,x
        sta __RES2_RUN__-1,x
        dex
        bne :-
        jsr clear_state
        ldx cfg_delay           ; the first `delay` ticks run on neutral input
        stx l_wr
        stx l_base
        stx r_wr
        lda #NEUTRAL
:       sta LRING-1,x
        sta RRING-1,x
        dex
        bne :-
        lda cfg_role            ; host sends seq 0 first; a client that has
        sta seq                 ;   "last seen" 1 will take it as new
        lda #1
        sta net_mode
        ; ---- patch table: [addr lo][addr hi][n][n bytes] ... [0][0]
        lda #<patches
        sta ptr
        lda #>patches
        sta ptr+1
@entry: ldy #0
        lda (ptr),y
        sta @dst+1
        iny
        ora (ptr),y
        beq @go
        lda (ptr),y
        sta @dst+2
        iny
        lda (ptr),y
        sta cnt
        ldx #0
@byte:  iny
        lda (ptr),y
@dst:   sta $FFFF,x
        inx
        cpx cnt
        bne @byte
        tya                     ; next entry
        sec
        adc ptr
        sta ptr
        bcc @entry
        inc ptr+1
        bne @entry
@go:    jmp G_START

clear_state:
        ldx #<__STATE_SIZE__
        lda #0
:       sta __STATE_RUN__-1,x
        dex
        bne :-
        rts

; ---- patch table -----------------------------------------------------------
.macro  P_JMP site, target      ; 3 bytes: JMP target
        .word site
        .byte 3, $4C
        .word target
.endmacro
.macro  P_JSR site, target      ; 3 bytes: JSR target (was LDA abs)
        .word site
        .byte 3, $20
        .word target
.endmacro
.macro  P_OPND site, target     ; keep the opcode, redirect its abs operand
        .word site+1
        .byte 2
        .word target
.endmacro
.macro  P_NOP10 site
        .word site
        .byte 10, $EA, $EA, $EA, $EA, $EA, $EA, $EA, $EA, $EA, $EA
.endmacro

patches:
        P_JMP   G_TICK, hook            ; every tick goes through the lockstep gate
        P_JMP   G_IDLE_JMP, idle        ; main loop runs with IRQs enabled
        P_JMP   G_SND_COMMIT, mix       ; sound: keep POKEY voices 3+4 for serial
        P_OPND  G_DLI_CALL_1, dli_a     ; long work at the end of each display
        P_OPND  G_DLI_CALL_2, dli_b     ;   kernel runs with IRQs enabled
        P_OPND  G_RD_PORTA_1, v_porta   ; controllers come from the input streams
        P_OPND  G_RD_PORTA_2, v_porta
        P_OPND  G_RD_TRIG0,   v_trig0
        P_OPND  G_RD_TRIG1,   v_trig1
        P_OPND  G_RD_CONSOL,  v_consol
        P_OPND  G_RD_KBCODE,  v_kbcode
        P_OPND  G_RD_IRQST,   v_irqst
        P_OPND  G_WR_IRQEN_A, sink      ; hands off the serial interrupt enables
        P_OPND  G_WR_IRQEN_B, sink
        P_OPND  G_WR_IRQEN_C, sink
        P_OPND  G_WR_SKCTL,   sink      ; ... and the serial mode / baud clock
        P_OPND  G_WR_AUDCTL,  sink
        P_NOP10 G_LATCH_1               ; facing is latched per tick in `hook`
        P_NOP10 G_LATCH_2
        P_OPND  G_BAD_CATCHUP, G_TICK   ; repair the image's damaged call target
        ; POKEY RANDOM -> the shared, seeded generator
        P_JSR   $4CA1, prng
        P_JSR   $4CA6, prng
        P_JSR   $4CFA, prng
        P_JSR   $4D08, prng
        P_JSR   $5232, prng
        P_JSR   $5E24, prng
        P_JSR   $5E30, prng
        P_JSR   $5E3A, prng
        P_JSR   $5E4B, prng
        P_JSR   $5E57, prng
        P_JSR   $5E61, prng
        P_JSR   $5FD1, prng
        P_JSR   $7774, prng
        P_JSR   $77D9, prng
        P_JSR   $77E1, prng
        P_JSR   $7A7E, prng
        P_JSR   $9A58, prng
        P_OPND  $7754, rnd0             ; CMP RANDOM
        P_OPND  $7A6B, rnd0             ; CMP RANDOM
        P_OPND  $7A70, rnd1             ; CMP RANDOM (independent of the one above)
        P_OPND  $9A61, rnd1             ; LDY RANDOM
        .word 0

.if TEST = 0
; ---------------------------------------------------------------------------
; helpers
; ---------------------------------------------------------------------------
; send: A = header, Y = body length (body in txbuf+1..). Waits for the wire.
send:   sei
        jsr finish_pkt
        jsr tx_start
        cli
:       lda tx_busy
        bne :-
        rts

; getpkt: wait for a valid packet, return its type in A. START key cancels.
getpkt: lda pkt_ready
        bne :+
        jsr cancel
        jmp getpkt
:       lda #0
        sta pkt_ready
        lda rxbuf
        and #$07
        rts

; cancel: START pressed -> give up on the network, play locally
cancel: lda CONSOL
        and #1
        bne :+
        sei
        lda #0
        sta IRQEN
        jmp G_START
:       rts

; imgsum: 16-bit sum of $4000-$BBFF -> A (lo), X (hi)
imgsum: lda #$00
        sta ptr
        sta cnt
        sta cnt+1
        lda #$40
        sta ptr+1
        ldy #0
@l:     lda (ptr),y
        clc
        adc cnt
        sta cnt
        bcc :+
        inc cnt+1
:       iny
        bne @l
        inc ptr+1
        lda ptr+1
        cmp #$BC
        bne @l
        lda cnt
        ldx cnt+1
        rts

; fuji: SIO command to the FujiNet control device.
;   A = command, Y = $40 read / $80 write, X = byte count; buffer = fbuf
;   returns with N set on error
fuji:   pha
        lda #0
        sta DAUX1
        sta DAUX2
        pla
fuji1:  sta DCOMND
        sty DSTATS
        stx DBYTLO
        lda #$70
        sta DDEVIC
        lda #1
        sta DUNIT
        lda #<fbuf
        sta DBUFLO
        lda #>fbuf
        sta DBUFHI
        lda #15
        sta DTIMLO
        lda #0
        sta DBYTHI
        jsr SIOV
        tya
        rts

; print: EOL-terminated string at X:A
print:  sta ICBAL
        stx ICBAH
        lda #$09                ; PUT RECORD
        bne cio120
; input: read a line into `line`
input:  lda #<line
        sta ICBAL
        lda #>line
        sta ICBAH
        lda #$05                ; GET RECORD
cio120: sta ICCOM
        lda #120
        sta ICBLL
        lda #0
        sta ICBLH
        tax
        jmp CIOV
input2: lda #<line2
        sta ICBAL
        lda #>line2
        sta ICBAH
        lda #$05
        bne cio120

; putc: one character
putc:   pha
        lda #$0B                ; PUT CHARACTERS, length 0 = the one in A
        sta ICCOM
        lda #0
        sta ICBLL
        sta ICBLH
        tax
        pla
        jmp CIOV

; decimal: print A as 1-3 digits
decimal:
        ldx #0
:       cmp #100
        bcc :+
        sbc #100
        inx
        bne :-
:       pha
        txa
        beq :+
        ora #'0'
        jsr putc
        pla
        ldx #'0'-1
        sec
@t2:    inx
        sbc #10
        bcs @t2
        adc #10
        pha
        txa
        jsr putc
        jmp @ones
:       pla
        ldx #0
        cmp #10
        bcc :+
        ldx #'0'-1
        sec
@t1:    inx
        sbc #10
        bcs @t1
        adc #10
        pha
        txa
        jsr putc
@ones:  pla
:       ora #'0'
        jmp putc

; pause: wait for the START key
pause:  lda #<m_pause
        ldx #>m_pause
        jsr print
:       lda CONSOL
        and #1
        bne :-
        rts

welcomed:   .byte 0

m_banner:   .byte "BALLBLAZER NETPLAY", EOL
m_bad:      .byte "THIS IS NOT THE GAME IMAGE THE NETPLAY", EOL
            .byte "PATCH WAS MADE FOR. LOCAL GAME ONLY.", EOL
m_nofuji:   .byte "NO FUJINET ANSWERED. LOCAL GAME ONLY.", EOL
m_myip:     .byte "THIS ATARI IS AT ", 0
m_askip:    .byte "OPPONENT'S ADDRESS", EOL
            .byte "(JUST RETURN = LOCAL GAME)", EOL
m_askrole:  .byte "H = HOST, PLAYER 1   J = JOIN, PLAYER 2", EOL
m_nostream: .byte "FUJINET REFUSED NETSTREAM MODE.", EOL
m_wait:     .byte "WAITING FOR OPPONENT. START = GIVE UP", EOL
m_differ:   .byte "OPPONENT HAS A DIFFERENT VERSION.", EOL
m_pause:    .byte "PRESS START", EOL

fbuf:       .res 140
line:       .res 124
line2:      .res 124
.endif
