#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_hook_emu.sh - prove the ACTUAL netpatch drives the opponent in-game.
#
# Builds the integration patch, loads it into a running copy of your own disk in
# atari800 (headless), hooks the real netp_apply_remote into the game's VBI
# exit, pokes the netcode's rem_* fields, and checks that player 2's kinematic
# variables take those values. This is the Phase-4 hook proof, minus the live
# N: transport (which needs FujiNet).
#
# Requires your own rom/ballblazer.atr locally (git-ignored). Not part of
# `make test` (that stays image-free); run it directly or via `make hooktest`.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
export HOME=/root SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
DISK="${1:-rom/ballblazer.atr}"
if [ ! -f "$DISK" ]; then
    echo "skip: $DISK not present (supply your own disk image)"; exit 0
fi
mkdir -p build

# 1. build the patch blob with a label file
ca65 -t none -I src/common -I src/net -I src/game src/game/netpatch.s -o build/netpatch.o
ca65 -t none -I src/common -I src/net src/net/netgame.s -o build/ng_i.o
ca65 -t none -I src/common -I src/net src/net/ncio.s    -o build/ncio_i.o
ld65 -C cfg/atari-inject.cfg -o build/netpatch.blob -Ln build/netpatch.lbl \
     build/netpatch.o build/ng_i.o build/ncio_i.o

# 2. pull the addresses we need straight from the link map (robust to changes)
lbl() { grep -iE "\\.$1\$" build/netpatch.lbl | awk '{print $2}' | tail -c5; }
AR=$(lbl netp_apply_remote); YI=$(lbl rem_yi); YF=$(lbl rem_yf); XI=$(lbl rem_xi)
SZ=$(printf '%X' "$(stat -c%s build/netpatch.blob)")
ARLO=${AR: -2}; ARHI=${AR:0:2}
echo "apply_remote=\$$AR rem_yi=\$$YI rem_yf=\$$YF rem_xi=\$$XI blob=\$$SZ bytes"

# 3. loopback: READ blob to $0600; trampoline @ $0590 = JSR apply_remote ; JMP XITVBV;
#    poke rem_* with markers; wedge the game's VBI exit ($4CBB) -> trampoline.
python3 tools/drive_atari.py "$DISK" boot run:3 \
  "mon:READ build/netpatch.blob 0600 $SZ" \
  "patch:0590:20,$ARLO,$ARHI,4C,62,E4" \
  "patch:$YI:3A" "patch:$YF:5C" "patch:$XI:7E" \
  "patch:4CBB:4C,90,05" \
  run:2 dump:build/disk/hooktest.bin quit >/dev/null 2>&1

# 4. verify player-2 kinematics took the injected rem_* markers
python3 - <<'PY'
d = open("build/disk/hooktest.bin", "rb").read()
got = (d[0x80], d[0x8E], d[0xFB])
want = (0x3A, 0x5C, 0x7E)   # rem_yi -> $80, rem_yf -> $8E, rem_xi -> $FB
if got == want:
    print("PASS: real netp_apply_remote drove P2 kinematics from rem_* "
          f"(${got[0]:02X}/{got[1]:02X}/{got[2]:02X})")
else:
    print(f"FAIL: got {got[0]:02X}/{got[1]:02X}/{got[2]:02X}, want 3A/5C/7E")
    raise SystemExit(1)
PY