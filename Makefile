XILINX_DIR = /opt/Xilinx/2025.1/Vivado

# The m65 tool from the mega65-tools repository
# (https://github.com/MEGA65/mega65-tools), used by the "fpga" target.
M65 = m65

# The coretool from the mega65-tools repository, used by the "cor" target. It
# is a Python script, src/tools/coretool in that repository, and is used as
# it is, e.g. "make cor CORETOOL=~/mega65-tools/src/tools/coretool".
CORETOOL = coretool

# Name of the design. Used for the Vivado script.
NAME = mandelbrot

# Target boards. Each board has its own FPGA part, top level module, source
# files, and constraint file (<board>.xdc). The make target <board> generates
# the bit-file build/<board>/<board>.bit. Vivado is run in build/<board>, so
# all its files (logs, checkpoint, .Xil, etc.) go there, and the boards can be
# built at the same time, e.g. "make -j3 mega65-r3 mega65-r6 nexys4ddr".
BOARDS = mega65-r3 mega65-r6 nexys4ddr
BITS   = $(foreach b,$(BOARDS),build/$(b)/$(b).bit)

# The MEGA65 boards, which also get a core file (build/<board>/<board>.cor)
# from the "cor" target. The name of the target in coretool is the board name
# without the dash, i.e. mega65r3 and mega65r6. The name and the version are
# shown by MEGAFLASH (at most 31 characters each). The version is the current
# commit, with "-dirty" if there are uncommitted changes.
MEGA65_BOARDS = mega65-r3 mega65-r6
CORS          = $(foreach b,$(MEGA65_BOARDS),build/$(b)/$(b).cor)
COR_NAME      = Mandelbrot
COR_VERSION   = $(shell git describe --always --dirty 2>/dev/null)

# Board programmed by the "fpga" target. Must be specified on the command
# line, e.g. "make fpga BOARD=mega65-r6", because the bit-file of one MEGA65
# revision must not be used on the other one.
BOARD =

# The MEGA65 board revisions R3 and R6 have the same FPGA, and the same
# design (src/mega65.vhd). Only the top level modules are different, because
# some of the pins are different. The bit-file of one revision must not be
# used on the other one. The keyboard driver and the HDMI output (both from
# the C64MEGA65 core) are only on the MEGA65. The link to the MAX10 (also
# from the C64MEGA65 core), which reads the reset button, is only on the R3.
MEGA65_SRC  = src/keyboard/kb_matrix_ram.vhd
MEGA65_SRC += src/keyboard/mega65kbd_to_matrix.vhd
MEGA65_SRC += src/keyboard/matrix_to_keynum.vhd
MEGA65_SRC += src/keyboard/m2m_keyb.vhd
MEGA65_SRC += src/hdmi/types_pkg.vhd
MEGA65_SRC += src/hdmi/sync_reg.vhd
MEGA65_SRC += src/hdmi/hdmi_tx_encoder.vhd
MEGA65_SRC += src/hdmi/vga_to_hdmi.vhd
MEGA65_SRC += src/hdmi/serialiser_10to1_selectio.vhd
MEGA65_SRC += src/mega65.vhd

mega65-r3_PART = xc7a200tfbg484-2
mega65-r3_TOP  = mega65_r3
mega65-r3_SRC  = $(MEGA65_SRC) src/max10/max10.vhd src/mega65_r3.vhd

mega65-r6_PART = xc7a200tfbg484-2
mega65-r6_TOP  = mega65_r6
mega65-r6_SRC  = $(MEGA65_SRC) src/mega65_r6.vhd

# The Nexys 4 DDR has a smaller FPGA, and its own top level module, with the
# same design as src/mega65.vhd, but smaller.
nexys4ddr_PART = xc7a100tcsg324-1
nexys4ddr_TOP  = nexys4ddr
nexys4ddr_SRC  = src/nexys4ddr.vhd

