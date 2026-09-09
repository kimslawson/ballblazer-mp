; ============================================================================
; gameaddr.inc  -  Ballblazer (DISK build) addresses used by the net patch.
; ----------------------------------------------------------------------------
; FACTS discovered by reverse engineering the user's own disk (docs/05-findings).
; These are memory-map facts (addresses), not game code. Disk-specific — verify
; against your own image with the tools in tools/ before trusting them.
;
; The values were confirmed by controlled-input correlation in atari800: forcing
; a player's control gate to the joystick path and injecting a stick direction,
; then keeping the bytes whose delta reverses sign between opposite directions.
; ============================================================================

; ---- per-player control seam (Seam A) ----------------------------------
GAME_P1_SEL       = $23DE   ; player-1 control selector: 0=joystick, !=0=droid
GAME_P2_SEL       = $33DE   ; player-2 control selector
GAME_DROID_AI     = $9A4A   ; droid "brain" (X=$00 for P1, X=$14 for P2)
GAME_DROID_JSR_P1 = $5F37   ; the `JSR $9A4A` inside the P1 handler
GAME_DROID_JSR_P2 = $5F74   ; the `JSR $9A4A` inside the P2 handler
GAME_PLAYER_STRIDE = $14    ; per-player index stride the AI uses (20 bytes)

; ---- interrupt / loop anchors ------------------------------------------
GAME_VBI          = $4CAB   ; immediate VBI (current VVBLKI target)
GAME_MAINLOOP     = $4C72   ; idle spin loop (logic runs in the VBI)

; ---- player-2 rotofoil kinematics (the REMOTE, network-driven side) ----
; Confirmed responders. Exact position-vs-velocity split is a refinement;
; these move under P2 forced input (fwd/back and lateral respectively).
GAME_P2_FB_A      = $80     ; fwd/back responder (clean +/-5)
GAME_P2_FB_B      = $8E     ; fwd/back responder (clean +/-5)
GAME_P2_LAT       = $FB     ; lateral responder (clean +/-8)
; full cluster for a fuller overwrite: $7E,$80,$8E,$90,$A5..$AD,$B2

; ---- player-1 rotofoil kinematics (the LOCAL side, captured to send) ---
GAME_P1_FB_HI     = $F1     ; fwd/back 16-bit pair (hi)
GAME_P1_FB_LO     = $F2     ; fwd/back 16-bit pair (lo)
GAME_P1_FB2_HI    = $F4     ; second fwd/back 16-bit pair
GAME_P1_FB2_LO    = $F5
GAME_P1_LAT       = $12D1   ; lateral (clean +/-8)

; ---- OS ----------------------------------------------------------------
VVBLKI            = $0222   ; immediate vertical-blank vector
