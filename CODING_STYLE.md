# VHDL coding style

This describes how the VHDL files of the Mandelbrot design (`src`, `sim`, and
`formal`) are written. Most of it is checked automatically by
[VSG](https://vhdl-style-guide.readthedocs.io/) with the configuration in
[vsg.yml](vsg.yml), see [Checking the style](#checking-the-style). The rest
(marked *not checked*) is a convention that the author keeps by hand.

The files copied unchanged from the C64MEGA65 core (`src/hdmi`,
`src/keyboard`, and `src/max10`) and the generated `src/vga/font_pkg.vhd` keep their own style
and are not covered.

## Files

* One design unit per file, and the file is named after it, e.g. entity
  `job_wide` is in `job_wide.vhd`, package `video_pkg` is in `video_pkg.vhd`.
  A testbench has the suffix `_tb`. (The exception is
  `formal/iterator_wide_stub.vhd`, a second architecture of `iterator_wide`
  used for the formal verification.)
* Every file starts with a comment block that explains what the module does,
  its interface, and anything surprising about it. Write it for someone who
  has not seen the code before. A testbench says what it checks.
* The library and use clauses come next, at column 0. The use clauses of one
  library are kept together, and a blank line separates different libraries:

  ```vhdl
  library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std_unsigned.all;

  use work.video_pkg.all;
  ```

* Arithmetic on `std_logic_vector` uses `ieee.numeric_std_unsigned`, so most
  signals stay `std_logic_vector`. `ieee.numeric_std` is used where signed or
  unsigned types are needed, and `ieee.math_real` only for constants and in
  testbenches.
* The design is VHDL-2008 (e.g. `std.env.finish`, `maximum`, `to_slv`).

## Layout

* Indent with 3 spaces, never tabs.
* Keep lines under 100 columns. This is a target, not a hard limit (VSG warns).
* Keywords and identifiers are lower case, except where the naming rules below
  say upper case. Bit string literals and exponents are upper case, e.g.
  `X"FF"`, `100.0E6`.
* Blank lines are placed where they help reading. Two blank lines at most, and
  processes are usually separated by two.
* A comment is indented like the code it describes. A comment above a process,
  an instance, or a block belongs to it.
* Sections of an architecture may have a banner:

  ```vhdl
  ---------------------------
  -- Pipeline output signals
  ---------------------------
  ```

* `-- pragma synthesis_off` and `-- pragma synthesis_on`, if needed, are
  written at column 0, so they are impossible to miss.

### Alignment

Alignment is the most visible part of the style. Within a group of lines (lines
not separated by a blank line or a comment line), the colons, the `<=`, and
the end-of-line comments are each aligned in one column.

* In an entity, all the generics have their colons in one column, and all the
  ports in another, for the whole clause, also across blank lines and
  comments. The same goes for the fields of a record, and the `=>` of a port
  map or generic map.
* Port modes are written `in ` (with a trailing space) and `out`, so the types
  line up:

  ```vhdl
  port (
     clk_i        : in  std_logic;
     job_start_i  : in  std_logic;
     job_busy_o   : out std_logic;
     res_addr_o   : out std_logic_vector( 8 downto 0);
  ```

* Vector ranges are padded so they line up, e.g. `( 8 downto 0)` under
  `(17 downto 0)`.
* There is one space after `signal`, `constant`, `type`, etc., i.e. the names
  are not aligned, only the colons after them. The `:=` of an initial value is
  not aligned either.
* In sequential code, signal assignments (`<=`) in a group are aligned, and
  variable assignments (`:=`) are aligned separately. *Not checked* (VSG
  would align both in one column).
* Tables (test cases, video modes, lookup tables) are aligned in columns, with
  numbers aligned to the right.

### Continuation lines

* A long `if` condition continues on the next lines aligned after `if `, and
  `then` goes on a line of its own, aligned with `if`:

  ```vhdl
  if res_valid_s = '1' and res_last_r = '1' and
     res_start_r = '0' and res_ack_i = '1'
  then
  ```

* Other continuation lines (assignments, expressions) are aligned by the author
  so that the structure is clear, typically under the first operand.
* Subprogram parameters, and the literals of a long enumeration type, continue
  under the opening parenthesis:

  ```vhdl
  type state_t is (IDLE_ST, ZOOM_ST, STEP_ST, PREP_ST, MULT_ST, CENTRE_ST,
                   PAN_ST, CLAMP_ST);
  ```

* The elements of a multi-line constant are indented one level from the
  `constant`, and the closing parenthesis ends the last line:

  ```vhdl
  constant C_SEG_TABLE : seg_table_t := (
     "0111111",  -- 0
     ...
     "1101111"); -- 9
  ```

## Naming

| Kind              | Convention                                     | Example       |
| ----------------- | ---------------------------------------------- | ------------- |
| Entity, file      | lower_snake_case                               | `job_scheduler` |
| Port              | lower_snake_case, suffix `_i` or `_o`          | `clk_i`       |
| Generic           | UPPER_SNAKE_CASE, prefix `G_`                  | `G_NUM_ROWS`  |
| Constant          | UPPER_SNAKE_CASE, prefix `C_`                  | `C_ADDR_BITS` |
| Type, subtype     | lower_snake_case, suffix `_t`                  | `state_t`     |
| Unconstrained array type | lower_snake_case, suffix `_vector`      | `int_vector`  |
| Enum literal      | UPPER_SNAKE_CASE, a state has suffix `_ST`     | `IDLE_ST`     |
| Signal            | lower_snake_case, see suffixes below           | `res_valid_r` |
| Variable          | lower_snake_case, suffix `_v`                  | `addr_v`      |
| Process label     | prefix `p_`                                    | `p_fsm`       |
| Instance label    | prefix `i_`                                    | `i_iterator`  |
| Generate label    | prefix `gen_`                                  | `gen_word`    |
| Package           | suffix `_pkg`                                  | `video_pkg`   |
| Architecture      | `rtl`, `structural`, `simulation` (testbench), or `stub` (formal) | |
| Xilinx primitive  | UPPER_CASE, as in the Xilinx library           | `MMCME2_ADV`  |

Signal suffixes (*not checked*) say where a signal comes from:

| Suffix          | Meaning                                                  |
| --------------- | -------------------------------------------------------- |
| `_r`            | A register, assigned in a clocked process                |
| `_s`            | Combinational, assigned outside a clocked process        |
| `_d`            | A delayed (pipelined) copy of another signal             |
| `_d2`, `_d3`, … | The same, delayed by that many clock cycles              |
| `_meta`, `_sync`| The two stages of a clock domain crossing synchronizer  |
| `_n`            | Active low, before the direction suffix (`vdac_sync_n_o`) |

Other naming habits:

* Related signals share a prefix that names the interface or the stage, e.g.
  `res_addr`, `res_data`, `res_valid` for the results, `wr_` and `rd_` for the
  two ports of a memory, and `vga_` for signals in the VGA clock domain.
* Clocks are named `clk` (`clk_i`) or `<domain>_clk`, resets `rst` or
  `<domain>_rst`.
* A testbench has the signals `clk`, `rst`, and usually `finished`, and the
  instance under test is `i_<entity>`.

## Coding idioms

* All logic is synchronous, on `rising_edge(clk_i)`. A clocked process has only
  the clock in its sensitivity list, and no `is`:

  ```vhdl
  p_job_done : process (clk_i)
  begin
     if rising_edge(clk_i) then
        ...

        if rst_i = '1' then
           job_busy_r <= '0';
        end if;
     end if;
  end process p_job_done;
  ```

* Resets are synchronous and active high, and the reset is the *last*
  statement in the process, so it overrides the rest. Only the registers that
  need a reset get one. A reset that goes to many places may be registered
  locally first (see `rst_r` in `job_wide.vhd`).
* Default assignments at the top of a process (e.g. `res_start_r <= '0';`)
  make a pulse last one clock cycle.
* No parentheses around an `if` condition.
* Instantiate entities directly, without the architecture name:

  ```vhdl
  i_iterator : entity work.iterator_wide
     generic map (
        G_MAX_COUNT => G_MAX_COUNT
     )
     port map (
        clk_i   => clk_i,
        ...
        done_o  => res_valid_s
     ); -- i_iterator
  ```

  The closing `);` of an instance has a comment with the instance label.
  Xilinx primitives are instantiated as components (from `unisim.vcomponents`),
  without the `component` keyword.
* The `end` of every construct repeats its kind and name, e.g.
  `end entity job;`, `end architecture rtl;`, `end process p_fsm;`,
  `end generate gen_word;`, `end function log2;`.
* Outputs are driven from internal signals, which are connected to the ports in
  a section at the end of the architecture, so the internal signal can also be
  read.
* Initial values on signals, ports, and variables are used where the power-up
  state matters (e.g. a state machine or for simulation), not everywhere.
* Assumptions about generics are checked with `assert ... severity failure` in
  the architecture.
* A comment at the end of a line in a port map or a generic map may explain a
  literal value, e.g. `CLKINSEL => '1', -- Select CLKIN1`.

## Testbenches

* A testbench is self-checking: it uses `assert` to compare the result with the
  expected value, and reports what went wrong.
* When everything is done it reports `"<name>_tb: finished"` and calls
  `std.env.finish`, so the simulation ends by itself. `make sim` counts a
  testbench as failed if the report is missing from its log.
* Bit-accurate reference models live in a package in `sim`
  (e.g. `iterator_model_pkg.vhd`).

## Checking the style

Install VSG (`pip install vsg`) and run, in the top folder:

```sh
vsg -c vsg.yml -ap -f $(git ls-files '*.vhd' ':!src/vga/font_pkg.vhd' \
                             ':!src/hdmi' ':!src/keyboard' ':!src/max10')
```

Add `--fix` to let VSG fix what it can. Without `-ap`, VSG stops at the first
phase with a violation, so e.g. the naming rules are only checked once the
formatting is right. The reasons for each rule that is changed or disabled are
in the comments of [vsg.yml](vsg.yml).

## Not yet consistent

These parts of the code do not follow the conventions above yet:

* Signal suffixes are used in the core modules (`job_wide`, `iterator_wide`,
  `dispatcher_*`, `disp_mem`, `vga/*`), but not in `viewport*.vhd`, `fps.vhd`,
  `main.vhd`, `seg.vhd`, `clk_rst.vhd`, or the top levels (`mega65*.vhd`,
  `nexys4ddr.vhd`), where most signals are registers without `_r`.
* Delays are written both as `_d2`, `_d3`, … and as `_dd`
  (`disp_mem.vhd`, `dispatcher_jobs.vhd`, `dispatcher_results.vhd`), and
  `_d1` is used next to `_d`.
* Active-low resets are named `rstn`, `rstn_i`, and `main_rstn_sync`
  (`clk_rst.vhd`, `mega65_r6.vhd`) instead of the `_n` suffix used elsewhere.
* Constrained array types use `_t` (e.g. `seg_table_t`), except `mem_vector`
  in `sim/overlay_tb.vhd`.
* 19 lines are over 100 columns, mostly in the testbenches.