# List of source files common to all boards. This is the only list: it is
# also given to the Vivado script (mandelbrot.tcl), followed by the source
# files of the board.
SRC  = src/util_pkg.vhd
SRC += src/text_pkg.vhd
SRC += src/main/iterator.vhd
SRC += src/main/job.vhd
SRC += src/main/job_scheduler.vhd
SRC += src/main/res_scheduler.vhd
SRC += src/main/dispatcher_pkg.vhd
SRC += src/main/dispatcher_jobs.vhd
SRC += src/main/dispatcher_results.vhd
SRC += src/main/dispatcher.vhd
SRC += src/disp_mem.vhd
SRC += src/cdc_data.vhd
SRC += src/vga/video_pkg.vhd
SRC += src/vga/palette_pkg.vhd
SRC += src/vga/disp.vhd
SRC += src/vga/font_pkg.vhd
SRC += src/vga/overlay.vhd
SRC += src/vga/pix.vhd
SRC += src/vga/vga.vhd
SRC += src/main/viewport.vhd
SRC += src/main/controls.vhd
SRC += src/main/fps.vhd
SRC += src/main/view_text.vhd
SRC += src/main/seg.vhd
SRC += src/main/main.vhd
SRC += src/clk_rst.vhd

# Testbenches, i.e. sim/<name>_tb.vhd. The slowest are listed first, so that
# they are started first by "make sim".
TBS = vga redraw picture overlay dispatcher disp_mem iterator viewport job job_scheduler res_scheduler fps view_text cdc_data controls

# Testbench simulated by the "run" and "check" targets. Must be specified on
# the command line, e.g. "make run TB=iterator".
TB =

# Generics of the testbench, as a list of <name>=<value>, e.g.
# GENERICS="G_PIXELS=1". Only used by main_tb.
GENERICS =

# Maximum simulation time. This must be longer than the slowest testbench. The
# testbenches stop by themselves, the slowest of those is vga (about 5.3 ms,
# for 1280x1024). "make sim" counts a testbench that is still running at this
# time as failed.
STOP_TIME = 6ms

TB_EXE = $(TB)_tb
# The clock module uses Xilinx primitives, and is not simulated. The source
# files of the boards (<board>_SRC) are not simulated either. The bit-accurate model of the
# iterator (iterator_model_pkg.vhd) is used by several testbenches.
TB_SRC = $(filter-out src/clk_rst.vhd,$(SRC)) sim/iterator_model_pkg.vhd sim/$(TB)_tb.vhd
WAVE = sim/$(TB).ghw
SAVE = sim/$(TB).gtkw

# Each testbench has its own GHDL work directory, so that several testbenches
# can be analyzed and simulated at the same time (see "make sim").
WORKDIR = build/$(TB)

# The GHDL executable. Set it to try another version of GHDL, e.g.
# "make sim GHDL=/opt/ghdl-4.1/bin/ghdl" (see the tools in README.md).
GHDL = ghdl

GHDL_OPTS = --std=08 -frelaxed-rules --workdir=$(WORKDIR)


#####################################
# Help (default target)
#####################################

.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  help            Show this help text (default)"
	@echo "  mega65-r3       Synthesize and implement the design for the MEGA65 R3 using Vivado (build/mega65-r3/)"
	@echo "  mega65-r6       Synthesize and implement the design for the MEGA65 R6 using Vivado (build/mega65-r6/)"
	@echo "  nexys4ddr       Synthesize and implement the design for the Nexys 4 DDR using Vivado (build/nexys4ddr/)"
	@echo "  cor             Make the core files of the MEGA65 boards using coretool (build/mega65-r3/mega65-r3.cor, build/mega65-r6/mega65-r6.cor)"
	@echo "  fpga            Program the FPGA of a board (BOARD=<board>) with its bit-file using m65"
	@echo "  sim             Simulate all testbenches in parallel using ghdl (logs in build/)"
	@echo "  run             Simulate a single testbench (TB=<name>) using ghdl, without writing a waveform"
	@echo "  check           Simulate a single testbench (TB=<name>) using ghdl, write the waveform, and show it in gtkwave"
	@echo "  formal          Run the formal verification using SymbiYosys (in formal/)"
	@echo "  consts          Check that the constants of the model match the design"
	@echo "  diagrams        Render the block diagrams (doc/*.tex) to PNG using pdflatex"
	@echo "  clean           Remove generated files"
	@echo ""
	@echo "Testbench is selected by TB=<name>, e.g. 'make check TB=iterator'."
	@echo "Available testbenches: $(TBS)"
	@echo ""
	@echo "Board is selected by BOARD=<board>, e.g. 'make fpga BOARD=mega65-r6'."
	@echo "Available boards: $(BOARDS)"


