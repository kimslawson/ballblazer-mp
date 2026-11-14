; ============================================================================
; hw.inc - Atari hardware / OS equates used by the netplay code
; ============================================================================
; GTIA
TRIG0   = $D010
PAL     = $D014          ; bits 1-3 = %000 on PAL machines, %111 on NTSC
COLBK   = $D01A
CONSOL  = $D01F
; POKEY
AUDF1   = $D200
AUDC1   = $D201
AUDF2   = $D202
AUDC2   = $D203
AUDF3   = $D204
AUDC3   = $D205
AUDF4   = $D206
AUDC4   = $D207
AUDCTL  = $D208
KBCODE  = $D209
SKRES   = $D20A          ; (write) reset serial status
RANDOM  = $D20A          ; (read)
SEROUT  = $D20D          ; (write)
SERIN   = $D20D          ; (read)
IRQEN   = $D20E          ; (write)
IRQST   = $D20E          ; (read) 0 = pending
SKCTL   = $D20F          ; (write)
SKSTAT  = $D20F          ; (read)
; PIA
PORTA   = $D300
PACTL   = $D302          ; bit 3 = cassette motor line (0 = on)
; ANTIC
NMIEN   = $D40E
; OS
VIMIRQ  = $0216          ; immediate IRQ vector
POKMSK  = $10            ; the OS's copy of IRQEN
DCB     = $0300          ; SIO device control block
DDEVIC  = $0300
DUNIT   = $0301
DCOMND  = $0302
DSTATS  = $0303
DBUFLO  = $0304
DBUFHI  = $0305
DTIMLO  = $0306
DBYTLO  = $0308
DBYTHI  = $0309
DAUX1   = $030A
DAUX2   = $030B
SIOV    = $E459
CIOV    = $E456
ICCOM   = $0342
ICBAL   = $0344
ICBAH   = $0345
ICBLL   = $0348
ICBLH   = $0349
RUNAD   = $02E0

; IRQ bits (IRQEN / IRQST)
IRQ_SERIN  = $20         ; serial input byte ready
IRQ_SEROUT = $10         ; serial output byte needed
IRQ_XMTDON = $08         ; serial output complete (not latched)

; SKCTL values (bits 0-1 keep the keyboard scan running)
SK_RECV = $13            ; receive asynchronously, clocked by voices 3+4
SK_SEND = $43            ; transmit clocked by voice 4; receive side parked on
                         ;   the (absent) external clock. The OS uses $23 to
                         ;   send, which transmits identically; $43 is chosen
                         ;   because the atari800 NetSIO core (and so Fujisan)
                         ;   only relays NetStream bytes in modes $00/$10/
                         ;   $30/$40.
