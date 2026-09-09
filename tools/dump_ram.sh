#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dump_ram.sh - headless RAM capture from atari800 for reverse engineering.
#
# Boots your own disk in atari800 (SDL dummy driver, no display needed) and
# writes a flat $0000-$BFFF image via the emulator's monitor.  Two modes:
#
#   dump_ram.sh handoff <disk.atr> <out.bin>
#       break at the loader handoff ($07AB, JMP (RUNAD)) - deterministic,
#       captures the fully-loaded game image the instant before it runs.
#
#   dump_ram.sh run <disk.atr> <out.bin> [seconds]
#       let it boot and run for N seconds (default 6), then SIGINT into the
#       monitor and dump - captures a live/title state.
#
# Output is a copyrighted-derived image: keep it local (build/ is git-ignored).
# Findings extracted from it (addresses, maps) go in docs/05-findings.md.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."
export HOME=/root SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

mode="${1:?usage: dump_ram.sh handoff|run <disk.atr> <out.bin> [seconds]}"
disk="${2:?need disk image}"
out="${3:?need output path}"
secs="${4:-6}"
mkdir -p "$(dirname "$out")"
[ -f "$disk" ] || { echo "disk not found: $disk"; exit 1; }

filter='OpenGL|config file|Created by|Video Mode|Requested|Native|render driver|Reinitial'

if [ "$mode" = "handoff" ]; then
    printf 'BPC 07AB\nCONT\nWRITE 0000 BFFF %s\nQUIT\n' "$out" \
        | timeout 90 atari800 -monitor -turbo -nobasic "$disk" 2>&1 \
        | grep -viE "$filter" | grep -iE "breakpoint|Wrote|PC=07AB" || true
elif [ "$mode" = "run" ]; then
    fifo="$(mktemp -u)"; mkfifo "$fifo"
    timeout 120 atari800 -monitor -turbo -nobasic "$disk" < "$fifo" > /tmp/dump_ram.log 2>&1 &
    pid=$!
    exec 3>"$fifo"
    printf 'CONT\n' >&3
    sleep "$secs"
    kill -INT "$pid" 2>/dev/null || true
    sleep 1
    printf 'WRITE 0000 BFFF %s\nQUIT\n' "$out" >&3
    sleep 3
    exec 3>&-
    wait "$pid" 2>/dev/null || true
    rm -f "$fifo"
    grep -iE "Wrote" /tmp/dump_ram.log || true
else
    echo "unknown mode '$mode'"; exit 1
fi

[ -s "$out" ] && echo "dumped $(stat -c%s "$out") bytes -> $out" || { echo "no dump produced"; exit 1; }