#####################################
# Generate bit-file and program FPGA
#####################################

.SECONDEXPANSION:

.PHONY: $(BOARDS)
$(BOARDS): %: build/$$*/$$*.bit

# The arguments of the Vivado script are the board name, the FPGA part, the
# top level module, and the source files. The stem ($*) is <board>/<board>,
# so the board name is $(notdir $*). The source files are given with absolute
# paths, because Vivado is run in build/<board>.
$(BITS): build/%.bit: $(NAME).tcl $$(notdir $$*).xdc $(SRC) $$($$(notdir $$*)_SRC)
	@mkdir -p $(@D)
	cd $(@D) && bash -c "source $(XILINX_DIR)/settings64.sh ; vivado -mode tcl -source $(abspath $<) -tclargs $(notdir $*) $($(notdir $*)_PART) $($(notdir $*)_TOP) $(abspath $(SRC) $($(notdir $*)_SRC))"

# Make the core files of the MEGA65 boards, which are flashed into a slot with
# MEGAFLASH. Each bit-file is built first, if needed. As with the bit-files,
# the core file of one MEGA65 revision must not be used on the other one.
.PHONY: cor
cor: $(CORS)

$(CORS): build/%.cor: build/%.bit
	$(CORETOOL) --quiet --force --build $@ --bit $< --target $(subst -,,$(notdir $*)) \
	   --bit-name "$(COR_NAME)" --bit-version "$(COR_VERSION)"

# Program the FPGA of the board BOARD with its bit-file, which is built first
# if needed. m65 works for all the boards, i.e. also for the Nexys 4 DDR.
.PHONY: fpga
ifeq ($(BOARD),)

# No board specified, so list the possible ones
fpga:
	@echo "Please specify a board using BOARD=<board>, e.g. 'make fpga BOARD=mega65-r6'."
	@echo "Available boards:"
	@for b in $(BOARDS); do echo "  $$b"; done

else ifeq ($(filter $(BOARD),$(BOARDS)),)

fpga:
	@echo "Unknown board '$(BOARD)'. Available boards: $(BOARDS)"
	@exit 1

else

fpga: build/$(BOARD)/$(BOARD).bit
	$(M65) -q $<

endif


#####################################
# Simulation
#####################################

# Simulate all testbenches (without opening the waveform viewer). The
# testbenches are run in parallel, each by its own target sim-<name>, using
# SIM_JOBS jobs (default: the number of CPUs). If make itself is run with -j,
# that is used instead. The output of each testbench goes to
# build/<name>.log, and a summary is shown at the end. The exit status is
# non-zero if any testbench fails.
SIM_JOBS ?= $(shell nproc 2>/dev/null || echo 1)
SIM_TARGETS = $(addprefix sim-,$(TBS))

.PHONY: sim
sim:
	@rm -f $(addprefix build/,$(addsuffix .status,$(TBS)))
	@$(MAKE) --no-print-directory -k $(if $(findstring jobserver,$(MAKEFLAGS)),,-j$(SIM_JOBS)) $(SIM_TARGETS) || true
	@echo ""
	@echo "=== Summary ==="
	@fail=0; \
	for tb in $(TBS); do \
	   status=`cat build/$$tb.status 2>/dev/null || echo "FAIL (not run)"`; \
	   printf "  %-15s %s\n" $$tb "$$status"; \
	   case "$$status" in PASS*) ;; *) fail=1 ;; esac; \
	done; \
	if [ $$fail -ne 0 ]; then echo "Some testbenches FAILED"; exit 1; fi; \
	echo "All testbenches passed"

