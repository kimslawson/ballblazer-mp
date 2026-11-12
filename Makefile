# ============================================================================
# Ballblazer-MP - build orchestration
#
#   make test        checks that need no game image (assemble, protocol, tools)
#   make disk        build/ballblazer-net.atr from YOUR rom/ballblazer.atr
#   make nptest      the emulator tests (need rom/ballblazer.atr + atari800):
#                      nplock    two linked emulators, lockstep soak
#                      npserial  real serial driver + lobby, both roles
#   make watch       run npserial, then replay it in a window you can watch
#   make disasm / rebuild / dump / dump-run / findings   reverse-engineering aids
#   make clean
#
# Toolchain: cc65 (ca65/ld65/da65) + python3; atari800 for the emulator tests.
#   Debian/Ubuntu: sudo apt-get install cc65 atari800 python3 python3-pil xvfb imagemagick
#   macOS:         brew install cc65 atari800
# ============================================================================

CA65  := ca65
LD65  := ld65
PY    := python3
NP    := build/np
DISK  ?= rom/ballblazer.atr

NP_SRC := src/netplay/resident.s src/netplay/lobby.s \
          src/netplay/hw.inc src/netplay/game.inc cfg/netplay.cfg

.PHONY: all test netplay disk nptest nplock npserial watch selftest disasm rebuild \
        dump dump-run findings clean

all: test

# ---- the netplay code (no game image needed to assemble it) ----------------
# np0 = production, np1 = emulator-link test build, np2 = serial test build
netplay: $(NP)/np0.resident

$(NP)/np0.resident: $(NP_SRC)
	@mkdir -p $(NP)
	$(CA65) -g -t none -D TEST=0 -I src/netplay src/netplay/resident.s -o $(NP)/res0.o
	$(CA65) -g -t none -D TEST=0 -I src/netplay src/netplay/lobby.s    -o $(NP)/lob0.o
	$(LD65) -C cfg/netplay.cfg -Ln $(NP)/np0.lbl -m $(NP)/np0.map -o $(NP)/np0 \
	        $(NP)/res0.o $(NP)/lob0.o
	@echo "resident: $$(wc -c < $(NP)/np0.resident | tr -d ' ') of 1024 bytes;" \
	      "lobby: $$(wc -c < $(NP)/np0.lobby | tr -d ' ') bytes"

# ---- the playable disk (your own image stays on your machine) --------------
disk: build/ballblazer-net.atr

build/ballblazer-net.atr: $(NP)/np0.resident tools/mkdisk.py $(DISK)
	$(PY) tools/mkdisk.py $(DISK) $(NP)/np0 $@ --xex build/ballblazer-net.xex

# ---- automated checks ------------------------------------------------------
test:
	@bash tools/run_tests.sh

selftest:
	@bash tools/selftest_roundtrip.sh

nptest: nplock npserial

nplock:
	$(PY) tests/np_soak.py 60 1 0.3

npserial:
	$(PY) tests/np_serial.py client
	$(PY) tests/np_serial.py host

# run the serial test, then watch it: the same session replayed in a normal
# emulator window at real speed, with sound (ROLE=host for the other side)
ROLE ?= client
watch:
	$(PY) tests/np_serial.py $(ROLE) --watch

# ---- reverse-engineering aids (need your own image) ------------------------
disasm:
	@mkdir -p build
	@bash disasm/disasm.sh $(ROM)

rebuild:
	@bash disasm/rebuild.sh

dump:
	@bash tools/dump_ram.sh handoff $(DISK) build/disk/ram.bin

dump-run:
	@bash tools/dump_ram.sh run $(DISK) build/disk/ram_run.bin 6

findings:
	@test -f build/disk/ram_run.bin || bash tools/dump_ram.sh run $(DISK) build/disk/ram_run.bin 6
	@echo "## memory map ##";     $(PY) tools/scan_findings.py map build/disk/ram_run.bin
	@echo; echo "## I/O seams ##"; $(PY) tools/scan_findings.py io  build/disk/ram_run.bin

clean:
	rm -rf build
