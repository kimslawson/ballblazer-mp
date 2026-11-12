#!/usr/bin/env python3
"""rig - frame-exact, scriptable atari800 with REAL inputs and screenshots.

Drives the stock `atari800` (developed against 5.0.0; the playback format
it relies on is the same up to 7.2.1) three ways at once:

  * INPUT, frame by frame: the emulator's `-playback` file is a named pipe that
    this driver feeds one frame record at a time. Joysticks, triggers and the
    console keys therefore go through the emulated PIA/GTIA exactly as on a real
    machine, and the emulator advances precisely as many frames as we feed it
    (it blocks on the pipe otherwise) - deterministic lockstep.
  * the built-in monitor over a pty (peek/poke, dumps, save states, PC
    breakpoints, 6502 trace);
  * screenshots (PNG) from a private Xvfb display - where Xvfb exists. On
    macOS (or with video=False) the emulator runs with SDL's dummy video
    driver and shot() quietly does nothing; everything else is the same.

Linux and macOS. `python3 tools/rig.py selfcheck` verifies that the rig is
stable and frame-exact on the machine it runs on.

It touches only your own local disk image and writes under build/ (git-ignored).

    from rig import Rig
    with Rig("rom/ballblazer.atr") as r:
        r.step(600)                       # 10 emulated seconds
        r.step(4, trig0=True)             # hold fire on stick 0 for 4 frames
        r.step(60, joy0="U")              # push forward for a second
        r.shot("build/shots/a.png")
        ram = r.dump()                    # bytes $0000-$FFFF (enters monitor)
"""
import ctypes
import fcntl
import hashlib
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

PROMPT = b"> "

# zlib (used by atari800 to read the playback file) fills its buffer completely
# before returning a line, so a pipe is consumed in fixed blocks: 8192 bytes
# first, then 16384 at a time. We pad every frame record to FRAME bytes so one
# block is exactly BLOCK frames; the emulator then runs in deterministic
# 16-frame slices and blocks on the pipe in between.
FRAME = 1024
BLOCK = 16
DIRS = {"U": 1, "D": 2, "L": 4, "R": 8}


def stick(s):
    """'UL' -> active-low nibble."""
    v = 0x0F
    for c in (s or "").upper():
        v &= ~DIRS[c]
    return v