# Simulate a single testbench as part of "make sim", with the output going to
# build/<name>.log. A testbench only passes if it has also reported
# "<name>_tb: finished": a testbench that hangs (e.g. waiting for a done flag
# that never comes) runs until STOP_TIME, and then GHDL exits with status 0.
.PHONY: $(SIM_TARGETS)
$(SIM_TARGETS): sim-%:
	@mkdir -p build
	@echo "=== Simulating $* ==="
	@start=`date +%s`; \
	note=""; \
	if ! $(MAKE) --no-print-directory run TB=$* > build/$*.log 2>&1; then \
	   result="FAIL"; \
	elif ! grep -q "$*_tb: finished" build/$*.log; then \
	   result="FAIL"; \
	   note=", not finished by $(STOP_TIME)"; \
	else \
	   result="PASS"; \
	fi; \
	secs=$$((`date +%s` - start)); \
	echo "$$result ($${secs}s$$note)" > build/$*.status; \
	echo "=== $*: $$result ($${secs}s$$note), log in build/$*.log ==="; \
	[ $$result = PASS ]

ifeq ($(TB),)

# No testbench specified, so list the possible ones
.PHONY: run check
run check:
	@echo "Please specify a testbench using TB=<name>, e.g. 'make $@ TB=iterator'."
	@echo "Available testbenches:"
	@for tb in $(TBS); do echo "  $$tb"; done

else

# Analyze, elaborate, and simulate the testbench TB. The argument is extra
# options to the simulation, e.g. --wave=<file>.
define SIMULATE
@mkdir -p $(WORKDIR)
$(GHDL) -i $(GHDL_OPTS) --work=work $(TB_SRC)
$(GHDL) -m $(GHDL_OPTS) $(TB_EXE)
$(GHDL) -r $(GHDL_OPTS) $(TB_EXE) --assert-level=error --stop-time=$(STOP_TIME) $(addprefix -g,$(GENERICS)) $(1)
endef

# Simulate a single testbench (TB=<name>) without writing a waveform, because
# that slows down the simulation considerably.
.PHONY: run
run: $(TB_SRC)
	$(call SIMULATE)

# Simulate a single testbench (TB=<name>), write the waveform to sim/<name>.ghw
# and show it. Not all testbenches have a GTKWave save file (sim/<name>.gtkw).
.PHONY: check
check: $(TB_SRC)
	$(call SIMULATE,--wave=$(WAVE))
	gtkwave $(WAVE) $(wildcard $(SAVE))

endif


#####################################
# Formal verification
#####################################

.PHONY: formal
formal:
	$(MAKE) -C formal


#####################################
# Diagrams
#####################################

# Block diagrams: standalone TikZ, rendered to a PNG next to the .tex file,
# which the Markdown files link to. The PNG is committed, so the docs can be
# read without LaTeX; run "make diagrams" after changing a .tex file. This
# needs pdflatex (with TikZ) and pdftoppm.
BLOCK_DIAGRAMS = doc/dispatcher

.PHONY: diagrams
diagrams: $(addsuffix .png,$(BLOCK_DIAGRAMS))

%.png: %.tex
	pdflatex -interaction=nonstopmode -halt-on-error -output-directory=$(dir $@) $<
	pdftoppm -r 150 -png -singlefile $*.pdf $*
	rm -f $*.pdf $*.aux $*.log

# Check that the constants of the boards in sim/model.py and in the defaults
# of sim/main_tb.vhd are the same as in the design (see sim/check_consts.py).
.PHONY: consts
consts:
	python3 sim/check_consts.py

.PHONY: clean
clean:
	rm -rf .cache
	rm -rf work-obj08.cf
	rm -rf build
	rm -rf $(addsuffix _tb,$(TBS))
	rm -rf */*.ghw
	rm -rf *.o
	rm -rf sim/main_out.txt
	$(MAKE) -C formal clean

