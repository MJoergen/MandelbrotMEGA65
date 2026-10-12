# CLAUDE.md

Mandelbrot set in VHDL. The main board is the MEGA65 (revisions R3 and R6,
XC7A200T, 1280x1024 on VGA and HDMI). The Nexys 4 DDR (XC7A100T, 640x480) is
still supported. [README.md](README.md) is the overview and how to build and
run; [ALGORITHM.md](ALGORITHM.md) explains each module in detail, and holds the
current build results; [HISTORY.md](HISTORY.md) holds the earlier versions of
the modules and the earlier build results. Read the relevant section of
ALGORITHM.md before changing a module.

This repository was split out of the `mandelbrot/` folder of
MJoergen/nexys4ddr. Commits from before the split refer to that folder, and
their `#N` refer to pull requests of that repository.

## Commands
On the author's machine all the tools are installed (Vivado 2025.1, GHDL,
VSG, SymbiYosys, GTKWave, m65, Python with numpy). The versions that are
known to work are in README.md (Tools). In the cloud environment of Claude
Code, the SessionStart hook (`.claude/settings.json`) installs the free tools
with `scripts/install-tools.sh` (the first time about 770 MB), so `make sim`,
`make formal`, and VSG can be run there, but not the builds (no Vivado). The
CI (`.github/workflows/ci.yml`) runs `make formal`, VSG, `make consts`, and
`make sim` on every push and pull request.
* `make sim`: all testbenches in parallel, about 9 minutes (mostly `vga`).
  `make run TB=<name>` runs one. They must all pass after a VHDL change.
* `make formal`: the formal proofs, about 20 seconds.
* `make consts`: checks that the constants in `sim/model.py` and
  `sim/main_tb.vhd` match the design, about 1 second.
* `make diagrams`: renders the TikZ block diagrams (`doc/*.tex`) to the PNG
  files that the docs link to. Commit the PNG together with the `.tex`.
* `make mega65-r6`, `make mega65-r3` (about 13 minutes each), `make nexys4ddr`
  (about 6 minutes). Run them in the background, or `make -j3 mega65-r3
  mega65-r6 nexys4ddr`. The results are in `build/<board>/vivado.log`, and
  the reports of the routed design in `build/<board>/timing.rpt`,
  `utilization.rpt`, and `power.rpt`. A build that fails timing writes no
  bit-file, and make stops with an error.
* `sim/model.py` (about 1 minute): bit-accurate model, and the estimated
  time for the picture. `make run TB=main STOP_TIME=200us` and then
  `sim/cmp_rtl.py` compare the simulated design with the model (about
  14 minutes).
* VSG, on the files that are checked:
  `vsg -c vsg.yml -ap -f $(git ls-files '*.vhd' ':!src/vga/font_pkg.vhd' ':!src/hdmi' ':!src/keyboard' ':!src/max10')`.
  It must report no errors. Lines over 100 columns (`length_001`) are only a
  warning: a target, not a hard limit, and about 20 lines already exceed it.
  Do not add new warnings without a reason.
* `make cor`: the core files (`build/<board>/<board>.cor`) of mega65-r3 and
  mega65-r6, from their bit-files, using coretool (mega65-tools). It is not
  installed in the cloud environment; it is a Python script, so it can be run
  from a clone of mega65-tools with `CORETOOL=<clone>/src/tools/coretool`.
* `make fpga BOARD=<board>` loads the bit-file into the real board. Only
  run it when asked.

GHDL can not analyze `src/clk_rst.vhd`, `src/mega65*.vhd`, or
`src/nexys4ddr.vhd` (they need the Xilinx unisim library), so the top levels
are only checked by Vivado.

## Conventions
* VHDL follows [CODING_STYLE.md](CODING_STYLE.md): naming, alignment, and
  idioms, including the conventions VSG does not check, and the parts of the
  code that do not follow them yet.
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
  and ALGORITHM.md (Resources and timing closure). The earlier result moves
  to HISTORY.md ("The previous run ...", at the start of Builds of the
  MEGA65, Builds of the Nexys 4 DDR, or Power). Some numbers are also in the
  comments of the constants in `src/mega65.vhd` and `src/nexys4ddr.vhd`.
* ALGORITHM.md describes the current design only. When a part changes, the
  description of the earlier version moves to HISTORY.md, and ALGORITHM.md
  may link to it.
* The statistics of the initial view in ALGORITHM.md are for 1280x1024
  (from `sim/model.py`). HISTORY.md is mostly about the Nexys 4 DDR at
  640x480, and stays as it is, apart from the earlier results that are
  added to it.
* The bit-accurate model must follow `src/main/iterator.vhd`: it is in
  `sim/iterator_model.py`, `sim/model.py`, and `sim/iterator_model_pkg.vhd`.
  The board constants in `sim/model.py` and the defaults of `sim/main_tb.vhd`
  must match `src/mega65.vhd` (see the "Must match" comments); `make consts`
  checks this.
* Testbenches are self-checking. A new one is added to `TBS` in the Makefile
  and described in ALGORITHM.md.
* `src/hdmi/`, `src/keyboard/`, and `src/max10/` are copied unchanged from
  the C64MEGA65 core. Do not edit or restyle them.

## Commits
* No `mandelbrot:` prefix (that was for the nexys4ddr repository). The
  subject says what the commit does, e.g. "Only read the BRAM that holds the
  pixel, to save power".
* The body is a paragraph on why, then `* ` bullets on what changed, ending
  with what was tested: which testbenches, formal proofs, and builds were
  run, the timing results, and whether it was tested on a board.
* Work on a branch, and merge it into `main` by fast-forward
  (`git merge --ff-only`), never with a merge commit. The merge commits in
  the older history are not the style to copy. If `main` has moved, so that a
  fast-forward is not possible, ask before rebasing the branch.
