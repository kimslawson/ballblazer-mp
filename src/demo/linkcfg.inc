; ============================================================================
; linkcfg.inc  -  EDIT THIS, then rebuild the demo.
; ----------------------------------------------------------------------------
; Two machines run the netdemo: one built as HOST, one as CLIENT.
;   * HOST   listens on UDP :5000 and is the plasmorb/ball authority.
;   * CLIENT dials the host's IP on UDP 5000.
; Put the HOST machine's LAN IP into the client URL below.
;
; UDP is used so a lost datagram just drops one state tick (no stall).  You can
; switch both builds to TCP (N:TCP://...) for a quick reliability check.
; ============================================================================

; Default role; the Makefile overrides it per target with -DROLE_HOST=0/1.
.ifndef ROLE_HOST
ROLE_HOST = 1           ; <-- set 1 on the host build, 0 on the client build
.endif

; emit_url: assembles the EOL($9B)-terminated device URL for this role.
.macro emit_url
    .if ROLE_HOST
        .byte "N:UDP://:5000/", $9B                 ; host: listen on port 5000
    .else
        .byte "N:UDP://192.168.1.50:5000/", $9B     ; client: <-- host's LAN IP
    .endif
.endmacro
