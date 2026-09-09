#!/usr/bin/env python3
"""drive_atari - script the atari800 monitor for headless input injection.

Runs atari800 fully headless (SDL dummy driver) and drives its terminal monitor
so we can: boot, break (via SIGINT), patch memory (e.g. rewrite an input-read
instruction so it returns a value we choose), let it run, and dump RAM. Used to
create controlled motion so tools/scan_findings.py diff can PIN the Seam-B
state variables (rotofoil/ball position/velocity/heading).

It touches only the user's own local disk image and writes dumps under build/
(git-ignored). It stores no game code.

Experiment steps come from argv as "verb:args" tokens:
    boot                       launch, break at OS cold start
    run:SECONDS                CONT, run in turbo SECONDS wall, SIGINT to monitor
    patch:ADDR:BB,BB,..        write bytes at ADDR (hex) via monitor 'C'
    dump:PATH                  WRITE $0000-$BFFF to PATH
    show                       print current PC/registers
    quit                       QUIT

Example (force joystick 'up' then dump twice):
    drive_atari.py rom/ballblazer.atr \
        boot run:3 patch:5F3D:A9,FE,EA run:1 dump:build/disk/up_a.bin \
        run:1 dump:build/disk/up_b.bin quit
"""
import os
import signal
import subprocess
import sys
import time

FILTER = ("OpenGL", "config file", "Created by", "Video Mode", "Requested",
          "Native", "render driver", "Reinitial")


def launch(disk):
    env = dict(os.environ, HOME="/root",
               SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    return subprocess.Popen(
        ["atari800", "-monitor", "-turbo", "-nobasic", disk],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, env=env, bufsize=0)


def send(proc, line):
    proc.stdin.write((line + "\n").encode())
    proc.stdin.flush()


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    disk = sys.argv[1]
    steps = sys.argv[2:]
    if not os.path.exists(disk):
        sys.exit(f"disk not found: {disk}")

    proc = launch(disk)
    time.sleep(1.0)  # let it reach the initial monitor prompt

    for step in steps:
        verb, _, arg = step.partition(":")
        if verb == "boot":
            pass  # already at the monitor after launch
        elif verb == "run":
            secs = float(arg or "2")
            send(proc, "CONT")
            time.sleep(secs)
            proc.send_signal(signal.SIGINT)  # drop back into the monitor
            time.sleep(0.6)
        elif verb == "patch":
            addr, _, bb = arg.partition(":")
            bytes_str = " ".join(bb.split(","))
            send(proc, f"C {addr} {bytes_str}")
            time.sleep(0.2)
        elif verb == "dump":
            send(proc, f"WRITE 0000 BFFF {arg}")
            time.sleep(1.0)
        elif verb == "show":
            send(proc, "SHOW")
            time.sleep(0.2)
        elif verb == "quit":
            send(proc, "QUIT")
        else:
            print(f"(ignoring unknown step '{step}')", file=sys.stderr)

    try:
        out, _ = proc.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()

    for line in out.decode(errors="replace").splitlines():
        if line.strip() and not any(f in line for f in FILTER):
            print(line)


if __name__ == "__main__":
    main()
