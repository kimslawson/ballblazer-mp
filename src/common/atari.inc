; ============================================================================
; atari.inc  -  Atari 8-bit OS / CIO / hardware equates
; ----------------------------------------------------------------------------
; Only the symbols this project needs.  All values are long-established facts
; from the Atari 400/800/XL/XE Operating System (see "Mapping the Atari" and
; the OS source listings).  Referenced by the FujiNet networking layer.
; ============================================================================

; ---- CIO (Central I/O) --------------------------------------------------
CIOV        = $E456          ; CIO vector: entry with X = IOCB# * 16
CIOINV      = $E455          ; (info) CIO init vector

; IOCB command bytes (placed in ICCMD before JSR CIOV)
CMD_OPEN    = $03
CMD_GETREC  = $05            ; get record (line, terminated by EOL)
CMD_GETCHR  = $07            ; get characters / block  (BGET)
CMD_PUTREC  = $09            ; put record
CMD_PUTCHR  = $0B            ; put characters / block  (BPUT)
CMD_CLOSE   = $0C
CMD_STATUS  = $0D            ; status  (FujiNet: refreshes DVSTAT bytes-waiting)
CMD_SPECIAL = $0E            ; first SPECIAL command; device-specific >= $0E

; OPEN aux1 (ICAX1) direction bits
OPEN_READ   = $04
OPEN_WRITE  = $08
OPEN_UPDATE = $0C            ; read + write (what the game link uses)
OPEN_APPEND = $01            ; OR with WRITE for append

; ---- IOCB layout --------------------------------------------------------
; Eight IOCBs starting at $0340, each 16 bytes.  X passed to CIOV is n*16.
IOCB0       = $0340
IOCB_LEN    = 16

; Offsets within an IOCB (add to IOCB0 + n*16)
ICHID       = $00            ; handler id (set by OS on OPEN)
ICDNO       = $01            ; device number (the digit in "N1:".."N8:")
ICCMD       = $02            ; command byte
ICSTA       = $03            ; status returned by last op
ICBAL       = $04            ; buffer address low
ICBAH       = $05            ; buffer address high
ICPTL       = $06            ; PUT-char routine addr low (set by OS)
ICPTH       = $07            ; PUT-char routine addr high
ICBLL       = $08            ; buffer length low  (bytes to transfer)
ICBLH       = $09            ; buffer length high
ICAX1       = $0A            ; aux 1 (open mode)
ICAX2       = $0B            ; aux 2 (device-specific)
ICAX3       = $0C
ICAX4       = $0D
ICAX5       = $0E
ICAX6       = $0F

; CIO status / error codes we care about
STAT_OK     = $01            ; success (1)
STAT_EOF    = $88            ; end of file (136)
STAT_TIMEOUT= $8A            ; device timeout (138)
STAT_NODEV  = $82            ; device does not respond / not open

; ---- FujiNet DVSTAT block ----------------------------------------------
; The N: handler returns four bytes here after a CIO STATUS ($0D) call.
; This is the canonical "how many bytes are waiting" mechanism used to poll
; the connection without blocking the caller.
DVSTAT      = $02EA          ; 4 bytes
DVSTAT_BW_L = DVSTAT+0       ; bytes waiting, low
DVSTAT_BW_H = DVSTAT+1       ; bytes waiting, high
DVSTAT_CONN = DVSTAT+2       ; connection status (0 = closed)
DVSTAT_ERR  = DVSTAT+3       ; extended error

; ---- OS run/init vectors (for XEX loading) ------------------------------
RUNAD       = $02E0          ; XEX run address
INITAD      = $02E2          ; XEX init address

; ---- A few hardware / OS shadow registers used by the demo --------------
RTCLOK      = $0012          ; 3-byte frame counter ($12=hi .. $14=lo jiffies)
RTCLOK_LO   = $0014          ; increments every VBLANK (~1/60 or 1/50 s)
CH          = $02FC          ; last key pressed (internal code); $FF = none
CONSOL      = $D01F          ; console keys (Start/Select/Option), active-low
COLBK       = $D01A          ; background colour (visual heartbeat)
SDMCTL      = $022F          ; DMA control shadow

; console key masks (CONSOL bits, 0 = pressed)
CONSOL_START  = %001
CONSOL_SELECT = %010
CONSOL_OPTION = %100