class Rig:
    def __init__(self, disk, display=None, video=None, extra=(), ntsc=True,
                 machine="-xl"):
        self.disk = disk
        self.display = display or ":%d" % (70 + os.getpid() % 25)
        if video is None:                  # screenshots only where possible
            video = have_video()
        self.video = video
        self.extra = list(extra)
        self.ntsc = ntsc
        self.machine = machine
        self.in_monitor = False
        self.fed = 0
        self.buf = b""
        self._fd = None
        # held input state (applied to every frame fed until changed)
        self.joy = ["", "", "", ""]
        self.trig = [False] * 4
        self.consol = 7      # bit0 START, bit1 SELECT, bit2 OPTION (0=pressed)
        self.key = -1

    # ---- lifecycle -------------------------------------------------------
    def __enter__(self):
        self.exe = os.environ.get("ATARI800") or shutil.which("atari800")
        if not self.exe:
            raise RuntimeError("atari800 not found (set ATARI800=/path/to/it)")
        self.tmp = tempfile.mkdtemp(prefix="rig")
        self.fifo = os.path.join(self.tmp, "input.fifo")
        os.mkfifo(self.fifo)
        env = dict(os.environ, SDL_AUDIODRIVER="dummy")
        self.xvfb = None
        if self.video:
            self.xvfb = subprocess.Popen(
                ["Xvfb", self.display, "-screen", "0", "800x600x24",
                 "-nolisten", "tcp"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(100):
                if os.path.exists("/tmp/.X11-unix/X" + self.display[1:]):
                    break
                time.sleep(0.05)
            env.update(DISPLAY=self.display, SDL_VIDEODRIVER="x11")
        else:
            env.update(SDL_VIDEODRIVER="dummy")
        # A private, empty configuration: no ROM paths, so the emulator's
        # built-in (Altirra) OS is used whatever ~/.atari800.cfg says. The
        # tests' timing was established with that OS.
        args = [self.exe, "-config", os.path.join(self.tmp, "atari800.cfg"),
                "-monitor", "-nobasic", "-nosound", "-turbo",
                self.machine, "-xl-rev", "altirra",
                "-ntsc" if self.ntsc else "-pal",
                "-playback", self.fifo]
        args += self.extra
        if self.disk:
            args.append(self.disk)
        self.master, slave = pty.openpty()
        # own session: a Ctrl-C in the terminal reaches this driver only (the
        # emulator would take it as "enter the monitor" at a random moment)
        self.p = subprocess.Popen(args, stdin=slave, stdout=slave,
                                  stderr=slave, env=env, close_fds=True,
                                  start_new_session=True)
        os.close(slave)
        # The emulator opens the FIFO for reading during init; this open
        # unblocks it. It then expects the two header lines.
        self.w = os.open(self.fifo, os.O_WRONLY)
        self.header = b"Atari800 event recording, version: 1\n55704\n"
        self.written = 0
        self._w(self.header)
        self.first = True
        # prime the first 8192-byte block (header + 8 frames) so init returns
        self.feed(8)
        self._wait_prompt(20)
        self.in_monitor = True
        return self

    def __exit__(self, *a):
        try:
            if not self.in_monitor:
                self.brk()
            self._send("QUIT")
            self.p.wait(timeout=3)
        except BaseException:
            self.p.kill()
        if self.xvfb:
            self.xvfb.terminate()
        for fd in (self.master, self.w):
            try:
                os.close(fd)
            except OSError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---- pty plumbing ----------------------------------------------------
    def _send(self, line):
        os.write(self.master, (line + "\n").encode())

    def _read_some(self, timeout):
        r, _, _ = select.select([self.master], [], [], timeout)
        if r:
            try:
                return os.read(self.master, 65536)
            except OSError:
                return b""
        return b""

    def _wait_prompt(self, timeout=10):
        end = time.time() + timeout
        out = b""
        while time.time() < end:
            out += self._read_some(0.02)
            if out.endswith(b"('q' to quit): "):      # pager: keep going
                out = out[:-len("Press Return to continue ('q' to quit): ")]
                os.write(self.master, b"\n")
                continue
            if out.endswith(PROMPT):
                more = self._read_some(0.003)
                if not more:
                    return out.decode(errors="replace")
                out += more
        raise TimeoutError("no monitor prompt; got: %r" % out[-400:])

    def mon(self, line, timeout=10):
        """Run one monitor command (entering the monitor if needed)."""
        if not self.in_monitor:
            self.brk()
        self._send(line)
        out = self._wait_prompt(timeout).replace("\r", "")
        lines = out.split("\n")
        if lines and lines[0].strip() == line.strip():
            lines = lines[1:]
        if lines and lines[-1].strip() == ">":
            lines = lines[:-1]
        return "\n".join(lines)

    # ---- frame feed ------------------------------------------------------
    def _w(self, data):
        """Write to the input pipe, discarding the emulator's per-frame log
        chatter meanwhile (an unread pty would eventually block it)."""
        idle = 0
        while data:
            r, w, _ = select.select([self.master], [self.w], [], 1)
            if r:
                self.buf = (self.buf + os.read(self.master, 65536))[-2000:]
            if w:
                n = os.write(self.w, data[:4096])
                self.written += n
                data = data[n:]
                idle = 0
            elif not r:
                idle += 1
                if idle > 20:
                    raise RuntimeError(
                        "emulator stopped reading input; it said: %r"
                        % self.buf[-600:])

    def _record(self):
        port0 = stick(self.joy[0]) | (stick(self.joy[1]) << 4)
        port1 = stick(self.joy[2]) | (stick(self.joy[3]) << 4)
        t = [0 if x else 1 for x in self.trig]
        vals = ["%d 0 %d" % (self.key, self.consol), "%d" % port0,
                "%d" % port1, "%d" % t[0], "%d" % t[1], "%d" % t[2],
                "%d" % t[3], "00000000"]
        w = [FRAME // 8 - 1] * 8
        if self.first:
            # shorten the very first record so header + record == FRAME
            self.first = False
            w[7] -= len(self.header)
        rec = b"".join(v.encode().ljust(n) + b"\n" for v, n in zip(vals, w))
        return rec

    def set(self, joy0=None, joy1=None, trig0=None, trig1=None, start=None,
            select=None, option=None, key=None):
        """Change held inputs (persist until changed again)."""
        if joy0 is not None:
            self.joy[0] = joy0
        if joy1 is not None:
            self.joy[1] = joy1
        if trig0 is not None:
            self.trig[0] = trig0
        if trig1 is not None:
            self.trig[1] = trig1
        for bit, v in ((1, start), (2, select), (4, option)):
            if v is not None:
                self.consol = (self.consol & ~bit) if v else (self.consol | bit)
        if key is not None:
            self.key = key

    def feed(self, n):
        """Queue n frames of the currently held inputs (does not wait)."""
        for _ in range(n):
            self._w(self._record())
        self.fed += n

    def step(self, n=1, **inputs):
        """Feed n frames. Keyword inputs apply to these frames only, e.g.
        step(4, trig0=True) taps fire; use set() for persistent changes.
        Frames execute in 16-frame slices: call sync()/brk()/shot() to round
        up to the slice boundary and wait for the emulator to get there."""
        if self.in_monitor:
            self._send("CONT")
            self.in_monitor = False
        if inputs:
            saved = (list(self.joy), list(self.trig), self.consol, self.key)
            self.set(**inputs)
            self.feed(n)
            self.joy, self.trig, self.consol, self.key = saved
        else:
            self.feed(n)

    def sync(self, timeout=180):
        """Pad to the 16-frame slice boundary (held inputs) and wait until the
        emulator has executed every frame fed so far. Returns frames run."""
        if self.in_monitor:
            self._send("CONT")
            self.in_monitor = False
        pad = (-(self.fed - 8)) % BLOCK
        if pad:
            self.feed(pad)
        self._wait_blocked(timeout)
        return self.fed

    @property
    def frame(self):
        return self.fed

    # Atari keyboard codes (what KBCODE reads) for the characters tests type
    KEYCODE = {"0": 0x32, "1": 0x1F, "2": 0x1E, "3": 0x1A, "4": 0x18,
               "5": 0x1D, "6": 0x1B, "7": 0x33, "8": 0x35, "9": 0x30,
               ".": 0x22, "\n": 0x0C, " ": 0x21, "H": 0x39, "J": 0x01}

    def type(self, text, hold=4, gap=6):
        """Type characters on the Atari keyboard (see KEYCODE)."""
        for ch in text:
            self.step(hold, key=self.KEYCODE[ch.upper()])
            self.step(gap)

    # ---- "has the emulator run everything it was fed?" -------------------
    # The emulator may only be signalled while it sleeps in read() on the
    # input pipe. How to see that from outside depends on the system.
    def _idle_linux(self):
        """Exact: /proc says which system call the process is blocked in."""
        if self._fd is None:
            d = "/proc/%d/fd" % self.p.pid
            for n in os.listdir(d):
                try:
                    if os.readlink(os.path.join(d, n)) == self.fifo:
                        self._fd = int(n)
                except OSError:
                    pass
            if self._fd is None:
                raise RuntimeError("emulator has not opened the input pipe")
        f = open("/proc/%d/syscall" % self.p.pid).read().split()
        return len(f) > 1 and f[0] == "0" and int(f[1], 16) == self._fd

    def _idle_darwin(self):
        """macOS: no thread of the process is runnable (libproc). The only
        things the emulator ever waits for are the input pipe and its
        terminal, and the terminal is kept drained - so three such samples in
        a row mean it is starved for input."""
        if self._fd is None:
            self._fd = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            self._pti = ctypes.create_string_buffer(96)   # struct proc_taskinfo
        n = self._fd.proc_pidinfo(self.p.pid, 4, ctypes.c_uint64(0),
                                  self._pti, 96)          # PROC_PIDTASKINFO
        if n != 96:
            raise OSError("proc_pidinfo failed")
        return struct.unpack_from("i", self._pti, 88)[0] == 0   # pti_numrunning

    def _idle_generic(self):
        """Fallback: the pipe is empty (the caller then waits a while)."""
        n = struct.unpack("i", fcntl.ioctl(self.w, termios.FIONREAD,
                                           b"\0\0\0\0"))[0]
        return n == 0

    def idle_method(self):
        m = os.environ.get("RIG_IDLE")
        if not m:
            m = {"linux": "linux", "darwin": "darwin"}.get(sys.platform,
                                                             "generic")
        return m

    def _wait_blocked(self, timeout=180):
        """Wait until the emulator has executed every frame it was given and
        is asleep waiting for more."""
        method = self.idle_method()
        probe = getattr(self, "_idle_" + method)
        need = {"linux": 1, "darwin": 3, "generic": 25}[method]
        streak = 0
        end = time.time() + timeout
        while time.time() < end:
            got = self._read_some(0.0005 if method == "linux" else 0.002)
            if got:                            # keep the pty drained
                self.buf = (self.buf + got)[-2000:]
                streak = 0
                continue
            if self.p.poll() is not None:
                raise RuntimeError("emulator exited (%s); it said: %r"
                                   % (self.p.returncode, self.buf[-400:]))
            try:
                streak = streak + 1 if probe() else 0
            except OSError:
                streak = 0
            if streak >= need:
                return
        raise TimeoutError("emulator never went idle")

    def brk(self):
        """Enter the monitor at a frame boundary. Costs one 16-frame slice.

        The emulator is only ever signalled while it is asleep on the input
        pipe; signalling it mid-frame or inside the monitor proved unreliable
        with atari800 5.0."""
        if self.in_monitor:
            return
        self.sync()
        self.p.send_signal(signal.SIGINT)
        time.sleep(0.002)
        self.feed(BLOCK)
        self._wait_prompt(30)
        self.in_monitor = True

    def until(self, addr, max_frames=600):
        """Run until PC == addr (feeds up to max_frames)."""
        self.mon("BPC %04X" % addr)
        self._send("CONT")
        self.feed(-(-max_frames // BLOCK) * BLOCK)   # leftovers stay queued
        out = self._wait_prompt(60)
        self.in_monitor = True
        self.mon("BPC D000")         # $D000-$D7FF = disabled
        return out

    # ---- memory ----------------------------------------------------------
    def dump(self, start=0, end=0xFFFF):
        fd, path = tempfile.mkstemp(suffix=".bin")
        os.close(fd)
        try:
            self.mon("WRITE %04X %04X %s" % (start, end, path))
            with open(path, "rb") as f:
                return f.read()
        finally:
            os.unlink(path)

    def peek(self, addr, n=1):
        d = self.dump(addr, addr + n - 1)
        return d[0] if n == 1 else d

    def poke(self, addr, *vals):
        if len(vals) == 1 and not isinstance(vals[0], int):
            vals = list(vals[0])
        vals = list(vals)
        for i in range(0, len(vals), 16):
            chunk = vals[i:i + 16]
            self.mon("C %04X %s" % (addr + i,
                                     " ".join("%02X" % v for v in chunk)))

    def load(self, path, addr):
        n = os.path.getsize(path)
        return self.mon("READ %s %04X %X" % (path, addr, n))

    def regs(self):
        out = self.mon("SHOW")
        m = re.search(
            r"A=(\w\w) X=(\w\w) Y=(\w\w) S=(\w\w) P=(\S+) PC=(\w{4})", out)
        if not m:
            return out
        a, x, y, s, p, pc = m.groups()
        return dict(A=int(a, 16), X=int(x, 16), Y=int(y, 16), S=int(s, 16),
                    P=p, PC=int(pc, 16))

    def save(self, path):
        return self.mon("SAVESTATE " + os.path.abspath(path))

    def restore(self, path):
        return self.mon("LOADSTATE " + os.path.abspath(path))

    # ---- video -----------------------------------------------------------
    def shot(self, path):
        """Screenshot (PNG, 2x). The window only exists while the emulator is
        running, so leave the monitor and render two more frames first."""
        if not self.video:
            return None
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.sync()
        time.sleep(0.12)
        env = dict(os.environ, DISPLAY=self.display)
        raw = path + ".raw.png"
        subprocess.run(["import", "-window", "root", raw], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        from PIL import Image
        im = Image.open(raw).convert("RGB").crop((232, 180, 568, 420))
        im = im.resize((672, 480), Image.NEAREST)
        im.save(path)
        os.unlink(raw)
        return path


def have_video():
    """Can we take screenshots here? (Xvfb + ImageMagick + Pillow)
    RIG_VIDEO=0 forces headless operation."""
    if os.environ.get("RIG_VIDEO") == "0":
        return False
    if not (shutil.which("Xvfb") and shutil.which("import")):
        return False
    try:
        import PIL  # noqa: F401
    except ImportError:
        return False
    return True


def emulator_version():
    exe = os.environ.get("ATARI800") or shutil.which("atari800")
    if not exe:
        return None
    out = subprocess.run([exe, "-v"], capture_output=True, text=True).stdout
    m = re.search(r"Version\s+([0-9.]+)", out)
    return m.group(1) if m else out.strip()


def selfcheck(disk):
    """Is the rig trustworthy on this machine?
       1. stable: 300 break/continue cycles without losing the emulator;
       2. frame-exact: two runs fed the same input end in identical memory."""
    ver = emulator_version()
    print("platform %s, atari800 %s, idle detection: %s, screenshots: %s"
          % (sys.platform, ver, Rig(None).idle_method(),
             "yes" if have_video() else "no"))
    if ver is None:
        print("FAIL: atari800 not found")
        return 1
    try:
        v = tuple(int(x) for x in ver.split(".")[:3])
    except ValueError:
        v = (0,)
    if v > (7, 2, 1):
        print("note: atari800 changed its playback file format after 7.2.1; "
              "this rig writes the format of 5.0 - 7.2.1 and may not work")
    elif v < (5, 0, 0):
        print("note: untested with atari800 older than 5.0")
    sums = []
    for run in range(2):
        with Rig(disk) as r:
            r.step(704)
            for i in range(150):
                r.step(16, joy0="UDLR"[i % 4], trig0=(i % 7 == 0),
                       start=(i == 3))
                r.poke(0x0600, i & 0xFF)       # forces a monitor round trip
            ram = r.dump(0x0000, 0xBFFF)
            sums.append(hashlib.md5(ram).hexdigest())
            print("run %d: %d frames, memory md5 %s" % (run + 1, r.fed, sums[-1]))
    if sums[0] != sums[1]:
        print("FAIL: two identical runs ended in different memory - the rig "
              "is not frame-exact here")
        return 1
    print("PASS: stable (300 monitor round trips) and frame-exact")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "selfcheck":
        sys.exit(selfcheck(args[1] if len(args) > 1 else "rom/ballblazer.atr"))
    disk = args[0] if args else "rom/ballblazer.atr"
    with Rig(disk) as r:
        r.step(600)
        print(r.regs(), "frame", r.fed)
        print(r.shot("build/shots/boot.png"))
