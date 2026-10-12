# CLAUDE.md

Mandelbrot set in VHDL. The main board is the MEGA65 (revisions R3 and R6,
XC7A200T, 1280x1024 on VGA and HDMI). The Nexys 4 DDR (XC7A100T, 640x480) is
still supported. [README.md](README.md) is the overview and how to build and
run; [ALGORITHM.md](ALGORITHM.md) explains each module in detail, and holds the
build results and their history. Read the relevant section of ALGORITHM.md
before changing a module.

This repository was split out of the `mandelbrot/` folder of
MJoergen/nexys4ddr. Commits from before the split refer to that folder, and
their `#N` refer to pull requests of that repository.

## Commands
All the tools are installed (Vivado 2025.1, GHDL, VSG, SymbiYosys, GTKWave,
m65, Python with numpy).
* `make sim`: all testbenches in parallel, about 9 minutes (mostly `vga`).
  `make run TB=<name>` runs one. They must all pass after a VHDL change.
* `make formal`: the formal proofs, about 20 seconds.
* `make mega65-r6`, `make mega65-r3` (about 13 minutes each), `make nexys4ddr`
  (about 6 minutes). Run them in the background, or `make -j3 mega65-r3
  mega65-r6 nexys4ddr`. The results are in `build/<board>/vivado.log`.
* `sim/model.py` (about 1 minute): bit-accurate model, and the estimated
  time for the picture. `make run TB=main STOP_TIME=200us` and then
  `sim/cmp_rtl.py` compare the simulated design with the model (about
  14 minutes).
* VSG, on the files that are checked:
  `vsg -c vsg.yml -ap -f $(git ls-files '*.vhd' ':!src/vga/font_pkg.vhd' ':!src/hdmi' ':!src/keyboard')`.
  It must report no errors. Lines over 100 columns (`length_001`) are only a
  warning: a target, not a hard limit, and about 20 lines already exceed it.
  Do not add new warnings without a reason.
* `make fpga BOARD=<board>` loads the bit-file into the real board. Only
  run it when asked.

GHDL can not analyze `src/clk_rst.vhd`, `src/mega65*.vhd`, or
`src/nexys4ddr.vhd` (they need the Xilinx unisim library), so the top levels
are only checked by Vivado.

## Conventions
* MEGA65 first. Where the boards differ, give the MEGA65 first and the
  Nexys 4 DDR second, e.g. "368 job modules (120 on the Nexys 4 DDR)", and
  list the boards as mega65-r3, mega65-r6, nexys4ddr.
* Never use the bit-file of one MEGA65 revision on the other one; some of
  the pins are different.
* Match the style of the existing text in docs, comments, and commit
  messages: plain words, exact numbers with units, and the existing
  spelling (e.g. "colour", "centre").
* Keep the docs in sync with the design. A change that affects resources,
  slack, frame rate, or power updates README.md (Implementation results)
  and ALGORITHM.md (Resources and timing closure), and the earlier result
  stays as history ("The previous run ..."). Some numbers are also in the
  comments of the constants in `src/mega65.vhd` and `src/nexys4ddr.vhd`.
* The statistics of the initial view in ALGORITHM.md are for 1280x1024
  (from `sim/model.py`). The history sections (Timing, and History of the
  ... build) are mostly about the Nexys 4 DDR at 640x480, and stay as they
  are.
* The bit-accurate model must follow `src/main/iterator.vhd`: it is in
  `sim/iterator_model.py`, `sim/model.py`, and `sim/iterator_model_pkg.vhd`.
  The board constants in `sim/model.py` and the defaults of `sim/main_tb.vhd`
  must match `src/mega65.vhd` (see the "Must match" comments).
* Testbenches are self-checking. A new one is added to `TBS` in the Makefile
  and described in ALGORITHM.md.
* `src/hdmi/` and `src/keyboard/` are copied unchanged from the C64MEGA65
  core. Do not edit or restyle them.

## Commits
* No `mandelbrot:` prefix (that was for the nexys4ddr repository). The
  subject says what the commit does, e.g. "Only read the BRAM that holds the
  pixel, to save power".
* The body is a paragraph on why, then `* ` bullets on what changed, ending
  with what was tested: which testbenches, formal proofs, and builds were
  run, the timing results, and whether it was tested on a board.
