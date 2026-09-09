; ============================================================================
; netpatch.s  -  wire the FujiNet netcode into Ballblazer's control seam.
; ----------------------------------------------------------------------------
; Original glue code (no game bytes). It is assembled to a free region (page 6
; by default; see cfg/atari-inject.cfg) and, once resident, turns the game's
; native player-2 path into a network-driven opponent using the tested
; src/net/ layer. Ties together the addresses in src/game/gameaddr.inc with the
; NETSTATE contract in docs/04-netcode.md.
;
; Model (state authority, per docs/04): the LOCAL player (P1) stays on the
; joystick path and runs the stock physics with zero added latency; each frame
; we capture its kinematics into loc_*, run ng_tick (non-blocking N: exchange),
; and overwrite the REMOTE player (P2) kinematics from rem_*. Dead reckoning in
; ng_tick keeps the remote craft smooth at 60 Hz between ~20 Hz packets. The
; overwrite runs at the VBI exit, AFTER the game's own per-frame updates, so it
; is the authoritative last word on the remote craft's position.
;
; Refinements flagged inline: (a) exact position/velocity/heading split within
; each confirmed cluster; (b) decision-replacement at $9A4A instead of
; state-overwrite, to reuse the game's integrator; (c) host ball authority.
; ============================================================================

        .include "atari.inc"
        .include "fujinet.inc"
        .include "gameaddr.inc"

        .importzp net_ptr
        .import   net_open
        .importzp ng_ptr
        .import   ng_init, ng_tick
        .import   loc_xi, loc_xf, loc_yi, loc_yf, loc_flags
        .import   rem_xi, rem_xf, rem_yi, rem_yf

        .export   netp_install, netp_post, net_mode
        .export   netp_capture_local, netp_apply_remote

XITVBV  = $E462

        .segment "BSS"
net_mode:   .res 1              ; 0 = stock game, 1 = network match active

        .segment "CODE"

; --------------------------------------------------------------------------
; netp_install - enter network-match mode.
;   in : net_ptr -> EOL-terminated N: URL, A = role (0 = client, 1 = host)
;   Sets P1=joystick / P2=droid (so the craft is "live"), opens the link,
;   installs the VBI-exit wedge, and arms net_mode. Returns A = CIO status
;   from the OPEN (Z set on success).
; --------------------------------------------------------------------------
.proc netp_install
        pha                         ; save role
        ; --- route control sources ---
        lda #0
        sta GAME_P1_SEL             ; player 1 = local human (joystick)
        lda #1
        sta GAME_P2_SEL             ; player 2 = "droid" so it is active; we
                                    ;   overwrite its state each frame below.
        ; --- reset link + role flags ---
        jsr ng_init
        pla                         ; role
        beq :+                      ; client -> no host bit
        lda #FLAG_HOST
        sta loc_flags
:
        ; --- open the N: link (net_ptr already points at the URL) ---
        lda #OPEN_UPDATE
        jsr net_open
        bne done                    ; open failed -> leave net_mode = 0

        ; --- install the VBI-exit wedge: patch the game's `JMP XITVBV` so it
        ;     runs netp_post first. GAME_VBI's exit JMP is at $4CBB. ---
        lda #<netp_post
        sta GAME_VBI_EXIT+1
        lda #>netp_post
        sta GAME_VBI_EXIT+2

        lda #1
        sta net_mode
        lda #STAT_OK               ; report success (Z set)
        cmp #STAT_OK
done:
        rts
.endproc

GAME_VBI_EXIT = $4CBB              ; the `JMP XITVBV` at the end of the game VBI

; --------------------------------------------------------------------------
; netp_post - runs at VBI exit each frame (after the game's own updates).
; capture local -> exchange -> overwrite remote, then hand off to XITVBV.
; --------------------------------------------------------------------------
.proc netp_post
        lda net_mode
        beq out
        jsr netp_capture_local
        jsr ng_tick                 ; non-blocking N: send/recv + dead reckon
        jsr netp_apply_remote
out:
        jmp XITVBV
.endproc

; --------------------------------------------------------------------------
; netp_capture_local - copy player-1's kinematics into loc_* (to transmit).
; Mapping uses the controlled-input-confirmed responders (gameaddr.inc);
; the exact position/velocity split is a documented refinement.
; --------------------------------------------------------------------------
.proc netp_capture_local
        lda GAME_P1_FB_HI
        sta loc_yi
        lda GAME_P1_FB_LO
        sta loc_yf
        lda GAME_P1_LAT
        sta loc_xi
        lda #0
        sta loc_xf
        rts
.endproc

; --------------------------------------------------------------------------
; netp_apply_remote - overwrite player-2's kinematics from rem_* (received).
; --------------------------------------------------------------------------
.proc netp_apply_remote
        lda rem_yi
        sta GAME_P2_FB_A
        lda rem_yf
        sta GAME_P2_FB_B
        lda rem_xi
        sta GAME_P2_LAT
        rts
.endproc
