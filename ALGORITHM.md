# The algorithm and its implementation
## Contents
* [Introduction](#introduction)
* [Terms](#terms)
* [Instantiation hierarchy](#instantiation-hierarchy)
* [The Mandelbrot iteration](#the-mandelbrot-iteration)
* [Fixed point arithmetic](#fixed-point-arithmetic)
* [Multiplier](#multiplier)
* [Iterator](#iterator)
  * [Periodicity detection](#periodicity-detection)
  * [Overflow](#overflow)
* [Jobs](#jobs)
* [Dispatcher](#dispatcher)
  * [Timing of a job and a result](#timing-of-a-job-and-a-result)
* [The top level](#the-top-level)
* [Display memory](#display-memory)
* [Redraw](#redraw)
* [View control](#view-control)
* [Frame rate](#frame-rate)
* [Overlay](#overlay)
* [Colours](#colours)
* [Timing](#timing)
* [Resources and timing closure](#resources-and-timing-closure)
  * [MEGA65](#mega65)
  * [Nexys 4 DDR](#nexys-4-ddr)
  * [Power](#power)

The history of the design, i.e. the earlier versions of its parts and the
results of the earlier builds, is in [HISTORY.md](HISTORY.md).

## Introduction
This describes in some detail how the Mandelbrot design works, and the main
parts it is built from. See [README.md](README.md) for an overview, a list of
files, and how to build and run the design.

The design is implemented on the MEGA65 (board revisions R3 and R6), which
uses a Xilinx FPGA XC7A200T. This FPGA has a total of 740 DSPs, of which 720
are used for the actual calculations. Additionally, the FPGA contains 365
BRAMs (of 36 kbit each), of which 320 are used for storing the results of the
calculation, i.e. the actual picture to be displayed (1280x1024). The same
design also runs on the Nexys 4 DDR board, with a smaller FPGA (XC7A100T, with
240 DSPs and 135 BRAMs) and a resolution of 640x480, see
[Nexys 4 DDR](#nexys-4-ddr). The numbers in this document are for the MEGA65,
unless stated otherwise.

On both boards the numbers have 33 fractional bits, so it is possible to zoom
deep into the set, and the maximum count is 1023. Until October 2026 the
Nexys 4 DDR had 16 fractional bits and the maximum count 511, with a simpler
iterator, see [HISTORY.md](HISTORY.md#the-iterator).

The design was first developed on the Nexys 4 DDR, and the MEGA65 was added
later. This document describes the current design. How it got there, i.e.
the earlier versions of its parts, the numbers of the model at the time, and
the results of the earlier builds, is in [HISTORY.md](HISTORY.md), which is
mostly about the Nexys 4 DDR, at 640x480.

## Terms
The following terms are used in this document:
* A *picture column* is a vertical slice of the picture.
* A *job* is 64 rows of a picture column, i.e. a sixteenth of it. The picture
  is divided into 16 *blocks* of 64 rows, so there are 20480 jobs. On the
  Nexys 4 DDR a job is 120 rows (a quarter of a picture column), and there
  are four blocks and 2560 jobs.
* The display memory is divided into blocks too, of one BRAM each (see
  [Display memory](#display-memory)). Which kind of block is meant is clear from
  the context: the display memory, or the jobs.
* A *group* is a group of 16 job modules in the dispatcher, or of 8 blocks in
  the display memory, which share a register for the signals that go to all
  of them, so that each route is shorter.
* A *job module* is an instance of
  [`src/main/job_wide.vhd`](src/main/job_wide.vhd), which calculates one job
  at a time, four rows at a time, using one iterator.
* An *iterator* is the block in
  [`src/main/iterator_wide.vhd`](src/main/iterator_wide.vhd), which
  calculates the counts of four points at the same time, one in each *slot*.
  (The name "wide" is from the time when the Nexys 4 DDR had an iterator for
  narrower numbers.)

## Instantiation hierarchy
The modules are instantiated as follows on the MEGA65:
```
mega65_r6 (or mega65_r3)                src/mega65_r6.vhd, src/mega65_r3.vhd (top level, the pins of each board revision)
 +- max10                               src/max10/max10.vhd (only on the R3: reads the reset button from the MAX10)
 +- mega65                              src/mega65.vhd (the design for the MEGA65)
     +- m2m_keyb                        src/keyboard/m2m_keyb.vhd (keyboard driver, in the MAIN clock domain)
     +- controls                        src/main/controls.vhd (maps the joysticks and keys to the buttons and switches)
     +- clk_rst                         src/clk_rst.vhd (MMCM, clock buffers, and resets)
     +- core                            src/core.vhd (the part that is the same on all the boards, without Xilinx primitives)
         +- main                        src/main/main.vhd (everything in the MAIN clock domain)
         |   +- viewport                src/main/viewport.vhd (view control from the buttons; state machine, types in src/main/viewport_pkg.vhd)
         |   |   +- viewport_axis (x 2) src/main/viewport_axis.vhd (the view along one axis, one for x and one for y)
         |   +- dispatcher              src/main/dispatcher.vhd (types in src/main/dispatcher_pkg.vhd)
         |   |   +- dispatcher_jobs     src/main/dispatcher_jobs.vhd (gives out the jobs, and the done flag)
         |   |   |   +- job_scheduler   src/main/job_scheduler.vhd (selects the job module to receive a job)
         |   |   +- job_wide (x 120)    src/main/job_wide.vhd (the job modules)
         |   |   |   +- iterator_wide   src/main/iterator_wide.vhd
         |   |   |       +- (DSP48E1)   (x 6, inferred in p_dsp, two cascades of three)
         |   |   +- dispatcher_results  src/main/dispatcher_results.vhd (collects the results and writes them)
         |   |       +- res_scheduler   src/main/res_scheduler.vhd (selects the job module whose result is accepted)
         |   +- fps                     src/main/fps.vhd (frame rate, calculated from the time for a picture)
         |   +- view_text               src/main/view_text.vhd (the view as text: the centre and the zoom)
         |   +- seg                     src/main/seg.vhd (7-segment display, not used on the MEGA65)
         +- disp_mem                    src/disp_mem.vhd (display memory, between the two clock domains)
         |   +- disp_blk                src/disp_blk.vhd (one block of the display memory, a BRAM)
         +- cdc_data                    src/cdc_data.vhd (moves the frame rate and the view to the VGA clock domain)
         +- vga                         src/vga/vga.vhd (everything in the VGA clock domain)
         |   +- pix                     src/vga/pix.vhd (pixel counters, for the video mode in src/vga/video_pkg.vhd)
         |   +- disp                    src/vga/disp.vhd (VGA output, uses the palettes in src/vga/palette_pkg.vhd)
         |   +- overlay                 src/vga/overlay.vhd (the view and the frame rate, uses the font in src/vga/font_pkg.vhd)
     +- (p_vdac, i_vdac_clk)            (outputs to the video DAC, for the VGA connector)
     +- vga_to_hdmi                     src/hdmi/vga_to_hdmi.vhd (encodes the picture to TMDS symbols, in DVI mode)
     +- serialiser_10to1_selectio       src/hdmi/serialiser_10to1_selectio.vhd (x 4, the HDMI data and clock)
```
On the Nexys 4 DDR, the top level is `nexys4ddr` (`src/nexys4ddr.vhd`), which
instantiates `clk_rst` and `core` in the same way as `mega65` does, but has no
keyboard, video DAC, or HDMI output, and drives the 7-segment display from
`seg`.

The number of job modules (and therefore iterators, with six DSPs each) is
set by the generic `G_NUM_ITERATORS` of `main`, which the design sets to 120
on the MEGA65 (see `src/mega65.vhd`), and to 39 on the Nexys 4 DDR (see
`src/nexys4ddr.vhd`).

## The Mandelbrot iteration
For each point $c = c_x + i c_y$ in the picture, we iterate
$z_{n+1} = z_n^2 + c$, starting from $z_0 = 0$. The number of iterations needed
before the real or the imaginary part of $z$ is outside the range -2 to 2 (or a
maximum iteration count is reached) is used to colour the pixel, see
[Overflow](#overflow).

The usual test is whether $|z|$ is larger than 2. If the real or the imaginary
part is outside the range -2 to 2, then $|z|$ is at least 2, so the test used
here detects the points outside the Mandelbrot set too, only sometimes a few
iterations later (the count differs by at most 2 for the initial view, with
the earlier 2.16 numbers and the maximum count 511). The points that are
shown as inside the set are the same with both tests, except for points
where $|z|$ becomes exactly 2, such as $c = -2$ (see [Overflow](#overflow)),
and for the few points where $|z|$ only becomes larger than 2 just before the
maximum count, so the test used here reaches the maximum count first (2
pixels of the initial view, with 2.16 and the maximum count 511).

Writing $z = x + iy$, the iteration is
```
new_x = x*x - y*y + cx
new_y = 2*x*y + cy
```
This can be rewritten to use only two (real) multiplications:
```
new_x = (x+y)*(x-y) + cx
new_y = 2*(x*y) + cy
```

## Fixed point arithmetic
Numbers are represented as "fixed point binary two's complement". Specifically,
2.33 bit representation is used (35 bits), i.e. two bits for the integer
portion, and 33 bits for the fraction part.

This means we can represent real numbers in the range -2 .. 2, with an accuracy
of 2^-33, i.e. about 10 decimal places of accuracy. A real number x is
represented using the binary number of x\*2^33, if x is positive, and
(x+4)\*2^33 if x is negative.

The first bit acts as a sign bit. It is '1' if the number is negative, and it
is '0' if the number is positive. The position of the picture and the size of
a pixel, which the view control, the dispatcher, and the job modules work
with, have the same format as the numbers of the iterator.

Some examples are (the bits after the point are grouped by four):
```
-2         : 10.0000 0000 ... 0000 0 = 0x400000000
-1.5       : 10.1000 0000 ... 0000 0 = 0x500000000
-1         : 11.0000 0000 ... 0000 0 = 0x600000000
-2^-33     : 11.1111 1111 ... 1111 1 = 0x7FFFFFFFF
 0         : 00.0000 0000 ... 0000 0 = 0x000000000
 2^-33     : 00.0000 0000 ... 0000 1 = 0x000000001
 0.5       : 00.1000 0000 ... 0000 0 = 0x100000000
 1         : 01.0000 0000 ... 0000 0 = 0x200000000
 1.5       : 01.1000 0000 ... 0000 0 = 0x300000000
```

## Multiplier
The built-in DSP (DSP48E1) provides a 25x18-bit signed multiplier, followed by
a 48-bit adder (the post-adder). The numbers have 35 bits, and x+y and x-y 36
bits, which is too many for one multiplier. Each number is split into a high
part and a low part of 17 bits (unsigned), e.g. a = ah\*2^17 + al, so
```
a*b = ah*bh*2^34 + (ah*bl + al*bh)*2^17 + al*bl
```
The first three products are calculated by three DSPs, which are cascaded:
the first DSP calculates al\*bh and passes it on (PCOUT, without registering
it) to the second DSP, which adds ah\*bl and registers the sum (P). The third
DSP calculates ah\*bh in the same clock cycle and registers it (M), and in the
next clock cycle adds it to that sum shifted 17 bits to the right (the cascade
input PCIN>>17), and registers the result. So each multiplication uses three
DSPs, and the iterator six. The last product, al\*bl (less than 2^34, i.e.
less than 2 LSB of the 2.33 result), is left out. A multiplication with all
four products would need eight DSPs in each iterator, i.e. 92 iterators
instead of 120 on the MEGA65, and 30 instead of 39 on the Nexys 4 DDR.

Without the last product, the new values are slightly too small: by 0 to 2
LSB for x, and 0 to 4 LSB for y (y is twice the product). Half an LSB of the
result is added to each product, which compensates for part of this, but
keeps the values exact when the low parts are zero: e.g. 0 stays 0, and the
points on the real axis keep y = 0. Compared with the truncation of the exact
product, x then differs by -2 to +1 LSB (0 on average), and y by -4 to +1 LSB
(-0.5 on average), measured on random values. The new values are (in units
of 2^-33, where al and bl are the lowest 17 bits of x+y and x-y, and xl and
yl those of x and y)
```
new_x = floor(((x+y)*(x-y) - al*bl + 2^32) / 2^33) + cx
new_y = floor((x*y - xl*yl + 2^31) / 2^32) + cy
```
This formula is symmetric in x+y and x-y, so it does not matter which of them
is given to which input of the multiplier. It is the bit-accurate model of
the iterator, in `sim/model.py` and `sim/iterator_model_pkg.vhd`. The half
LSB is not added in the DSPs (a constant in the input C of the first DSP
prevents Vivado from using the cascade), but by the carry into the adder that
adds cx (bit 15 of the register P of the second DSP for x, and bit 14 for y),
which gives exactly the same result.

At most one of x+y and x-y is outside the range -2 to 2 (see
[Overflow](#overflow)), and that one goes to the input with the most bits:
the high part of the other input can only have 18 bits (the B input of the
DSP), and 19 are needed for 3.33.

The DSPs are not instantiated directly. They are inferred by Vivado from the
process `p_dsp` in
[`src/main/iterator_wide.vhd`](src/main/iterator_wide.vhd), so the
simulation needs no model of the DSP. The "DSP Final Report" in
`build/<board>/vivado.log` shows `A'*B'` (the first DSP of each cascade),
`(PCIN+A'*B')'`, and `(PCIN>>17+(A'*B')')'`, or `(PCIN>>17+(A*B')')'` when
the input A comes from the second DSP through the cascade (ACOUT, after its
register A), as for (x+y)\*(x-y).

The register M of the third DSP is written explicitly in the VHDL. Before, the
inputs of the third DSP were registered twice instead, and Vivado 2025.1 moved
the second register to M. In the full MEGA65 design it did this right for
x\*y, but for (x+y)\*(x-y) it took the input A from the second DSP through the
cascade (ACOUT) and left out the second register (`(PCIN>>17+A*B'')'`, AREG
= 0). So ah came from the wrong slot, and the board showed a wrong picture,
while the simulation of the VHDL (and the synthesis of `iterator_wide.vhd`
alone) was right. `mandelbrot.tcl` now checks after the synthesis that the
inputs A and B of the last DSP of each cascade go through two registers
(counting the register of the cascade, ACASCREG or BCASCREG, of the DSP
before it), and stops with an error otherwise.

## Iterator
This component
([`src/main/iterator_wide.vhd`](src/main/iterator_wide.vhd)) performs the
main calculation. It takes as input the complex numbers c of four
consecutive rows of a picture column (a result of the job module, see
[Jobs](#jobs)): they have the same cx, and the values of cy are cy, cy+stepy,
cy+2\*stepy, and cy+3\*stepy. It then iterates the Mandelbrot function for
each of them, and stops when either the maximum iteration count is reached,
or an overflow occurs.

The inputs to this block are: start\_i, cx\_i, cy\_i, and stepy\_i. Outputs
are done\_o and cnt\_o (the four counts, the first row in the lowest bits).
The values of cx\_i, cy\_i, and stepy\_i must be held constant for the
entire calculation. stepy\_i is registered in the iterator before it is
added to cy, so it must be stable one clock cycle before start\_i. The signal start\_i is pulsed high for a single clock
cycle. The signal done\_o goes high when all four points are finished, and
stays high, with cnt\_o unchanged, until the next start\_i.

Example: We start with the point -0.5+0.5i, i.e. cx = -0.5 and cy = 0.5. This
point is in the Mandelbrot set, so the iteration continues until the maximum
count (or until the periodicity detection stops it, see below). The expected
sequence of points is then:
```
cnt |   x                          |   y
----+------------------------------+------------------------------
 0  |  0.0000000000 (000000000)    |  0.0000000000 (000000000)
 1  | -0.5000000000 (700000000)    |  0.5000000000 (100000000)
 2  | -0.5000000000 (700000000)    |  0.0000000000 (000000000)
 3  | -0.2500000000 (780000000)    |  0.5000000000 (100000000)
 4  | -0.6875000000 (6A0000000)    |  0.2500000000 (080000000)
 5  | -0.0898437500 (7D2000000)    |  0.1562500000 (050000000)
 6  | -0.5163421631 (6F7A20000)    |  0.4719238281 (0F1A00000)
 7  | -0.4561028702 (71679AF42)    |  0.0126516595 (0067A4740)
 8  | -0.2921302365 (76A6DE7D8)    |  0.4884590835 (0FA174F1A)
```
The values in the parentheses are the (2.33 fixed point) hexadecimal
representation of the values, and the decimal numbers are these values rounded
to ten decimals. The values are calculated with the bit-accurate model (see
below). Up to iteration 7 they are exact, but from iteration 8 the new values
need more than 33 fraction bits, and the iterator rounds them (see
[Multiplier](#multiplier)). So the values differ slightly from a calculation
with real numbers: in iteration 8 x is 1.7 LSB too small, and y 0.4 LSB.

**Pipeline and slots.** The iteration takes four clock cycles: x+y and x-y are
calculated in the fabric and registered in the DSPs (the registers A and B);
the first two DSPs calculate their products and the sum, and the third DSP
its product; the third DSP adds the sum to its product; and cx and cy are
added in the fabric, together with the overflow check, and the new values
are registered (x\_r and y\_r). In each clock cycle, each of the four stages
works on a different point. So the iterator calculates four points at the
same time, in turns, one iteration of each point in every four clock cycles,
and one iteration in every clock cycle in total. The iterator calculates the
values of cy of the four rows when it is started. The point in x\_r and y\_r
is called the slot; each slot has its own value of cy, its own saved values
for the periodicity detection, and its own count. The values of cy and the
saved values are in shift registers of four entries, which move along with
the slots, so the values of the slot in x\_r and y\_r are always in the first
entry. All four points have done the same number of iterations when they are
in x\_r and y\_r, so one counter is enough.

At the start, x\_r and y\_r are cleared for each slot (in the first four clock
cycles). A point that stops after n iterations is done 4n+k+3 clock cycles
after the start, where k is its slot (0 to 3), and the iterator is done (done\_o
is high) when the last of the four points is done. The slots that are done
before the others wait for them: for the initial view the iterator is busy
89% of the time with points that are not done yet, between 83% and 98% for the
other views in the model, and 100% when all the points need the maximum count.

**While idle.** After the last of the four points is done, x\_r and y\_r, the
shift registers of cy, and the saved values keep their value until the next
start: their clock enable is the flag `run_r`, which is high from the start
until all four points are done. So nothing in the iterator toggles while it
is idle, i.e. between the jobs and when no picture is calculated (see
[Redraw](#redraw)). The DSPs themselves have no clock enable: their inputs
come from x\_r and y\_r, so the registers of the DSPs stop changing three
clock cycles after done\_o goes high, and the DSPs are inferred in the same
way as without the clock enable. The clock enable of x\_r and y\_r is still
low in the clock cycle of the start, where they are cleared, and the clear
has priority over it, so the start is the same as without it.

**Resources.** Out of context (only the iterator, on the XC7A200T-2, before
the clock enables were added), the iterator uses 6 DSPs, 365 LUTs, and 330
registers, and meets 180 MHz with +0.650 ns of slack: the longest path is
from the sign bit of y, through the adder for x+y or x-y, to the input of a
DSP. In the whole design each job module (with its iterator) uses 415 LUTs
and 520 registers (36 more than before stepy was registered in the iterator). On both boards the number of job modules is limited by
the number of DSPs, see [Resources and timing closure](#resources-and-timing-closure).

**Tests.** The testbench [`sim/iterator_wide_tb.vhd`](sim/iterator_wide_tb.vhd)
is self-checking. It runs a few starting values (in the set, escaping
immediately, escaping quickly, and escaping slowly), four at a time (either
the same point, or four points that finish at different times), and
compares each count exactly with the bit-accurate model, and with a count
calculated using real numbers, within a tolerance of 1. All the counts are
equal to the real ones. It also checks that the points in the set are found
by the periodicity detection, points where x+y or x-y is outside the range
-2 to 2 during the iteration (see [Overflow](#overflow)), points where only x
(-1+i) or only y (the real axis) repeats a saved value, values of cy that
wrap around, and a grid of 40 x 32 points over the initial view. While the
iterator is idle, it checks that x\_r and y\_r do not change, and that the
registers P of the DSPs do not change from four clock cycles after done\_o
(`p_idle`). Without the clock enable of x\_r and y\_r, this check fails.

The bit-accurate model is written in VHDL, in the package
[`sim/iterator_model_pkg.vhd`](sim/iterator_model_pkg.vhd). The testbenches
for the job module and the dispatcher compare every value with this model,
and require them to be equal. The iterator testbench still compares with
real numbers too, so that it also checks that the model (i.e. the design)
calculates the Mandelbrot iteration.

The complete picture can be checked bit-accurately too. The script
[`sim/model.py`](sim/model.py) is a vectorized (numpy) version of the same
model, which calculates the count for every pixel of the initial view, using
the same values of c as the design. Run as a script, it compares the model with
a calculation using real numbers, for both boards. The testbench
[`sim/main_tb.vhd`](sim/main_tb.vhd) runs `main.vhd` with the initial view, and
writes every pixel written to the display memory to the file
`sim/main_out.txt`. The script [`sim/cmp_rtl.py`](sim/cmp_rtl.py) then compares
these values with the model. The first line of the file is the size of the
picture, the address distance between two picture columns, and the maximum
count, so the script knows the view, and how to decode the addresses. By
default the testbench simulates the design of the MEGA65 (120 job modules,
four pixels in each write, jobs of 64 rows, 1280x1024 with 21 bits of
address, and the maximum count 1023). Its generics select the smaller design
of the Nexys 4 DDR (39 job modules, jobs of 120 rows, 640x480 with 19 bits of
address) with
`GENERICS="G_NUM_ITERATORS=39 G_PIXELS=4 G_ROWS_IN_JOB=120 G_NUM_COLS=640 G_NUM_ROWS=480 G_COL_STRIDE=512 G_ADDR_BITS=19 G_MAX_COUNT=1023"`,
see the Makefile. A complete picture takes a long time to simulate, but a
partial picture can be compared too:
```
make run TB=main STOP_TIME=200us
sim/cmp_rtl.py
```
The 200 us of simulated time gives about 79000 pixels on the MEGA65 (about
10 minutes, see [MEGA65](#mega65)), and about 36000 pixels on the
Nexys 4 DDR (about 5 minutes). This testbench is not part of
`make sim`.

The testbench [`sim/picture_tb.vhd`](sim/picture_tb.vhd) does the same
check inside the testbench, with the VHDL model, for a small picture (64x48,
with 8 job modules, four pixels in each write, and jobs of 12 rows), so it is
part of `make sim`. It checks every pixel of three pictures (the initial
view, then the view after zooming in and panning, and then after zooming
out): each pixel is written exactly once, the picture is complete when the
frame rate is updated, and the value of each pixel is the value of the
model. The view of each picture is read from `main` with external names. It
uses the maximum count 127 instead of 1023, because with 1023 the simulation
took more than half an hour.

The testbench [`sim/core_tb.vhd`](sim/core_tb.vhd) checks the whole design
from the buttons and switches to the VGA output, i.e. `core` with the clocks
of the Nexys 4 DDR (in the same ratio, 120 MHz and 25 MHz, but about 17 times
faster). A picture of a real size is too slow to simulate (the first picture
is the initial view, which is mostly inside the set), so the video mode is
560x4 (560 is the smallest width that `vga` accepts, because of the overlay),
with short blanking, and the maximum count is 127 instead of 1023. For two
pictures (the initial view with palette 1, and the view after pan right held
down for one update, with palette 3) it waits until the picture is complete,
and then checks the colour of every pixel of the next frame of the VGA output
against the model and the palette. It also checks that the frame rate and the
view in the VGA clock domain are those of the MAIN clock domain, after
`cdc_data`. The palette does not move in this testbench (that is checked by
`disp_tb`). It takes about 9 minutes, and is part of `make sim`.

The board constants in `sim/model.py` and the defaults of the generics of
`sim/main_tb.vhd` are copies of those in `src/mega65.vhd` (and the model also
has those of `src/nexys4ddr.vhd`). `make consts` runs
[`sim/check_consts.py`](sim/check_consts.py), which reads the constants
from the VHDL files and checks that the copies are the same.

### Periodicity detection
Points in the Mandelbrot set never overflow, so they would take the maximum
number of iterations (1023). For the initial view, 27% of the pixels are in
the set, and they need 98% of all the iterations. But for most of them the
values of x and y start to repeat exactly after a while: x and y have only 35
bits each, so an orbit that converges to a fixed point or a cycle ends up in
an exact cycle of values. Once the values after iteration n are equal to the
values after an earlier iteration m, the iteration repeats the same values
for ever, without an overflow, so the count is the maximum count. So the
iterator can stop as soon as it sees a repeated value, and the count is
exactly the same as without stopping early.

This is detected in the same way as in
[Brent's cycle detection algorithm](https://en.wikipedia.org/wiki/Cycle_detection#Brent's_algorithm).
The values of x and y of each slot are saved (sx\_r and sy\_r) after the
iterations 1, 2, 4, 8, 16, and so on, i.e. after each power of two. In each
iteration from iteration 2 the current values (in x\_r and y\_r) are
compared with the saved values of the slot. The saved values are not cleared
at the start of a point, because the clear would need an extra LUT for each
bit; they are only loaded, using the clock enable. The saved values are from
an earlier iteration, and the gap between the saved iteration and the
current one keeps growing, so a cycle is found once the saved values are in
the cycle and the gap is at least the length of the cycle. Both x and y must
be equal: in rare cases only one of them repeats, for points that escape
later.

When they are equal, the iteration of that slot stops, with the count
G\_MAX\_COUNT. The comparison is not in the paths of the iteration itself.

With 35 bits, the values take longer to repeat exactly than with the earlier
18 bits: for the initial view, the detection stops 303913 of the 347793
pixels in the set early, after 275 iterations on average (against 124 with
18 bits, at 640x480), and the average number of iterations of all the pixels
is 79, instead of 278 without the detection. The rest of the pixels in the
set (near the edge of the set) do not reach a cycle within 1023 iterations.

### Overflow
The iteration stops when the new value of x or y is outside the range -2 to 2
(not including 2), which is the range of the 2.33 number format. For points
that are not in the Mandelbrot set, the values grow quickly once they get out
of this range.

The range is checked on the sums `(x+y)*(x-y) + cx` and `2*x*y + cy`, before
they are truncated to 35 bits, and not on the products alone. A product can
be outside the range of the final value, even when the sum with cx or cy is
inside the range, and the other way around. The new value of x is between -6
and 6 (37 bits), and the new value of y between -10 and 10 (38 bits), so
they can not overflow. The new x is in range if the three top bits are
equal, and the new y if the four top bits are equal. The new values of x and
y are then the lowest 35 bits.

The count returned in cnt\_o is the number of the first iteration where the
value is out of range, or the maximum count if this does not happen.

The value 2 itself is outside the range. So the point $c = -2$, which is in
the Mandelbrot set ($z$ is -2, 2, 2, 2, ...), gets the count 2, as if it was
outside the set. Points very close to -2 are not affected (e.g. for
$c = -2 + 2^{-33}$, $z_2$ is $2 - 3 \cdot 2^{-33}$, which is in range). This
is only a single point, so it does not matter for the picture.

The values x+y and x-y, which are the inputs to the first multiplication,
are between -4 and 4, so they need 36 bits (3.33 format). The high part of
the second input of the multiplication (the B port of the DSP) has only 18
bits, i.e. 35 bits in all. However, at most one of x+y and x-y is outside the
range -2 to 2:
* If x and y have the same sign bit, then x-y is in the range -2 to 2.
* Otherwise, x+y is in the range -2 to 2.

So the one of them that may be out of range is given to the first input of
the multiplication, and the other one to the second input. The choice only
depends on the sign bits of x and y, so each input is calculated by a single
adder, which adds or subtracts y: the first one x+y when the sign bits are
equal, and x-y otherwise, and the second one the other way round.
Subtracting means adding y with all bits inverted, plus a carry into the
adder, so each bit needs only one LUT.

**Accuracy.** For the initial view (1280x1024), 99.86% of the pixels have
exactly the same count as a calculation with real (64-bit floating point)
numbers, and 196 of the 1.3 million pixels are on the other side of the
boundary of the set (`sim/model.py`). At 640x480 it is 99.84% and 46 of
307200 pixels. With the earlier 2.16 numbers it was 98.6% and 1390 pixels
(and 98.5% and 292 pixels at 640x480).

## Jobs
There is one iterator in each job module, and therefore six DSPs, and there
are `G_NUM_ITERATORS` job modules (120 on the MEGA65, and 39 on the Nexys 4
DDR). `G_NUM_COLS` is the number of picture columns, not of job modules. The
number of rows in a job is the generic `G_ROWS_IN_JOB` of the dispatcher
(`C_ROWS_IN_JOB` in the design: 64 on the MEGA65, and 120 on the Nexys 4 DDR;
1024 is not a multiple of 120), which is the generic `G_NUM_ROWS` of the job
module.

Each job is calculated in its entirety by one job module
([`src/main/job_wide.vhd`](src/main/job_wide.vhd)).

The inputs to a job module are:
```
job_start_i  : in  std_logic;
job_cx_i     : in  std_logic_vector(34 downto 0);
job_starty_i : in  std_logic_vector(34 downto 0);
job_stepy_i  : in  std_logic_vector(34 downto 0);
```
and the output is:
```
job_busy_o   : out std_logic;
```
The signal job\_start\_i is pulsed high for one clock cycle to initiate the
calculation of a job, and the output job\_busy\_o remains high until the entire
calculation is finished. The value job\_starty\_i is cy of the first row of
the job.

The results of the calculation are presented on the following output ports:
```
res_addr_o   : out std_logic_vector( 8 downto 0);
res_data_o   : out std_logic_vector(9*G_PIXELS-1 downto 0);
res_valid_o  : out std_logic
```
with the additional input port
```
res_ack_i    : in  std_logic;
```
Each result is the values of `G_PIXELS` consecutive rows (4, see
[Timing](#timing)), which the dispatcher writes to the display memory as one
word. The res\_addr\_o is the row number of the first of these rows, counted
from the first row of the job, and res\_data\_o is the calculated values,
with the value of the first row in the lowest 9 bits. The res\_ack\_i is
needed, because there may be an arbitrarily long delay before the job
dispatcher has time to acknowledge the result. The number of rows in a job
must be a multiple of 4.

The iterator calculates the four rows of a result at the same time, so
`G_PIXELS` must be 4. The job module starts the iterator with cy of the first
row of the result, and stepy, and the iterator calculates cy of the other
three rows. When the result has been acknowledged, it starts the next four
rows, with cy plus 4\*stepy, which gives exactly the same values as adding
stepy for each row (in 35 bits). The maximum count is 1023, so the count has
10 bits, but the display memory has 9 bits for each pixel. So the value of a
pixel is 511 for the points in the set (the count is G\_MAX\_COUNT), and
otherwise the count modulo 511 (0 to 510), which is converted in the output
register of the job module: 511 is subtracted from the count once or twice,
if it is at least 511. The palettes have 512 entries (see
[Colours](#colours)), and the palette offset is also calculated modulo 511,
so the colours of the counts 0 to 510 repeat for the larger counts.

The testbench for the job module ([`sim/job_wide_tb.vhd`](sim/job_wide_tb.vhd))
is self-checking. It runs a few jobs, of 12 rows (three results) and of 4
rows (a single result), and checks that the job module is busy only during a
job, that the results come in order, with the right row numbers, that a
result stays unchanged until it is acknowledged (the acknowledge is delayed
by a varying number of clock cycles), and that the value of each row is
exactly the value calculated by the bit-accurate model (see
[Iterator](#iterator)). One of the jobs has values of cy that wrap around
from 2 to -2.

## Dispatcher
This ([`src/main/dispatcher.vhd`](src/main/dispatcher.vhd)) is essentially the top level
entity controlling the calculation of the entire picture. This is perhaps the
most complicated module. The input signals are:
```
start_i   : in  std_logic;
startx_i  : in  std_logic_vector(34 downto 0);
starty_i  : in  std_logic_vector(34 downto 0);
stepx_i   : in  std_logic_vector(34 downto 0);
stepy_i   : in  std_logic_vector(34 downto 0);
```
and the output is:
```
done_o    : out std_logic
```
The signal start\_i is pulsed high for one clock cycle to initiate the
calculation. The signal done\_o goes high when the calculation is finished, and
stays high until the next start\_i. Three additional output signals go to the
display memory:
```
wr_addr_o : out std_logic_vector(G_ADDR_BITS-1 downto 0);
wr_data_o : out std_logic_vector(9*G_PIXELS-1 downto 0);
wr_en_o   : out std_logic;
```
The data is the 9-bit values of `G_PIXELS` consecutive rows of a picture
column (a result of a job module, see [Jobs](#jobs)), and the address
is that of the first of them. The values are stored in the display memory, see
[Display memory](#display-memory).

This module instantiates a configurable number of job modules (`job_wide`,
120 on the MEGA65 and 39 on the Nexys 4 DDR, one for each six DSPs). It keeps
track of which job modules are currently calculating, and whenever a job
module is idle, the next job is sent to it. The values (the job of each job
module) have 35 bits; the type `value_vector` in `dispatcher_pkg.vhd` is an
array of vectors whose width is given where it is used (VHDL-2008).

The dispatcher has two parts, with the job modules between them:
[`src/main/dispatcher_jobs.vhd`](src/main/dispatcher_jobs.vhd) gives out
the jobs (with i\_job\_scheduler) and sets the done flag, and
[`src/main/dispatcher_results.vhd`](src/main/dispatcher_results.vhd)
accepts the results (with i\_res\_scheduler) and writes them to the display
memory. Only two things go from the first part to the second: the active
flag of the schedulers, and, for each job that is started, the index of the
job module, the picture column, and the block of the job. The second part
writes these to its tables (`job_addr_r` and `job_blk_r`) one clock cycle
after the job is started, long before the job module has a result. The
tables are written and read in the same module, so that they can still be a
RAM: the hierarchy is not flattened in synthesis (`-flatten_hierarchy none`
in `mandelbrot.tcl`), and every signal between the parts comes from a
register.

The jobs are given out one block at a time: first all the picture columns
(1280) of the top 64 rows, then all the picture columns of the next 64 rows,
and so on. After the last picture column of a block, cx starts again from the
left edge, and starty moves to the next block, by adding 64 times stepy (in
35 bits, like the job modules add stepy, so cy of each row is the same as if
the picture column was calculated in one job). The multiplication by the
constant `G_ROWS_IN_JOB` (64, or 120 on the Nexys 4 DDR) is done once for
each picture, in LUTs, because all the DSPs are used by the iterators. The dispatcher keeps the picture column and the block
of the job of each job module, and when a result is accepted it adds the
first row of the block to the row from the job module, to get the row in
the picture.

The address in the display memory is the picture column times the generic
`G_COL_STRIDE`, plus the row. On the MEGA65 `G_COL_STRIDE` is 1024, so the
address is the picture column (11 bits) followed by the row (10 bits). On the
Nexys 4 DDR `G_COL_STRIDE` is 512, so the address is the picture column
(10 bits) followed by the row (9 bits). On both boards the multiplication and
the addition are only wires. The address has `G_ADDR_BITS` bits (21 or 19). For other values of
`G_COL_STRIDE` (e.g. 600, when the MEGA65 showed 800x600 in the 2^19 pixels of
the old display memory) the address is calculated in two pipeline stages: the
multiplication by the constant (in LUTs, like the multiplication by
`G_ROWS_IN_JOB`), and then the addition of the row. The extra stage is there for
a power of two too, as registers, so the write has one more clock cycle of
latency than it would need.

Smaller jobs make the work more evenly shared between the job modules at
the end of the picture, see [Timing](#timing). The order of the jobs matters
less: other orders were tried in the model (e.g. column by column, or starting
from the middle of the picture), and the best order depends on the view.

A separate scheduler module is used to send jobs to the different job
modules. Currently, the scheduler for the jobs operates in a round-robin
fashion over all the job modules, one per clock cycle. This potentially
may give a delay up to 120 clock cycles before an idle job module is
given a job, i.e. 0.64 us at 187.8 MHz. The job modules wait in
parallel, and with 20480 jobs and 120 job modules, each job module gets
about 171 jobs on average. So the delay adds at most about 107 microseconds
(and half of that, i.e. about 1%, on average) to the time for a picture,
which is about 5.88 ms. With the 368 job modules of the MEGA65 before the
wide iterator, it added at most about 145 microseconds to about 2.53 ms. On
the Nexys 4 DDR (up to 39 clock cycles, i.e. 0.33 us at 120 MHz, and about
66 jobs for each job module) it adds at most about 21 microseconds to about
7.1 ms.

The scheduler ([`src/main/job_scheduler.vhd`](src/main/job_scheduler.vhd)) has a counter that
goes round all the job modules, one per clock cycle, and selects a job
module when the counter reaches it and it is idle. Selecting the busy flag of
one of the job modules in a single clock cycle was too slow with 368 job
modules (the MEGA65 before the wide iterator), so it is done in two steps: first, in each group of 16 job modules, the busy flag at
the position of the counter in the group is registered, and in the next clock
cycle the flag of the group of the counter is used.

The job modules are spread over the whole FPGA, so the signals that go from
the dispatcher to all of them have long routes. To keep each route shorter,
these signals go through an extra register in each group of 16 job modules
(the generic G\_GROUP\_SIZE, so there are 8 groups on the MEGA65, the last
one with 8 job modules, and 3 on the Nexys 4 DDR, the last one with 7): the
job (cx, starty, and stepy), the start of the job, the reset, and the index of
the job module whose result is accepted. The registers of the groups are
identical, so they have the attribute `keep`, which prevents the synthesis
tool from merging them.
Each job module registers the reset once more, so the reset register of a
group drives only 16 registers.

A result is accepted in four steps. First, the index of the job module
selected by i\_res\_scheduler goes to the register in each group. Then each
group acknowledges the selected job module, if it is in the group, and
selects its result. Then the result is selected from the group of the job
module, and its row in the picture and the address of its column are
calculated. Finally, the address is calculated from the column and the row
(see above), and the result is written to the display memory. The job module
keeps its result until it has seen the acknowledge, so the result is still
there when its group selects it. Because of the extra registers, the
scheduler for the jobs sees that a job module is busy five clock cycles after
it has sampled its busy flag and selected it, so the dispatcher needs at
least five job modules.

The display memory can take one result (one word of `G_PIXELS` pixels) in each
clock cycle, and the scheduler
for the results ([`src/main/res_scheduler.vhd`](src/main/res_scheduler.vhd),
i\_res\_scheduler) tries to use as many of these clock cycles as possible.
Each group of 16 job modules (the same groups as above) registers the
ready flags of its job modules, and then, in the next clock cycle, a
candidate: one of its job modules that has a result ready, picked in
round-robin order within the group, i.e. the first one after the job module
that was accepted last time. The ready flags are registered first, so that the
routes from the job modules and the round-robin selection are in separate
clock cycles. A counter goes round the 8
groups, one per clock cycle, and the candidate of the
group of the counter is accepted, if the group has one. So, unlike an idle
job module waiting for a job, a job module with a result waits until
its group is visited, i.e. at most 8 clock cycles, plus 8 clock cycles for
each job module of its group that is before it in the round-robin order.

A job module has a result ready when its result is valid and has not been
acknowledged. The ready flags and the candidate of a group are registered, so
a job module that has just been accepted can still be the candidate of its
group for three more clock cycles, until the acknowledge has reached it and
the ready flags have been registered again. The counter therefore visits each
group at most once every five clock cycles (when there are fewer than five
groups, the counter has empty positions), so a job module can not be
accepted twice for the same result.

The done flag (done\_o) needs to know that all 120 job modules are idle. The
busy flags are first combined in each group of 16 job modules, in a
register, and then the 8 groups are combined. The done flag is not set while
a job has just been started, until the busy flag of the job module has
reached the register of its group.

The dispatcher has a self-checking testbench
([`sim/dispatcher_tb.vhd`](sim/dispatcher_tb.vhd)). It calculates two small
pictures (64 by 16 pixels, with 16 job modules in groups of 5, so the last
group is smaller, and four jobs of 4 rows in each picture column, i.e. one
result each), one right after the other, and checks that each pixel is
written exactly once, that each write starts at a row that is a multiple of
4, that everything has been written when done\_o goes high, that done\_o
goes low when a new picture is started, and that the value of each pixel is
exactly the value calculated by the bit-accurate model (see
[Iterator](#iterator)) for the value of c of that pixel. This also checks
that each result is written to the right address. It then repeats this for
two pictures with a single picture column, i.e. with fewer picture columns
than job modules, which is a special case for done\_o, so every job is the
last picture column of its block. Finally it repeats this for two pictures
with two jobs of 8 rows (two results) in each picture column. The first two
instances have 512 and 16 addresses for each picture column, so the address
is the picture column followed by the row, and the third has 20, which is
not a power of two (like 600 when the MEGA65 showed 800x600). The last
picture has a pixel of 2^-28, near the top of the range, so cy wraps around
from 2 to -2. The simulation takes about 80 seconds.

The scheduler has a small self-checking testbench
([`sim/job_scheduler_tb.vhd`](sim/job_scheduler_tb.vhd)), with 21 processes, i.e. two
groups, where the second one is smaller. It checks that nothing is started
when the scheduler is not active or when everything is busy, that each idle
process is started once per round and busy processes never, that the
processes are started in round-robin order, and that reset restarts the
scheduler from the first process.

The scheduler for the results has a self-checking testbench too
([`sim/res_scheduler_tb.vhd`](sim/res_scheduler_tb.vhd)). Each process
behaves like a job module: when it has a result, it is ready until the
result has been accepted, and its ready flag goes low as late as allowed. It
then gets a new result after a random delay. The testbench checks that
nothing is selected when the scheduler is not active or nothing is ready,
that only a process that is ready is selected and each result only once, that
every ready process is selected within the expected time (also when all the
processes are ready all the time), and that all the results are selected. It
does this for 21 processes in groups of 5 (so the last group is smaller), and
for 6 processes in a single group (so the counter has empty positions).

### Timing of a job and a result
The parts of the dispatcher, and the processes and registers of each step,
are:

![The parts of the dispatcher](doc/dispatcher.png)

The diagram is generated from [`doc/dispatcher.tex`](doc/dispatcher.tex)
with `make diagrams`.

All the signals between the parts are registers, so a job and a result can
be followed one clock cycle at a time. The tables give the clock cycle in
which each signal is high (or has the value given).

**A job.** In clock cycle t the counter of `job_scheduler` is at job module
i, which is idle:

| Clock cycle | What happens
| ----------- | ------------
| t   | `job_busy_i(i)` is low, and goes to `grp_busy_r` of its group
| t+1 | `grp_busy_r` of the group is low, so job module i is selected
| t+2 | `job_idx_valid_o` is high, with `job_idx_start_o` = i
| t+3 | `job_start_r(i)` and `job_started_r` are high, the job is in `tbl_*_o`, and c of its first row in `job_cx_r` and `job_starty_r`
| t+4 | `job_start_o(i)` (`job_start_d`) is high, and the job is in `grp_cx_r`, `grp_starty_r`, and `grp_stepy_r` of each group. `dispatcher_results` writes the job to its table
| t+5 | The job module is busy (`job_busy_o`), and starts the iterator with the first row (`res_start_r`)
| t+6 | `grp_job_busy_r` of the group has the busy flag

The waveform shows this for the first jobs of a picture, in a simulation
of the first instance of `sim/dispatcher_tb.vhd` (16 job modules in groups
of 5), following job module 6 (in group 1). It was made with the earlier
version of the testbench, with the 2.16 job modules (`job.vhd`) and one pixel
in each write, which have the same timing as `job_wide.vhd` here (the job
module is busy, and starts the iterator, in the clock cycle after its start). The scheduler is started in t-1, and all the job
modules are idle, so it selects one job module in each clock cycle. The
values of the job followed are white, and those of the other jobs are light
grey:

![Timing of a job](doc/timing_job.png)

So:
* The scheduler samples the busy flag of job module i again
  `G_NUM_ITERATORS` clock cycles after t, and the flag is high from t+5, so
  the dispatcher needs at least five job modules (it asserts this, and
  `dispatcher_jobs.psl` proves that a job module is only started when it is
  idle).
* The done flag ignores the busy flags while a job has just been started:
  `job_started_r`, `job_started_d`, and `job_started_dd` are high in the
  clock cycles t+3, t+4, and t+5, and from t+6 `grp_job_busy_r` has the
  busy flag.

**A result.** In clock cycle r job module i has a new result:

| Clock cycle | What happens
| ----------- | ------------
| r   | `res_valid_i(i)` is high, with the row in `res_addr_i(i)` and the counts in `res_data_i`
| r+1 | `res_busy_r(i)` is low, so the ready flag (`res_ready_s(i)`) is high, and goes to `req_r` of its group in `res_scheduler`
| r+2 | The candidate of the group is picked from `req_r`
| r+3 | `cand_r` of the group is job module i (if it is next in the round-robin order), and the counter is at the group (if not, the next clock cycles are the same, until it is)
| c (r+4 at the earliest) | Job module i is selected: `idx_valid_r` is high, with `idx_iterator_r` = i
| c+1 | Step 1: `grp_idx_r` and `grp_valid_r` in each group, and the job of i from the table in `acc_job_addr_r` and `acc_blk_r`
| c+2 | Step 2: `res_ack_o(i)` (`res_ack_r`) is high, so `res_ready_s(i)` is low. The result is in `grp_res_addr_r` and `grp_res_data_r` of the group
| c+3 | Step 3: the job module has seen the acknowledge, and the result is removed (`res_valid_i(i)` is low, and `res_busy_r(i)` is high). The address of the column and the row in the picture are in `acc_col_dd` and `acc_row_dd`
| c+4 | Step 4: `wr_en_o` is high, with the address and the counts. The display memory writes them two clock cycles later (three on the Nexys 4 DDR)

The waveform shows a result of job module 12 (in group 2), in the same
simulation, where it is selected as early as possible (c = r+4). Many job
modules have a result at the same time, so the steps of the other results
(light grey) overlap with those of this one:

![Timing of a result](doc/timing_result.png)

The waveforms are generated from [`doc/timing_job.tex`](doc/timing_job.tex)
and [`doc/timing_result.tex`](doc/timing_result.tex) with `make diagrams`,
and the values are read off the simulation (the clock cycles are given in
the files).

So:
* The ready flag of job module i is low from c+2 until its next result,
  as `res_scheduler` requires (`dispatcher_results.psl` proves this).
* The counter of `res_scheduler` visits each group at most once every five
  clock cycles (`C_PERIOD`, at least five positions). So the next job
  module of the group is selected in c+5 at the earliest, from the ready
  flags of c+2, and job module i is not selected twice for the same result.
* Each acknowledged result is written exactly once, two clock cycles after
  the acknowledge (`dispatcher_results.psl` proves this too).
* The ready flag of the next result of the job module is high 4n+k+10 clock
  cycles after the selection, where n is the largest number of iterations
  of the four rows, and k the last of the rows with n iterations (see
  [Timing](#timing)).

## The top level
The design for the MEGA65 ([`src/mega65.vhd`](src/mega65.vhd)), which is the
same for both board revisions (see [MEGA65](#mega65)), instantiates the
clock and reset generation ([`src/clk_rst.vhd`](src/clk_rst.vhd)) and
[`src/core.vhd`](src/core.vhd), which holds what is the same on all the
boards: the display memory, and one module for each clock domain:
* [`src/main/main.vhd`](src/main/main.vhd) runs in the MAIN clock domain
  (187.8 MHz, or 120 MHz on the Nexys 4 DDR). It handles the buttons and
  switches, controls the dispatcher, writes the results to the display
  memory, calculates the frame rate, and converts the view to text. On the
  MEGA65 the buttons and switches come from the joysticks and the keyboard
  (whose driver also runs in the MAIN clock domain), and on the Nexys 4 DDR
  `main` also shows the frame rate on the 7-segment display.
* [`src/vga/vga.vhd`](src/vga/vga.vhd) runs in the VGA clock domain (the pixel
  clock, 108 MHz for 1280x1024 on the MEGA65, and 25 MHz for 640x480 on the
  Nexys 4 DDR). It generates the pixel counters, reads the display memory, and
  generates the VGA output, with the view in the top left corner and the
  frame rate in the top right corner. On the MEGA65 the VGA output goes to
  the video DAC (for the VGA connector) and to the HDMI output, whose
  serialisers use a third clock, the TMDS clock (540 MHz, five times the
  pixel clock).

The top level of the Nexys 4 DDR ([`src/nexys4ddr.vhd`](src/nexys4ddr.vhd))
does the same, without the keyboard, the video DAC, and the HDMI output.

The two clock domains communicate through the display memory, which has a
write port in the MAIN clock domain and a read port in the VGA clock domain.
The only other signals between them are the frame rate, the view as text,
and a toggle signal, which tells the VGA clock domain that they have changed,
see [Overlay](#overlay).
The files used only in the MAIN clock domain are in [`src/main/`](src/main),
and the files used only in the VGA clock domain are in [`src/vga/`](src/vga).
The designs of the boards, the clock and reset generation, and the display
memory, which are in both clock domains, are in [`src/`](src).

**Reset.** The resets are generated in `clk_rst`, together with the clocks.
The design is held in reset while the reset button is pressed, and while the
MMCM is not locked (on the MEGA65 R3 the reset button is read from the MAX10,
see [`src/mega65_r3.vhd`](src/mega65_r3.vhd)). This signal is synchronized to each clock domain (the main
clock and the VGA clock), and the reset is then stretched to eight clock cycles
after it is released. Only the HDMI output of the MEGA65 (`vga_to_hdmi` and
the serialisers) uses the VGA reset. `vga` needs no reset: the pixel
counters start at their initial values and run freely, and the rest of `vga`
follows them, a few clock cycles later.
The display memory has no reset (see [Display memory](#display-memory)).

## Display memory
The display memory ([`src/disp_mem.vhd`](src/disp_mem.vhd)) has `G_NUM_BLOCKS`*4096 pixels of 9
bits: 1280*1024 (1,310,720) on the MEGA65, and 2^19 on the Nexys 4 DDR. The
address of a pixel is the picture column times `G_COL_STRIDE` plus the row
(see [Dispatcher](#dispatcher)), i.e. the picture column (11 bits) followed by
the row (10 bits) on the MEGA65, and the picture column (10 bits) followed
by the row (9 bits) on the Nexys 4 DDR. The 640x480 picture of the Nexys 4 DDR
only uses the first 327,680 pixels (80 of the 128 blocks). The dispatcher
delivers a 9-bit count for each pixel, and `main` writes all 9 bits. The `vga` module converts the count to the colour, in the format
RRRGGGBB, see [Colours](#colours).

Each entry of the memory (a word) holds `G_PIXELS` pixels, i.e. consecutive
rows of a picture column, with the first row in the lowest 9 bits. The write
port writes a whole word, at the address of its first pixel (whose lowest bits
must be zero), and the read port reads a single pixel. So the VGA side is the
same for any `G_PIXELS`. The memory is divided into `G_NUM_BLOCKS` blocks of
2^12 pixels (320 on the MEGA65, and 128 on the Nexys 4 DDR), one BRAM each,
selected by the top bits of the address. A 36 kbit BRAM holds 4096 entries of
9 bits, or 1024 entries of 36 bits (the ninth bit of each byte is the parity
bit), so the ninth bit needs no extra BRAMs, and the number of BRAMs is the
same for 1 and 4 pixels in each word. The blocks are in groups of 8 (40 groups
on the MEGA65, and 16 on the Nexys 4 DDR). The write address and data go to
the blocks through a tree of registers: first to a register in each group,
which on the MEGA65 drives the 8 BRAMs of the group directly. On the Nexys 4
DDR there is also a register for each block between them (the generic
`G_BLOCK_REGS`), which can be placed next to its BRAM. The MEGA65 leaves these
out, which saves about 15,000 registers, which the job modules need. A single
register for the address of all the BRAMs, which are spread over the whole
FPGA, made the routing too slow (with 128 BRAMs on the Nexys 4 DDR). Writes to
addresses beyond the last block are ignored. The write port has two clock
cycles of latency (three on the Nexys 4 DDR), and the read port four: the read
address goes to a register in each group, which drives the 8 BRAMs of the
group, then the BRAMs are read, then each group selects the block in the group
(the BRAM itself selects the pixel in the word, see below), and then the pixel
is selected from the groups. `vga` gives `disp` and `overlay` the pixel counters delayed
by one clock cycle (`C_DISP_MEM_LATENCY` less `C_DISP_LATENCY`, in
`video_pkg`), so they see three clock cycles. Only the BRAM that holds the
pixel is read: its read enable is high, and those of all the other BRAMs
are low. Reading all the BRAMs in every clock cycle used most of the power
while the job modules were idle (see [Power](#power) and
[HISTORY.md](HISTORY.md#the-display-memory)). The number of the block of the
read address goes to a register in each group, like the address of the pixel
in the block, and the read enable of each BRAM is decoded from the register of
its group. So the decoder is on the short paths from the register of a group
to its 8 BRAMs, and not on the long paths from the pixel counters to the
registers of all the groups, which are the worst paths of the VGA clock (see
[MEGA65](#mega65)). In the next clock cycle each group takes the block in the
group from the same register, instead of from the read address.

The BRAMs have asymmetric ports: written `9*G_PIXELS` bits wide and read 9 bits
wide (the address of the read port has `log2(G_PIXELS)` more bits). Vivado
infers this from the asymmetric RAM template in UG901 (a shared variable in
VHDL), so the BRAM selects the pixel in the word, and only the selection of
the block in the group remains. Each block is a separate entity
([`src/disp_blk.vhd`](src/disp_blk.vhd)): when the shared variable was
declared in a generate statement in `disp_mem`, Vivado did not infer a BRAM,
but built the memory from registers (and the build did not finish). The
simulation model of the template is checked in GHDL by `disp_mem_tb`.

The display memory has no reset. The BRAMs are cleared when the FPGA is
configured (the count 0, black in all palettes), and a reset keeps their
contents, so the previous picture stays on the screen until the first picture
after the reset has overwritten it. The first picture overwrites every pixel
of the picture anyway.

The display memory has a small self-checking testbench
([`sim/disp_mem_tb.vhd`](sim/disp_mem_tb.vhd)). It writes to a few words
in each block, back-to-back both in different blocks and in the same block,
and reads all their pixels back on the read port. It checks that each value is
written to the right block and address, and is in the right position in the
word, that a second write overwrites the first, that nothing is written when
the write enable is low, and that the read latency is exactly four clock
cycles. In every clock cycle of the read port it checks that only the BRAM of
the read address is enabled, with an external name for the read enables
inside the memory. It does this for 1 and 4 pixels in each word with 128
blocks, and for 4 pixels with 320 blocks, 21 bits of address, and no
registers for the blocks, where it also checks that writes beyond the last
block are ignored, and that a read beyond the last block enables no BRAM.
It also checks that a word that is never written reads as 0 in every block.

## Redraw
This and the next two sections describe `main`: when it calculates a
picture, the control of the view, and the frame rate.

A new picture is only started when the view has changed since the previous
picture was started, and after reset. The view is updated 18 times per second,
also when no button is held down (see [View control](#view-control)), so
`main` keeps a copy of the view of the latest picture (`pic_startx`,
`pic_starty`, `pic_stepx`, and `pic_stepy`), which it takes when the
dispatcher takes the view, i.e. when start is high. The view is compared with
this copy, and the result of the comparison (72 bits) is registered
(`view_new`). When the signal done\_o from the dispatcher goes high, the
signal active is cleared, and when `view_new` is set, active is set again
together with a pulse on start. The dispatcher clears done\_o when it sees the
start, so done\_o is ignored while start is high. If the view changes during a
picture, a new picture is started as soon as that one is finished, and several
changes during a picture give only one new picture. The first picture is
started at once after reset.

The job modules
are idle while the view does not change, and the iterators do not toggle
then (see [Iterator](#iterator)). While a button is held down, at most 18
pictures per second are calculated, so the job modules are busy about 10% of
the time for the initial view (18 times 5.88 ms) on the MEGA65, and 13% (18
times 7.08 ms) on the Nexys 4 DDR. See [Power](#power) for Vivado's estimate
of the power.

The testbench [`sim/redraw_tb.vhd`](sim/redraw_tb.vhd) is self-checking. It
runs `main` and the display memory with a small picture (16x12, five job
modules, and the maximum count 127), a small display memory (8 blocks), and a short time between the
updates of the view (4000 clock cycles, longer than a picture), and holds the
buttons down for one update at a time: no buttons, pan right, zoom in, zoom
out, and pan left until the left edge of the view is at -2. It checks that
each picture is started with a view that differs from the view of the previous
picture, that at each update the latest picture is finished and has the
current view (i.e. every change of the view gave a picture), that nothing is
written between the pictures, and that the frame rate is updated once for each
picture. It also reads the display memory after the first picture and after
the last one: every pixel must be the value written by `main`. A second
instance of `main` updates the view every 400 clock cycles, i.e. several
times during a picture. The testbench holds pan right down for three updates
during the first picture, and checks that this gives exactly one more
picture, with the view after the last change, and that it is started as soon
as the first picture is finished (3 clock cycles after its last word is
written). The update pulse, the start, and the view are inside `main`, so the
testbench reads them with external names (VHDL-2008).

## View control
The view is given by the position of the top left corner of the
picture (startx, starty), and the size of a pixel (stepx, stepy). The initial
view has the real axis from -1.6667 to 1.0, and the imaginary axis is
centred on 0, with the same aspect ratio as the picture, so the pixels are
square: from -1.0667 to 1.0667 for 1280x1024 (5:4), and from -1.0 to 1.0 for
640x480 (4:3) on the Nexys 4 DDR. The pixel size is the size of the view
divided by the number of columns and rows, rounded down. The size of the real
axis is given as 8/3 exactly (`main.vhd`), so that the sizes of a pixel in the
two directions are equal (with 2.6667, they were 273 in both directions with
the earlier 2.16 numbers at 640x480, but differed by 447 LSB with 2.33).

The view is controlled by the module
[`src/main/viewport.vhd`](src/main/viewport.vhd), which holds the state
machine and instantiates
[`src/main/viewport_axis.vhd`](src/main/viewport_axis.vhd) twice, for x and
for y. The two axes are always in the same step of the update, and the only
thing they share is the decision to zoom, which needs the new size of a pixel
to be in range in both. The view is updated at a fixed rate, 18 times per
second (every 56 ms), which is given by a counter in `main.vhd` that counts
`G_CLK_FREQ`/18 clock cycles. At each update, the following happens, depending on the buttons that are held
down. The buttons are named as on the Nexys 4 DDR; on the MEGA65 they come
from the joysticks and the keyboard (see
[`src/main/controls.vhd`](src/main/controls.vhd)): `BTNC` is the
fire buttons and the `+` and `-` keys, and switch 2 is the fire button of
port 2 and the `-` key, and `BTNL`, `BTNR`, `BTNU`, and `BTND` are the
directions of port 1 and the cursor keys.
* `BTNC`: Zoom. The values of stepx and stepy are both decreased by 1/64 of
  their value plus one least significant bit (zoom in), or increased by the same
  (zoom out, if switch 2 is on). This is about 1.6% per update. The zoom keeps
  the centre of the picture fixed: startx is moved by the change of stepx
  times 640 (half the number of columns), and starty by the change of stepy
  times 512, so the pixel in column 640 and row 512 (just right of and below
  the centre of the screen) shows the same point before and after the zoom
  (except at the edge of the range, see below). On the Nexys 4 DDR these are
  320 and 240.
* `BTNL`, `BTNR`: startx is decreased or increased by stepx times the pan
  step (`BTNR` has priority if both are held down). The pan step is 1/320 of
  the number of columns, i.e. 4 pixels (2 on the Nexys 4 DDR), so panning
  takes the same time on both boards.
* `BTNU`, `BTND`: starty is decreased or increased by stepy times the pan step
  (`BTND` has priority if both are held down).

The view is always kept inside the range of the number format, i.e. -2 to
2 (not including 2). Otherwise the values of cx and cy, which the dispatcher and
the job modules calculate by adding stepx and stepy, would wrap around, and
the picture would show parts of the range twice (e.g. a second copy of the set
at the right edge). Similarly, the size of a pixel must not become zero or
negative. So:
* Panning stops when the first column (row) is at -2, or when the last column
  (row) is at 2 minus one LSB.
* Zooming in stops when the size of a pixel is one LSB, i.e. 2^-33, where the
  picture is then 1.5\*10^-7 wide (7.5\*10^-8 on the Nexys 4 DDR). In
  practice the picture is limited by the precision of the calculation before
  this. At about 1.6% per update, it takes about 59 seconds to zoom in from
  the initial view to there, against 17 seconds with the earlier 2.16
  numbers.
* When zooming out would move the first column (row) to before -2, or the
  last column (row) beyond the range, the view is moved right (down) or left
  (up) instead, so that edge stays at the end of the range. Zooming out stops
  when the view can not get any larger, i.e. when it covers almost the whole
  range from -2 to 2 in x.

The check that the zoomed view fits is a comparison of the new size of a pixel
with a constant, the largest size for which the view fits. The position of the
right (bottom) edge needs the size of a pixel multiplied by the number of
columns (rows) minus one, and keeping the centre fixed needs the change of the
size multiplied by 640 (512), and the pan step needs the size of a pixel
multiplied by 4 (2 on the Nexys 4 DDR). These multiplications are done serially with
shifts and additions or subtractions, one bit of the constant per clock cycle,
so no DSP is used. Doing all of the update in a single clock cycle would be far
too slow for the MAIN clock, so the update is done in small steps over 18 clock
cycles (17 on the Nexys 4 DDR, where 639 has only 10 bits, against 11 bits
for 1279), with at most one addition or comparison per step. The outputs are all
changed at the end of the update. The new view is used when the next picture is
started. Some of the constants (e.g. the largest position, 2^35-1, and the
largest size of a pixel for a small picture) do not fit in a VHDL integer, so
they are calculated as real numbers, which are exact for integers up to
2^53, and converted to vectors.

The buttons and switches are asynchronous to the MAIN clock (on the MEGA65 the
joystick lines, combined with the keys), so `main` synchronizes them with two
registers (with the attribute `async_reg`), like the reset in `clk_rst` and the
palette switches in `vga`. On the Nexys 4 DDR, the switches 0 and 1 select the
colour palette, see [Colours](#colours). They are used in the VGA clock domain
(in `vga`), not in `main`. So is switch 3, which moves the palette. The
switches 4 to 7 are not used. On the MEGA65 the switches 0 and 1 are the
palette selected with the keys `1` to `4`, switch 3 is the movement of the
palette (see [Colours](#colours)) toggled with the space bar, and the switches
4 to 7 are always off.

The view control has a self-checking testbench
([`sim/viewport_tb.vhd`](sim/viewport_tb.vhd)). It holds the buttons down for many
updates, and checks after every update that the view is inside the range, that
the size of a pixel is at least one LSB, that the view is the one expected
from a simple model, and that the outputs all change in the same clock cycle.
It also checks the initial view, that panning and zooming reach the ends of
the range and stop there, that zooming in keeps the centre exactly fixed, and
that a pulse on upd\_i during an update is ignored, but one just after the
update is not. It does this for both boards, with an instance each: 640x480
(a pan step of 2 pixels, and an update of 17 clock cycles) and 1280x1024 (a
pan step of 4 pixels, and an update of 18 clock cycles), with the initial
view of `main`. The values of the model are real
numbers, because the 2.33 values do not fit in an integer. The initial view
is also checked when the design is elaborated: it must be inside the range
too.

**The joysticks and the keyboard.** On the MEGA65,
[`src/main/controls.vhd`](src/main/controls.vhd) maps the joysticks and the
keyboard to the buttons and switches above, in the MAIN clock domain. The
keyboard driver (`m2m_keyb`, in `src/keyboard/`) cycles through the 80 keys,
once every 1.11 ms (1968 clock cycles for each key), and shows whether each
one is pressed. The keys that
are used are stored in a register each, which is updated once in each cycle
through the keys. The keys `1` to `4` select the palettes 1 to 4, and the
palette is stored in a register (palette 3, fire, after power-on), so it stays
selected when the key is released. The palette is only changed at the end of
a cycle through the keys (key 79), when all the keys have been read, so it
changes only once when one key is pressed while another one is released. If
several of the keys are held down, the lowest one wins. The space bar toggles
a register (off after power-on), the movement of the palette. It is also
changed at the end of a cycle through the keys, and only when the key was not
pressed in the previous cycle, so it toggles once for each press, however long
the key is held down. The joysticks are not
registered in `controls`, only in `main` (and in `vga` for the palette and the
movement).

The keyboard is ignored for the first 256 cycles through the keys after
power-on (0.28 s), i.e. no key is pressed. The keyboard driver sends a
clock to the keyboard, and reads one bit for each clock cycle. Every 141
clock cycles (0.45 ms) it sends a sync pulse, after which the keyboard starts
again with the first bit. Until the first sync pulse after the FPGA is loaded,
the bits are not aligned with the key numbers, and keys that are not pressed
seem pressed. If they were not ignored, they would select a random palette,
and start the movement at random, each time the FPGA is loaded.

The testbench [`sim/controls_tb.vhd`](sim/controls_tb.vhd) is self-checking.
It cycles through the keys like the keyboard driver, and checks the buttons
and switches in every clock cycle of a whole cycle through the keys: while
random keys are pressed in the cycles that are ignored after power-on (4 in
the testbench), after that with no key pressed, for each of the 80 keys on
its own, for each combination of the
keys `1` to `4`, for all 64 combinations of the joystick inputs, and for 300
random combinations of keys and joystick inputs. The palette must stay
selected when its key is released, and the space bar must toggle the movement
once for each press.

## Frame rate
The top right corner of the VGA output (and the
7-segment display of the Nexys 4 DDR) shows the frame rate, i.e. the
number of pictures per second, rounded down to an integer, with the leading
zeros blanked. A counter counts clock cycles while a picture is being
calculated, and it is cleared when the next picture is started. At the end of
a picture, the module [`src/main/fps.vhd`](src/main/fps.vhd) divides the
clock frequency (the generic `G_CLK_FREQ` of `main`, set by the design:
187,826,087 Hz on the MEGA65, or 120,000,000 Hz on the Nexys 4 DDR) by the
value of the counter, and converts the result to decimal. So the frame rate is
the number of pictures per second if the picture was recalculated
continuously.
The frame rate is that of the latest picture, i.e. the picture on the screen.
Pictures are only calculated when the view changes (at most 18 times per
second), so the frame rate does not change while the view does not change.
The module used to be able to average the time over several pictures, but
that was never used (see [HISTORY.md](HISTORY.md#the-frame-rate)).
A single-cycle division would be far too slow for the MAIN clock, so both
steps are done one bit per clock cycle: a restoring division, with one
subtraction for each of the 28 bits of the quotient (27 on the Nexys 4 DDR),
and then the double dabble algorithm to convert the quotient to 8 decimal digits
(for each bit, 3 is added to each digit which is 5 or more, and then
everything is shifted left by one bit). Together this takes 58 clock cycles
(56 on the Nexys 4 DDR), much less than a picture, and the widest addition is
29 bits. A frame rate above 99999999 would show as 99999999, but that would need a picture of fewer than 2 clock cycles. The
counter is 27 bits wide, so it wraps around after 2^27 clock cycles (0.71 s
at 187.8 MHz), but a picture takes far less than that: even if every pixel
needed the maximum count (1023), the model (see [Timing](#timing)) gives about
11.2 million clock cycles (60 ms, i.e. 17 pictures per second) for the
picture.

On the Nexys 4 DDR the frame rate is also shown on the 7-segment display. Its
digits share the segment signals, so
[`src/main/seg.vhd`](src/main/seg.vhd) shows them one at a time, each for 2^14 clock
cycles, i.e. all 8 digits are refreshed every 1.09 ms (0.92 kHz) at 120 MHz. The
segments and the digit enables (anodes) are active low. The decimal point is
not used. The MEGA65 has no 7-segment display, so the outputs of `seg` are
not connected there.

The testbench [`sim/fps_tb.vhd`](sim/fps_tb.vhd) is self-checking. It gives
the frame rate module a number of picture times (the extremes, the values
around a change of the frame rate, e.g. 199 and 200, and random values), and
checks the digits and the blanking against the integer division, and that the
display shows the same number: every digit that is not blanked is switched on
with the right segments during a refresh cycle, the blanked digits are never
switched on, and at most one digit is on at a time. It also checks that a new
picture time during a calculation does not start a new calculation. It does
this with two instances of the module, one with the clock frequency of each
board: 180,000,000 Hz (a quotient of 28 bits, like the 187,826,087 Hz of the
MEGA65 now) and 120,000,000 Hz (27 bits).

## Overlay
The frame rate is shown in the top right corner of the VGA output by
[`src/vga/overlay.vhd`](src/vga/overlay.vhd), in white on black, with the
leading zeros not shown (the picture is shown there instead). The overlay
shows a line of text at the top of the picture, 8 pixels from the top, the
left, and the right edge: 79 characters for 1280 pixels (39 for 640 on the
Nexys 4 DDR), with the view (see *The view as text* below) in the first 25
characters, and the frame rate in the last 8. The characters in between are
not shown. A character is 4 bits: the digits, and `.`, `-`, `+`, `i`, and
`x` (see [`src/text_pkg.vhd`](src/text_pkg.vhd)), and the code 15, which is
not shown, e.g. for the blanked digits of the frame rate. The characters are
16x32 pixels, from the [Spleen](https://github.com/fcambus/spleen) font
(BSD 2-Clause license, see [`font/LICENSE.spleen`](font/LICENSE.spleen)). The
script [`font/gen_font_pkg.py`](font/gen_font_pkg.py) converts the font to the
table in [`src/vga/font_pkg.vhd`](src/vga/font_pkg.vhd), 32 rows of 16 bits
for each character. The frame rate (32 bits of digits and 8 bits of
blanking) and the view (100 bits of text) are calculated in the MAIN clock
domain, so they are moved to the VGA clock domain by
[`src/cdc_data.vhd`](src/cdc_data.vhd), in the design of the board
([`src/core.vhd`](src/core.vhd)), so `main` does not depend on the
VGA clock. `cdc_data` is a generic clock domain crossing for a value that
changes seldom (the ports of the source clock domain start with `s_`, and
those of the destination with `m_`), and the design gives it the frame rate
and the view as one value of 140 bits. `main` sets `fps_valid_o` for one
clock cycle each time the frame rate and the view change, and `cdc_data`
then changes a toggle signal (`p_toggle`). This is synchronized with two
registers (`p_cdc`), and when it changes, the frame rate and the view are
copied, so `overlay` only gets signals in the VGA clock domain. Until the
first frame rate, the output is the initial value (`G_INIT`), with all the
characters not shown. The frame rate and the view change only at the end of
a picture, so they are constant for much longer than the synchronizer takes
(a few VGA clock cycles), and they are never copied while they change. The
constraint in [`mega65.xdc`](mega65.xdc) and
[`nexys4ddr.xdc`](nexys4ddr.xdc) (`set_max_delay -datapath_only`) makes
sure that it arrives before the toggle signal, and excludes these paths from
the normal timing between the two clocks. The new
value is shown from the next frame on, so a frame never shows two values.
The overlay is a pipeline of five stages after the pixel counters: the position
in the overlay, the character, the row of the font, the pixel of the row, and
then the colour, which replaces the output of `disp`. This adds one clock
cycle of latency to all the VGA outputs. Before the view was shown, the
overlay only had the 8 digits of the frame rate.

The testbench [`sim/cdc_data_tb.vhd`](sim/cdc_data_tb.vhd) gives `cdc_data`
a new value of 40 bits after a random time (at least ten destination clock
cycles), and checks in every destination clock cycle that the output is the
initial value before the first value, that it is always either the latest
value or the one before it (never a mix of the two, and never back to the
one before), and that the latest one arrives at most one source clock cycle
and four destination clock cycles after it was sent. It does this with the
clocks of both boards (180 MHz and 108 MHz, and 120 MHz and 25 MHz).

The testbench [`sim/overlay_tb.vhd`](sim/overlay_tb.vhd) checks the colour of
every pixel of three frames of the VGA output (with a different value for each
pixel), with no view and no frame rate (the initial value), then a view and
a frame rate of 4 digits, and then a view with all the characters and a
frame rate of 8 digits. The view and the frame rate are changed in the
middle of the overlay, and the new value must only be shown in the next
frame. It prints the overlay of the last frame.

**The view as text.** The top left corner of the VGA output shows the view
of the picture: the centre as a complex number, and the zoom, e.g.
`-0.33858-0.00418i   1.00x` for the initial view of the MEGA65. The module
[`src/main/view_text.vhd`](src/main/view_text.vhd) converts the view to this
text (25 characters) when a picture is started, with the view that the
dispatcher takes. `main` keeps the text until the frame rate of the picture
is ready (`fps_valid_o`), and then outputs it together with the frame rate,
so the screen always shows the view and the frame rate of the same picture,
the latest one.

`view_text` only handles 2.16 numbers, so `main` gives it the view
truncated to 2.16 (the top 18 bits of startx, starty, stepx, and stepy),
with the size of a pixel at least one LSB of 2.16. The text is then only
approximate: the centre is calculated with the truncated size of a pixel, so
it is off by up to 640 LSBs of 2.16 (about 0.01, and 320 LSBs or about 0.005
on the Nexys 4 DDR). E.g. the centre
of the initial view is -0.33337-0.00000i, but it is shown as
-0.33858-0.00418i. The zoom stops at 136.00 (a pixel of one LSB of 2.16;
273.00 on the Nexys 4 DDR), although the view can be zoomed in 2^17 times further. The values below are
those of the truncated view.
* The centre is the point of the pixel in column 640 and row 512 (320 and
  240 on the Nexys 4 DDR), the one that is kept fixed when zooming (see *The
  view* above), i.e. startx + 640 * stepx and starty + 512 * stepy. The real
  and the imaginary part are each shown with a sign, one digit before the
  point, and five after it, rounded to the nearest (one LSB of the 2.16
  format is 0.000015). The rows go down the screen, so the imaginary part
  increases downwards.
* The zoom is the initial size of a pixel (136 LSBs, or 273 on the Nexys 4
  DDR) divided by stepx, with two digits after the point, rounded to the
  nearest, and the leading zeros not shown. It is 1.00 for the initial view,
  from 0.67 when zoomed out as far as possible to 136.00 (273.00) when
  zoomed in as far as possible. The size of a pixel is an integer number of
  LSBs, so the zoom has only a few possible values when zoomed in far, e.g.
  136.00 and 68.00 for a pixel of 1 and 2 LSBs. A zoom above 999.99 is
  shown as 999.99, but that only happens for a picture of fewer than 175
  columns.

Like the frame rate, the conversion is done one bit per clock cycle, with at
most one addition or subtraction of 30 bits per clock cycle: the
multiplication by the constant column (row) of the centre with shifts and
additions, then the magnitude of the centre times 100000/2^16 (i.e. times
3125 and divided by 2^11, with 2^10 added for the rounding), also with shifts
and additions, the zoom times 100 with a restoring division (with half of
stepx added to the dividend, for the rounding), and each value to decimal
with the double dabble algorithm. The conversion takes 130 clock cycles on
the MEGA65 (0.72 us), much less than a picture.

The testbench [`sim/view_text_tb.vhd`](sim/view_text_tb.vhd) is
self-checking. It has three instances of `view_text`, with the size of the
picture and the initial size of a pixel of the MEGA65, of the Nexys 4 DDR,
and of `redraw_tb` (16x12, where the zoom is always above 999.99, the
largest value shown), and gives them the initial views, views at the edges of the range (the
centre as far left and right as possible, with the smallest and the largest
pixel, at 0 and one LSB from it, and with the largest fraction), and 2000
random views inside the range. It checks the text of each against a model
that calculates the centre and the zoom with integers, and prints the text
of the first views. It also checks that nothing is shown before the first
conversion, that the text only changes with a pulse of one clock cycle on
`valid_o`, and that a start during a conversion is ignored.

## Colours
The display memory holds the count of each pixel (9 bits). The VGA output has
8 bits of colour, in the format RRRGGGBB (3 bits red, 3 bits green, and 2 bits
blue). On the MEGA65 each colour is expanded to 8 bits for the video DAC and
the HDMI output, by repeating its bits (e.g. 111 becomes 11111111), so the
full range is used. The points in the set (the value 511) get the colour of the set. For the
other counts, the value (all 9 bits, except in palette 1) is converted to the
colour by one of four palettes in [`src/vga/palette_pkg.vhd`](src/vga/palette_pkg.vhd).
The maximum count is 1023, so the count has 10 bits, and the job module
writes 511 for the points in the set, and the count modulo 511 for the other
points (see [Jobs](#jobs)), so the colours of the counts 0 to 510 repeat for
the larger counts.
On the MEGA65 the palette is selected with the keys `1` to `4` (see
"The joysticks and the keyboard" in [The top level](#the-top-level)), and on
the Nexys 4 DDR by switches 0 and 1 (switch 1 is the high bit, both off is palette 1):
* 1: The lower 8 bits of the count (the value) are the colour. Most of the pixels outside the set have
  small counts (in the initial view, 92.5% of the pixels outside the set have
  a count below 16),
  so only the blue and green bits are set, and red needs a count of at least
  32. The set is white (the same colour as the value 255).
* 2: Rainbow. The hue goes once around the colour circle (red, yellow, green,
  cyan, blue, magenta) for every 16 counts.
* 3: Fire (the palette after power-on on the MEGA65). Black, red, orange, yellow, and white, with the square root of the
  count, once for the counts 0 to 63, again for 64 to 255, and again for 256 to 510.
* 4: Blue, white, orange, and dark brown, with the logarithm of the count, once
  for the counts 0 to 6, again for 7 to 62, and again for 63 to 510.

In the palettes 2 to 4 the set is black. The display memory stores all 9 bits
of the count, which costs no extra BRAMs (see [Display
memory](#display-memory)), so the points with the count 255 are not shown in
the colour of the set.

The palettes are tables of 512 entries, which are calculated from the formulas
above (with `ieee.math_real`) when the design is elaborated, so they are easy
to change. The colour of each entry is rounded to the nearest of the 8 (or 4)
levels of each colour component. The tables are implemented in LUTs, and the
lookup is done in the output register of `disp`, so it adds no delay.

**Moving the palette.** While the movement is on (the space bar toggles it on
the MEGA65, and switch 3 turns it on on the Nexys 4 DDR), `disp` offsets the
palette by a value that is incremented once for every 6 frames (10 times per
second), modulo 511, the number of counts outside the set. The colour of the
count `c` is then the colour of the count `c - offset` (modulo 511), so each
colour moves to higher counts, i.e. towards the set, and the whole picture
seems to be moving. The set keeps its colour. The offset is a register in
`disp`, which is changed at the start of the vertical sync pulse, so it is the
same for the whole picture. When the movement is turned off, the offset stays
where it is, and it is 0 after power-on. The pictures do not change in any
other way, so the dispatcher and the display memory are not involved, and the
movement does not recalculate anything. The offset is subtracted before the
table lookup, in the same clock cycle. On the MEGA65 the path from the display
memory through the subtraction and the table to the colour register is close
to the worst path of the VGA clock: it took 8.09 ns (+0.977 ns of slack at
108 MHz) in the first build with the movement, 8.94 ns (+0.176 ns) in a later
one, and 8.19 ns (+0.916 ns) in the current one, see [MEGA65](#mega65). If it fails timing, the subtraction can be
moved to the clock cycle before, with a register for the index.

The switches (on the MEGA65 the palette register in the MAIN clock domain)
are asynchronous to the VGA clock, so they are synchronized with two
registers in `vga`. This includes the switch that moves the palette.

The testbench [`sim/disp_tb.vhd`](sim/disp_tb.vhd) checks `disp` with a very
small video mode (so it can simulate 2200 frames in a second): the colour of
every pixel in all four palettes, calculated from the tables, with the offset
of the moving palette (stepping every second frame, wrapping from 510 to 0
more than twice, and standing still while the movement is turned off).

The testbench for the VGA output ([`sim/vga_tb.vhd`](sim/vga_tb.vhd)) checks
the timing and the polarity of the sync signals, and then the colour of every
pixel of a frame, with a different value for each pixel, and a different
palette for every 120 lines. This also checks the address of each pixel. It
does this for both video modes, each with the address layout of its board,
and for 640x480 with 480 addresses for each picture column (not a power of
two).

**Video modes.** The resolution and the timing of the VGA output are given by
a video mode, which is a record in
[`src/vga/video_pkg.vhd`](src/vga/video_pkg.vhd): the number of visible
pixels, the front porch, the sync pulse, and the back porch, for each line and
for each frame, and the polarity of the sync pulses, from the VESA standard.
There are two: 1280x1024 at 60 Hz (pixel clock 108 MHz, 1688 pixels in each
line, 1066 lines, and positive sync pulses), used on the MEGA65, and 640x480
at 60 Hz (pixel clock 25.175 MHz, which works fine with 25 MHz, and negative
sync pulses), used on the Nexys 4 DDR. The design of the board gives the
video mode to `vga` and the size of the picture to `main`, and sets the VCO
and the divider of the VGA clock in `clk_rst` (1080 MHz divided by 10, or
1200 MHz divided by 48).
The pixel counters have 11 bits, for up to 2048 pixels in a line. `vga` calculates the address of the pixel from
the pixel counters (the column times `G_COL_STRIDE` plus the row, in LUTs),
which is only wires on both boards (`G_COL_STRIDE` is 1024 or 512).

## Timing
A counter measures the time it takes to generate the picture, which is shown
as a frame rate on the VGA output (and on the 7-segment display of the
Nexys 4 DDR), see [Frame rate](#frame-rate).

The time for a picture is estimated by the model
[`sim/model.py`](sim/model.py), which simulates the dispatcher one clock
cycle at a time (`picture_cycles()`), with both schedulers. The iterator
calculates the four rows of a result at the same time, one iteration of each
in every four clock cycles (see [Iterator](#iterator)). So in the model a
result takes 4n+k+10 clock cycles, from the selection of the previous result
until its ready flag is high, where n is the largest number of iterations
done by its four rows when they stop (the count for a pixel that escapes,
1022 for a pixel that reaches the maximum count, and the iteration of the
match for a pixel where a cycle is found), and k the slot of the last row
with n iterations (0 to 3). The scheduler for the results selects a job
module three clock cycles after its ready flag is high.

**Several pixels in each write.** The display memory takes one result in
each clock cycle, so with one pixel in each write the time for the picture
would mostly be decided by its write port. The BRAMs can be written in words
of 36 bits instead of 9, i.e. four pixels, with the same number of BRAMs
(see [Display memory](#display-memory)). So each result is four consecutive
rows of a picture column (the generic `G_PIXELS`), which the iterator
calculates at the same time, and the dispatcher writes up to four pixels per
clock cycle. What this gave, and what else was considered, is in
[HISTORY.md](HISTORY.md#several-pixels-in-each-write).

For the initial view (with the maximum count 1023) the model gives:

| | MEGA65 (1280x1024) | Nexys 4 DDR (640x480)
| --- | --- | ---
| Job modules, main clock | 120 (720 DSPs), 187.8 MHz | 39 (234 DSPs), 120 MHz
| Clock cycles for the picture | 1103544 (5.88 ms, 170 pictures per second) | 849122 (7.08 ms, 141 pictures per second)
| Limit of the display memory (four pixels in each write) | 327680 | 76800
| Every pixel needs the maximum count (1023) | about 11.2 million (60 ms, 17 pictures per second) | about 8.08 million (67 ms, 15 pictures per second)
| Seahorse Valley (0.08 wide, centred near -0.75+0.15i) | 4466723 (23.8 ms, 42 pictures per second) |
| With the earlier 2.16 iterator and the maximum count 511 | 357998 (2.53 ms, 396 pictures per second, 368 job modules at 141.64 MHz) | 143751 (1.20 ms, 835 pictures per second, 120 job modules)

On the MEGA65 the initial view is 2.3 times slower than with the 2.16
iterator: the wide iterator needs three times as many DSPs (so there are
three times fewer iterators), the periodicity detection needs twice as many
iterations for the points in the set (see
[Periodicity detection](#periodicity-detection)), and the maximum count is
1023, partly made up by the faster main clock. On the Nexys 4 DDR, where the
main clock is the same, it is 5.9 times slower. The job modules wait 7.1
clock cycles per pixel on average for their results to be accepted on the
MEGA65, and 2.6 on the Nexys 4 DDR. Jobs of 16 to 240 rows give 141 to 142
pictures per second on the Nexys 4 DDR.

A simulation of a complete picture of 160x128 pixels with `main_tb` and the
design of the MEGA65 (120 job modules, jobs of 64 rows) wrote the last pixel
41043 clock cycles after the reset, and the model gives 41208 clock cycles
(0.4% more), with all the pixels the same as in the model. The simulation
took 27 minutes. It was made before the clock enables of the iterator (see
[Iterator](#iterator)) and before `main` only calculated a picture when the
view changes (see [Redraw](#redraw)).

The frame rates of the wide iterator have not been measured on the boards
yet. With the 2.16 iterator the measured frame rates agreed with the model
within 0.3%, see [HISTORY.md](HISTORY.md#timing-of-the-216-iterator). The
frame rate changes slightly from picture to picture, because the counter of
the scheduler for the jobs runs freely, so each picture starts at a
different position of it, and the job modules get their first jobs in a
different order.

## Resources and timing closure
Both boards are built with Vivado 2025.1, with the same script
(`mandelbrot.tcl`). The directives used in it matter for meeting timing:
* `synth_design` with `-directive AreaOptimized_medium`
* a relatively placed macro for the six DSPs of each iterator, which places
  them in a column (see [Iterator](#iterator))
* on the MEGA65, a floorplan of the job modules (`mega65_floorplan.tcl`),
  see [MEGA65](#mega65)
* `opt_design` with `-directive ExploreWithRemap`
* `place_design` with `-directive ExtraTimingOpt`
* `phys_opt_design` with `-directive AlternateFlowWithRetiming`, both after
  placement and after routing

The resource numbers below are from `report_utilization` on the routed design
(`build/<board>/<board>.dcp`), and the slack is from
`report_timing_summary` on the same design, i.e. after the post-route
`phys_opt_design`. The build script writes these reports to
`build/<board>/utilization.rpt` and `build/<board>/timing.rpt`, and the
power estimate (see [Power](#power), "busy") to `build/<board>/power.rpt`.
It only writes the bit-file when the setup and the hold slack are both
positive, so a run that fails timing (see the variation between runs
below) gives no bit-file that `make fpga` could load. The first two
subsections give the current results for each board, and the third gives
the power. How the design and the main clock got there, with the results of
the earlier builds, is in [HISTORY.md](HISTORY.md#builds-of-the-mega65).

On the MEGA65 the 120 iterators calculate two multiplications of 35-bit
numbers in every clock cycle, each with three DSPs, i.e. 45.1 billion such
multiplications per second at 187.8 MHz (720 DSPs). On the Nexys 4 DDR the 39
iterators give 9.4 billion at 120 MHz (234 DSPs). With the earlier 2.16
iterator, which used both of its DSPs in every clock cycle, the 736 DSPs of
the MEGA65 at 141.64 MHz gave 104 billion 18-bit multiplications per second,
and the 240 DSPs of the Nexys 4 DDR at 120 MHz 28.8 billion.

### MEGA65
The MEGA65 has an XC7A200T with speed grade -2 (part xc7a200tfbg484-2), on
both board revisions R3 and R6. The design is the same for both (see
[`src/mega65.vhd`](src/mega65.vhd)), but some of the pins are different, so
each revision has its own top level module
([`src/mega65_r3.vhd`](src/mega65_r3.vhd) and
[`src/mega65_r6.vhd`](src/mega65_r6.vhd)), constraint file with the pins
([`mega65-r3.xdc`](mega65-r3.xdc) and [`mega65-r6.xdc`](mega65-r6.xdc)),
and make target (`make mega65-r3` and `make mega65-r6`). The timing
constraints and the configuration of the bitstream are the same for both, in
[`mega65.xdc`](mega65.xdc), apart from those of the MAX10, which is only on
the R3. The R6 has an output for each
joystick line, which pulls the line low; the top level of the R6 drives them
all high, because an unused pin has a weak pull-down, and then the joystick
lines can be read as pressed. The R3 does not have these outputs, and uses
some of the pins for other things (e.g. the serial link to the MAX10, which
reads the reset button), so the bit-file of one revision must not be used on
the other one.

The VGA output is 1280x1024 at 60 Hz, with a 108 MHz pixel clock, and the
design uses 120 job modules (2.33 numbers and the maximum count 1023, see
[Iterator](#iterator)) and four pixels in each write to the display
memory, with a 187.8 MHz main clock (see *Video modes* in [Colours](#colours)).
The MMCM multiplies the 100 MHz input clock by 54/5, which gives a VCO of 1080 MHz, the only VCO frequency
that gives 108 MHz exactly (divided by 10); the main clock is the VCO divided
by 5.75. The display memory has 1280x1024 pixels in 320 BRAMs, with 21 bits
of address (the column followed by the row), and no registers for the write
port of each block (see [Display memory](#display-memory)). The jobs are 64
rows (1024 is not a multiple of the 120 rows of the Nexys 4 DDR). A run of
`make mega65-r6` gives:

| Resource         | Used     | Available | Used (%)
| ---------------- | -------- | --------- | --------
| DSP48E1          | 720      | 740       | 97
| Block RAM        | 320 RAMB36 + 2 RAMB18 | 365 RAMB36 | 88
| Slices           | 22,703   | 33,650    | 68
| LUTs             | 61,213   | 134,600   | 46
| Registers        | 71,503   | 269,200   | 27

| Check | Slack
| ----- | -----
| Setup (WNS) | +0.093 ns (TNS 0)
| Hold (WHS)  | +0.020 ns (THS 0)

The "Report Cell Usage" table in `build/mega65-r6/vivado.log` gives the cell
counts after synthesis instead: 81,588 LUT cells and 71,471 registers, and
12,623 shift registers (SRL16E, 105 in each iterator: the four entries of cy
and of the saved values of x and y). The number of LUT cells is larger than
the number of LUTs used, because two small LUT cells can share one LUT (the
placer does this, "LUT Combining"). Each job module (with its iterator) uses
459 or 460 LUTs (57 of them as shift registers) and 519 registers
(`report_utilization -hierarchical`). The runs before the rebase (see *The
main clock* below) and the count modulo 511 (see [Jobs](#jobs)) used about
2,800 fewer LUTs, and about 3,800 fewer LUT cells after synthesis.

The timing is met after the routing (+0.094 ns), before the post-route
`phys_opt_design`. The worst setup path of the main clock is from the
register of stepy of a group in the dispatcher (`grp_stepy_r` in
`dispatcher_jobs`) to the register of cy of a job module (`res_cy_r`),
mostly routing (3.99 ns of 5.37 ns). The next is in an iterator, from y to
the input B of a DSP, through the adder of x+y or x-y (4.55 ns, of which
2.11 ns is logic: a LUT and nine CARRY4). The worst path in the keyboard
driver (`m2m_keyb`, copied unchanged from the C64MEGA65 core, from the
counter of the keyboard scan, `keyscan_counter`, to the debounce RAM) has
+0.140 ns. The path that was the worst one at 180 MHz, from `grp_stepy_r` to
the accumulator of cy in an iterator (`cy_acc_r`), mostly routing (4.39 ns
of 5.60 ns at 180 MHz), now ends in a register of the iterator (`stepy_r`),
which is in each iterator, and the adder of cy has the register as its
input. The worst hold slack is +0.020 ns, on the VGA clock. On the main
clock it is +0.028 ns, in an iterator, from the register of cx (`cx_r`) to x
(`x_r`). The
VGA clock has +0.219 ns of setup slack: its worst path is from the row
counter (`pix_y` in `pix`) to the read address of one of the groups of the
display memory (`rd_grp_addr`, see [Display memory](#display-memory)), only
routing (8.40 ns of the 8.75 ns). The 118 paths from the MAIN clock to the
VGA clock (the frame rate, the view, and their toggle signal to `cdc_data`,
and the palette from `controls` to `vga`) have +7.62 ns of slack, and
`report_cdc` reports all of them as safe. The TMDS clock (540 MHz) has
+0.259 ns of pulse width slack, on its BUFG. The colour and sync outputs to
the video DAC are registered in the IOBs. The router leaves about 8,700
nodes with overlaps after the initial routing, and resolves them in a few
iterations. The runs of `make mega65-r3` and `make mega65-r6` at the same
time take about 11 minutes (for the R6: synthesis 3 minutes, placement
3.5 minutes, and routing 2 minutes).

A run of `make mega65-r3` gives almost the same: the design is the same,
except that the R3 reads the reset button from the MAX10 (with `max10`, in
the clock domain of the 100 MHz input clock, and with one more BUFG), and has
52 IOBs instead of 62. It uses 22,544 slices and 61,263 LUTs, and the timing
is met with +0.129 ns (the same after the routing), from `grp_cx_r` to
`res_cx_r` of a job module, only routing (4.75 ns of 5.10 ns), and
+0.007 ns of hold slack (in an iterator, from `stepy_r` to `cy_acc_r`). The
VGA clock has +0.202 ns of setup slack (from `pix_y` to `rd_grp_addr`), the
paths from the MAIN clock to the VGA clock +8.69 ns, and the input clock (in
`max10`) +4.93 ns.

**The main clock.** The first runs of the wide iterator were at 180 MHz. With
the register of stepy in each iterator (so that the long route from the
group registers of the dispatcher ends in a register next to the adder of
cy) the main clock was raised by changing the divider of the MMCM (steps of
0.125, on the R6): 5.875 (183.8 MHz) met timing with +0.123 ns, 5.75
(187.8 MHz) with +0.113 ns, 5.625 (192.0 MHz) with +0.089 ns, and 5.5
(196.4 MHz) with +0.014 ns, but 5.375 (200.9 MHz) failed with -0.080 ns and
5.25 (205.7 MHz) with -0.085 ns. These runs were made before the rebase
(see below). After the rebase, 192.0 MHz only met timing with +0.018 ns on
the R6 (in the keyboard driver) and +0.057 ns on the R3, and on both only
after the post-route `phys_opt_design`, so the main clock is one step lower,
187.8 MHz (5.75), which gives some margin (+0.093 ns on the R6 and +0.129 ns
on the R3, already after the routing). At 200.9 and 205.7 MHz the
failing paths are in the keyboard driver (`m2m_keyb`, from `keyscan_counter`
to the debounce RAM), which is copied unchanged from the C64MEGA65 core, and
which runs in the MAIN clock domain. With the keyboard on the 108 MHz VGA
clock instead (only to measure, the crossing to `controls` was not
made safe) the iterators met timing at 200.9 MHz with +0.030 ns, but not at
205.7 MHz (-0.085 ns), 210.8 MHz (-0.170 ns), and 216.0 MHz (-0.286 ns). Then
the failing paths are almost all from the first DSP of the cascade (the
register of its inputs) through its multiplier and the cascade to the
register P of the second DSP, i.e. inside the DSPs, so a faster clock needs
another register in the DSPs (see [TODO.md](TODO.md)). The maximum clock
frequency is therefore between 196.4 and 200.9 MHz for the design as it is,
and about 203 MHz for the iterators. Putting the carry chains of the adders of
x+y and x-y in the relatively placed macro of the iterator, next to the DSPs,
was tried: the macro with DSPs and slices needs the absolute grid of
`update_macro`, and the placer could not place the macros in the pblocks of
the floorplan ("Could not place shape in pblock"), so it is not used.

The previous runs, at 192.0 MHz, met timing with +0.018 ns on the R6
(22,670 slices, 61,226 LUTs) and +0.057 ns on the R3 (22,789 slices). The
runs at 192.0 MHz before those were made before the wide iterator was
rebased onto the design that is the same on all the boards in `core.vhd`,
the moving palette, the palettes with all 9 bits of the count, the BRAMs
that select the pixel in the word, and the keyboard ignored after power-on,
and before the count modulo 511 in the display memory. They met timing with
+0.089 ns on the R6 (22,743 slices, 58,443 LUTs) and +0.103 ns on the R3
(22,659 slices). The runs before those, at 180 MHz and without the register
of stepy in the iterator, met timing with +0.083 ns on the R6 (23,173
slices) and +0.089 ns on the R3. The details are in
[HISTORY.md](HISTORY.md#builds-of-the-mega65).

The design was first built without the explicit register M in the last DSPs
of the iterator, and Vivado left out a register (see
[Multiplier](#multiplier)), so the picture on the board was wrong.
Those builds met timing with +0.072 ns on the R6 (23,252 slices) and
+0.074 ns on the R3; the details are in
[HISTORY.md](HISTORY.md#builds-of-the-mega65).

The build of the original version of the wide iterator (before the clock
enables of the iterator, the HDMI output, and the keyboard, with the main
clock already at 180 MHz) met timing on the R6 with +0.102 ns and +0.010 ns
of hold slack (22,211 slices, 56,878 LUTs, and 60,518 registers), with the
same worst setup path. The builds with the 2.16 iterator before that are in
[HISTORY.md](HISTORY.md#builds-of-the-mega65).

**The floorplan.** The iterators only meet timing at 180 MHz or more with a
floorplan ([`mega65_floorplan.tcl`](mega65_floorplan.tcl), in the source
files of both MEGA65 revisions in the Makefile, sourced by `mandelbrot.tcl`
after the synthesis). Each job module gets a pblock with the six DSPs of its
iterator (a column of six DSPs, the relatively placed macro of the iterator,
see `mandelbrot.tcl`) and the slices next to them: 12 slice columns, in the 15
rows of slices that the six DSPs span (two DSPs are as high as five slices),
i.e. 180 slices for the 110 or so that the job module uses. The DSPs of the
XC7A200T are in five columns of 100 DSPs and four columns of 60 (rows 20 to
79), which hold 16 and 10 iterators, i.e. 120 in total (the other 20 DSPs are
not used). The job modules are given to the columns in order, so the job
modules of a group of the dispatcher (16 job modules, which share registers)
are in one or two neighbouring columns. Without the floorplan, the placer put
the fabric logic of many iterators far from their DSPs, e.g. the DSPs in the
column at the right edge of the FPGA, and the registers of the same iterator
spread over the whole width of the FPGA. The routes between the DSPs and the
fabric then took up to 3.2 ns, the setup slack after the placement was
-1.2 ns to -1.5 ns at 180 and 160 MHz, and -0.2 ns at 148.97 MHz, and the
router got stuck with about 35,000 nodes with overlaps (the placer reported
congestion of level 5 and 6 in the middle of the FPGA). Without the macros for
the DSPs (or with one macro for each cascade of three DSPs, which the cascade
already forces), it was no better (-1.47 ns after the placement). With the
floorplan the setup slack after the placement is +0.48 ns at 180 MHz, and
there was no congestion of level 5 or more.

The previous runs of the wide iterator, before it was rebased onto the view
in the top left corner, the palette selected with the keys `1` to `4`, and
the R3 reading the reset button from the MAX10, met timing with +0.069 ns on
the R6 (22,974 slices) and +0.092 ns on the R3, and the runs before those,
before the reset of the display memory was removed (see
[Display memory](#display-memory)), the buttons and switches were
synchronized with two registers, and the asynchronous inputs were declared
as false paths, with +0.109 ns on the R6 (22,035 slices) and +0.118 ns on the
R3, see [HISTORY.md](HISTORY.md#builds-of-the-mega65).

With 1280x1024 (1,310,720 pixels) and 120 job modules, the model gives
1103544 clock cycles for the initial view, i.e. 5.88 ms at 187.8 MHz (about
170 pictures per second), see [Timing](#timing). Jobs of 32 to 256 rows give
168 to 171 pictures per second. If every pixel needed the maximum count (1023),
the picture would take about 11.2 million clock cycles (60 ms, 17 pictures per
second). A simulation of a partial picture with `main_tb` and the design of
the MEGA65 (200 us of simulated time: 1273 of the 1280 columns, rows 0 to 63,
78,828 pixels, about 10 minutes) gave the same pixels as the model, and so did
a complete picture of 160x128 pixels with the original version of the wide
iterator, see [Timing](#timing).

### Nexys 4 DDR
The Nexys 4 DDR has an XC7A100T with speed grade -1 (part xc7a100tcsg324-1).
The design is the same as on the MEGA65, but smaller (see
[`src/nexys4ddr.vhd`](src/nexys4ddr.vhd)): 39 job modules, 640x480 (with a
25 MHz pixel clock), jobs of 120 rows, and a display memory of 2^19 pixels in
128 BRAMs, with a register for the write port of each block. There is no
keyboard, video DAC, or HDMI output, and the frame rate is also shown on the
7-segment display. The numbers below come from a run of `make nexys4ddr`,
which meets timing with a 120 MHz main clock.

| Resource         | Used     | Available | Used (%)
| ---------------- | -------- | --------- | --------
| DSP48E1          | 234      | 240       | 98
| Block RAM        | 128 RAMB36 + 1 RAMB18 | 135 RAMB36 | about 95
| Slices           | 9,840    | 15,850    | 62
| LUTs             | 21,353   | 63,400    | 34
| Registers        | 30,918   | 126,800   | 24
| Clock buffers    | 3 BUFG, 1 MMCM | |

The available numbers are the totals for the XC7A100T. Its 240 DSPs are in
three columns of 80, and the six DSPs of an iterator are placed in a column
(two cascades of three, which can not go from one column to another), so a
column has room for 13 iterators, and 6 DSPs are not used. With 40 job
modules the placer could not place the macros of the iterators. The job
modules use less than two thirds of the slices, and there is no floorplan.

The "Report Cell Usage" table in `build/nexys4ddr/vivado.log` gives the cell
counts after synthesis instead: 23,421 LUT cells (LUT1 to LUT6), 30,862
registers (FDRE and FDSE cells), and 4,108 shift registers (SRL16E, 105 in
each iterator), see [MEGA65](#mega65). Each job module (with its iterator)
uses 461 to 464 LUTs (57 of them as shift registers) and 521 registers,
about the same as on the MEGA65.

The display memory has 2^19 pixels of 9 bits (the count), i.e. 128 blocks of
36 kbit BRAM, each written as 1024 entries of 36 bits (four pixels, with the
parity bits) and read as 4096 entries of 9 bits, as expected. The RAMB18 is
used by the dispatcher (dispatcher\_results), for the tables `job_addr_r` and `job_blk_r` that hold the picture column and the
block of the job of each job module.

The timing after routing is:

| Check | Slack
| ----- | -----
| Setup (WNS) | +0.347 ns (TNS 0)
| Hold (WHS)  | +0.008 ns (THS 0)

The timing is met after the routing (+0.346 ns), before the post-route
`phys_opt_design`. The previous run, before the rebase onto the design that
is the same on all the boards in `core.vhd`, the moving palette, the
palettes with all 9 bits of the count, and the BRAMs that select the pixel
in the word, and before the count modulo 511, met timing with +0.266 ns
(10,017 slices), the run before that, without the register of stepy in the
iterator, with +0.308 ns (9,694 slices), and the last run with the 2.16
iterator, on main before the rebase, with +0.090 ns (9,294 slices), see
[HISTORY.md](HISTORY.md#builds-of-the-nexys-4-ddr). The worst setup path is
from the reset of the main clock (`main_rst_r` in `clk_rst`) to the reset of
the start of the view (`start` in `viewport_axis`), only routing (6.94 ns of
7.39 ns). The worst hold path (+0.008 ns) is in the display memory, from the
data register of a block (`blk_data_r`) to its BRAM. The 115 paths from the
MAIN clock to the VGA clock (the frame rate, the view, and their toggle
signal) have +8.47 ns of slack against the maximum delay of 10 ns, and
`report_cdc` reports all of them as safe.

The 120 MHz main clock (period 8.33 ns) is generated from the 100 MHz input
clock by the MMCM: it is multiplied by 12, which gives 1200 MHz (the maximum
for speed grade -1), and divided by 10. With the earlier 2.16 iterator,
whose longest path was a whole iteration in one clock cycle, the iterators
failed timing at 126.3 MHz (divided by 9.5) by 0.07 to 0.17 ns. The wide
iterator is pipelined, and a faster main clock has not been tried yet. The
main clock uses the output CLKOUT0
of the MMCM, because it is the only output with a fractional divider. The
MMCM also generates the 25 MHz VGA clock (divided by 48). On the MEGA65 the
VCO is 1080 MHz instead, see [MEGA65](#mega65). The constraints in
`nexys4ddr.xdc` are the 100 MHz input clock, a maximum delay
(`set_max_delay -datapath_only`) for the paths from the MAIN clock to the VGA
clock, which only carry the frame rate, the view, and their toggle signal to
the synchronizer in `cdc_data` (see [Overlay](#overlay)), and a false
path (`set_false_path`) from the inputs (the reset, the buttons, and the
switches), which are asynchronous, and synchronized with two registers. The
constraint file of the MEGA65, [`mega65.xdc`](mega65.xdc), has the same, with
the joysticks, the data from the keyboard, and the reset button (R6) or the
data from the MAX10 (R3) as the inputs; there the paths from the MAIN clock
to the VGA clock also carry the palette and its movement (from `controls`),
which `vga` synchronizes with two registers. Apart from these, the two clocks only
meet in the display memory, which has a separate clock for each port.

The router leaves about 5,200 nodes with overlaps after the initial routing.
The run of `make nexys4ddr` takes about 6 minutes (synthesis 2 minutes,
placement 1 minute, routing 1.5 minutes), on a machine with 20 threads, also
at the same time as the runs of the MEGA65.

### Power
A picture is only calculated when the view changes (see [Redraw](#redraw)),
the iterators do not toggle while they are idle (see
[Iterator](#iterator)), and the display
memory only reads the BRAM that holds the pixel and has no reset (see
[Display memory](#display-memory)). The numbers below are
estimates by `report_power` on the routed designs (the "busy" numbers are in
`build/<board>/power.rpt`), without simulation data
(vectorless). "Busy" uses the default activity of Vivado (most signals
toggle in 12.5% of the clock cycles), i.e. roughly the design while a
picture is calculated. "Idle" sets the activity of all the signals in the
dispatcher and the job modules to zero (`set_switching_activity -toggle_rate
0 -static_probability 0`), so the clock enables in the iterators are low, i.e.
the design between the pictures:

| Board | Busy | Idle | Main (busy / idle) | Display memory (busy / idle)
| ----- | ---- | ---- | ------------------ | ----------------------------
| MEGA65 R6   | 3.72 W | 0.89 W | 2.97 W / 0.36 W | 0.25 W / 0.04 W
| Nexys 4 DDR | 1.14 W | 0.38 W | 0.73 W / 0.11 W | 0.16 W / 0.03 W

The MEGA65 R3 gives almost the same (3.71 W and 0.89 W). The MEGA65 builds
are at 187.8 MHz, with the HDMI output and the keyboard. While a button is
held down, the design is busy for about 10% of the time on the MEGA65 and
13% on the Nexys 4 DDR, and otherwise it is idle. The values of
x and y in the iterators change in almost every clock cycle while they are
busy, so the real busy power is probably higher than the estimate, and the
saving larger.

On the MEGA65 the busy power is mostly the DSPs (1.26 W), the signals
(0.98 W), the logic (0.51 W), and the clocks (0.49 W), almost all in the job
modules. The idle power is mostly the clocks (0.40 W), the I/O (0.17 W, the
VGA and HDMI outputs), the static power (0.16 W), and the MMCM (0.13 W). The
block RAM uses 0.005 W, and the signals 0.02 W. The clocks use more than with
the 2.16 iterator (0.25 W while idle), because the main clock is faster and
there are more registers. The previous runs, at 192 MHz, gave 3.78 W and
0.90 W on the R6 (the DSPs 1.29 W). The runs before those, before the rebase
and the count modulo 511, gave 3.77 W and 0.92 W on the R6 (the DSPs
1.24 W). The runs
before those, at 180 MHz and without the register of stepy in the
iterators, gave 3.53 W and 0.86 W on the R6 (the DSPs 1.21 W). The runs before
those, without the explicit register
M in the last DSPs of the wide iterator, gave 3.56 W and 0.86 W on the R6
(the DSPs 1.25 W). The runs before those, before the wide iterator was
rebased onto the view in the top left corner, the palette selected with the
keys, and the R3 reading the reset button from the MAX10, gave 3.57 W and
0.86 W on the R6, and the runs before those 3.50 W and 0.85 W on both
revisions. The earlier runs, also those with the 2.16 iterator, are in
[HISTORY.md](HISTORY.md#power).

On the Nexys 4 DDR the busy power is mostly the signals (0.39 W), the DSPs
(0.25 W), and the clocks (0.14 W), and the idle power the clocks (0.12 W), the
MMCM (0.12 W), and the static power (0.10 W). The previous run, before the
rebase and the count modulo 511, gave 0.98 W busy and 0.39 W idle (the
signals 0.23 W). With the 2.16 iterator (120
job modules) it was 1.20 W busy and 0.36 W idle, see
[HISTORY.md](HISTORY.md#power).
