# ============================================================================
# Ballblazer-MP - build orchestration
#
#   make test          run all automated checks (no ROM needed)
#   make demo          build the FujiNet link demo (host + client .xex)
#   make selftest      disassembly round-trip proof on a synthetic cart
#   make disasm        disassemble YOUR rom/ballblazer.rom  (see rom/README.md)
#   make rebuild       reassemble the disassembly and verify byte-identity
#   make clean
#
# Toolchain: cc65 (ca65/ld65/da65/sim65) + dasm + atari800.  On Debian/Ubuntu:
#   sudo apt-get install cc65 dasm atari800
# ============================================================================

CA65    := ca65
LD65    := ld65
PY      := python3

INCS    := -I src/common -I src/net -I src/demo
ATARGET := -t atari
BUILD   := build

NET_SRC := src/net/ncio.s src/net/netgame.s
NET_OBJ := $(BUILD)/ncio.o $(BUILD)/netgame.o

.PHONY: all test demo selftest disasm rebuild clean dirs

all: test demo

dirs:
	@mkdir -p $(BUILD)

# ---- automated tests -------------------------------------------------------
test: dirs
	@bash tools/run_tests.sh

selftest: dirs
	@bash tools/selftest_roundtrip.sh

# ---- the FujiNet link demo (two role variants) -----------------------------
demo: $(BUILD)/netdemo-host.xex $(BUILD)/netdemo-client.xex
	@echo "built $^"

# host variant (ROLE_HOST=1)
$(BUILD)/netdemo-host.xex: $(NET_SRC) src/demo/netdemo.s src/demo/linkcfg.inc | dirs
	$(CA65) $(ATARGET) $(INCS) -DROLE_HOST=1 src/net/ncio.s     -o $(BUILD)/ncio_h.o
	$(CA65) $(ATARGET) $(INCS) -DROLE_HOST=1 src/net/netgame.s  -o $(BUILD)/netgame_h.o
	$(CA65) $(ATARGET) $(INCS) -DROLE_HOST=1 src/demo/netdemo.s -o $(BUILD)/netdemo_h.o
	$(LD65) -C cfg/atari-xex.cfg -o $(BUILD)/netdemo-host.bin \
	        $(BUILD)/netdemo_h.o $(BUILD)/netgame_h.o $(BUILD)/ncio_h.o
	$(PY) tools/xex.py $(BUILD)/netdemo-host.bin $@ 2000

# client variant (ROLE_HOST=0)
$(BUILD)/netdemo-client.xex: $(NET_SRC) src/demo/netdemo.s src/demo/linkcfg.inc | dirs
	$(CA65) $(ATARGET) $(INCS) -DROLE_HOST=0 src/net/ncio.s     -o $(BUILD)/ncio_c.o
	$(CA65) $(ATARGET) $(INCS) -DROLE_HOST=0 src/net/netgame.s  -o $(BUILD)/netgame_c.o
	$(CA65) $(ATARGET) $(INCS) -DROLE_HOST=0 src/demo/netdemo.s -o $(BUILD)/netdemo_c.o
	$(LD65) -C cfg/atari-xex.cfg -o $(BUILD)/netdemo-client.bin \
	        $(BUILD)/netdemo_c.o $(BUILD)/netgame_c.o $(BUILD)/ncio_c.o
	$(PY) tools/xex.py $(BUILD)/netdemo-client.bin $@ 2000

# ---- disassembly of your own ROM -------------------------------------------
disasm: dirs
	@bash disasm/disasm.sh $(ROM)

rebuild: dirs
	@bash disasm/rebuild.sh

clean:
	rm -rf $(BUILD)
