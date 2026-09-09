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

# ---- RAM capture + analysis (needs your own rom/ballblazer.atr) -------------
DISK ?= rom/ballblazer.atr

dump: dirs
	@bash tools/dump_ram.sh handoff $(DISK) $(BUILD)/disk/ram.bin

dump-run: dirs
	@bash tools/dump_ram.sh run $(DISK) $(BUILD)/disk/ram_run.bin 6

findings: dirs
	@test -f $(BUILD)/disk/ram_run.bin || bash tools/dump_ram.sh run $(DISK) $(BUILD)/disk/ram_run.bin 6
	@echo "## memory map ##";     python3 tools/scan_findings.py map $(BUILD)/disk/ram_run.bin
	@echo; echo "## I/O seams ##"; python3 tools/scan_findings.py io  $(BUILD)/disk/ram_run.bin

# ---- injected network patch (netpatch + netgame + ncio) --------------------
patch: dirs
	$(CA65) -t none $(INCS) -I src/game src/game/netpatch.s -o $(BUILD)/netpatch.o
	$(CA65) -t none $(INCS) src/net/netgame.s -o $(BUILD)/ng_i.o
	$(CA65) -t none $(INCS) src/net/ncio.s    -o $(BUILD)/ncio_i.o
	$(LD65) -C cfg/atari-inject.cfg -o $(BUILD)/netpatch.blob \
	        $(BUILD)/netpatch.o $(BUILD)/ng_i.o $(BUILD)/ncio_i.o
	@echo "injected patch footprint: $$(stat -c%s $(BUILD)/netpatch.blob) bytes"

# ---- netcode CPU cycle microbench (sim65) ----------------------------------
bench: dirs
	$(CA65) -t sim6502 -D UNIT_TEST $(INCS) src/net/netgame.s -o $(BUILD)/ng_b.o
	$(CA65) -t sim6502 $(INCS) src/net/ncio.s -o $(BUILD)/ncio_b.o
	@for s in BENCH_DR BENCH_TX BENCH_RX; do \
	  $(CA65) -t sim6502 -D $$s $(INCS) tests/bench_netgame.s -o $(BUILD)/bench.o; \
	  $(LD65) -t sim6502 -o $(BUILD)/bench.prg $(BUILD)/bench.o $(BUILD)/ng_b.o $(BUILD)/ncio_b.o sim6502.lib; \
	  c=$$(sim65 --cycles $(BUILD)/bench.prg 2>&1 | grep -ioE "[0-9]+ cycles" | grep -oE "[0-9]+"); \
	  echo "$$s: $$((c/1000)) cyc/call (of 29868 per NTSC frame)"; \
	done

# ---- link latency/loss simulation ------------------------------------------
sim:
	@$(PY) tools/netsim.py

# ---- in-game hook proof (needs your own rom/ballblazer.atr; not in `test`) --
hooktest:
	@bash tools/test_hook_emu.sh

clean:
	rm -rf $(BUILD)
