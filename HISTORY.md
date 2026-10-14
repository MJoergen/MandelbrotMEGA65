# The history of the design
This is how the Mandelbrot design got to where it is: the earlier versions
of its parts, the numbers of the model at the time, and the results of the
earlier builds. [ALGORITHM.md](ALGORITHM.md) describes the current design,
and links here where a part had an earlier version. The design was first
developed on the Nexys 4 DDR, and the MEGA65 was added later, so most of the
history is about the Nexys 4 DDR, at 640x480.

The design was developed in the `mandelbrot/` folder of
[MJoergen/nexys4ddr](https://github.com/MJoergen/nexys4ddr), and moved to
this repository on 12 October 2026. The last version there is
[mandelbrot/ at cb97f12](https://github.com/MJoergen/nexys4ddr/tree/cb97f12898373688fc146e128c3e287b1dd40c6c/mandelbrot).
The commits from before the move refer to that folder, and their `#N` refer
to the pull requests of that repository.

## Contents
* [The iterator](#the-iterator)
  * [The 2.16 iterator](#the-216-iterator)
* [The dispatcher](#the-dispatcher)
* [The display memory](#the-display-memory)
* [When a picture is calculated](#when-a-picture-is-calculated)
* [The frame rate](#the-frame-rate)
* [The colours](#the-colours)
* [Timing](#timing)
  * [Several pixels in each write](#several-pixels-in-each-write)
  * [One iteration in each clock cycle](#one-iteration-in-each-clock-cycle)
  * [Timing of the 2.16 iterator](#timing-of-the-216-iterator)
* [Builds of the MEGA65](#builds-of-the-mega65)
* [Builds of the Nexys 4 DDR](#builds-of-the-nexys-4-ddr)
* [Power](#power)

## The iterator
An earlier version of the iterator used a single DSP, which calculated both
products one after the other, so each iteration took three clock cycles (the
DSP was idle in one of them). It needed 129 LUTs and 87 registers, where the
2.16 iterator with two DSPs (see [below](#the-216-iterator)) needed 70 LUTs
and 47 registers, because x and y are held in the DSPs, and the inputs of the
DSPs need no multiplexers. So that iterator did three times as many
iterations in each clock cycle, with about half the logic, but it used two
DSPs instead of one.

Before the clock enable of the registers P, the DSPs went on calculating
while the iterator was idle, with values that were not used (e.g. the values
of a point in a cycle, or the values after an overflow, which wrap around),
so an idle iterator used as much power as a busy one.

The iterator with a single DSP registered the result of the comparison of
the periodicity detection, and stopped one iteration later. With the
detection, its job module needed 126 clock cycles per pixel on average for
the initial view, instead of 435.

An earlier version of the iterator calculated x+y and x-y in 18 bits, so they
wrapped around when they were outside the range -2 to 2. For the initial view
this gave a different count for about 13% of the pixels, compared with the
same calculation without the wrap around. It was much worse when zooming in
near the points -2 and +-i, where the orbits often have x+y or x-y close to -2
or 2. Here the picture had straight edges and broken filaments, and some
points were even wrongly shown as inside or outside the set. The testbench of
the iterator includes two points where x+y or x-y is outside the range -2 to 2
during the iteration, and the version that wrapped around gave a wrong count
for both.

The iterator with a single DSP used its multiplier in two out of three clock
cycles, so it gave about 25 billion multiplications per second on the MEGA65
(256 DSPs at 148.97 MHz) and 24 billion on the Nexys 4 DDR (240 DSPs at
150 MHz), against 104 and 28.8 billion with two DSPs.

### The 2.16 iterator
Until October 2026 the Nexys 4 DDR used numbers in 2.16 format (18 bits) and
the maximum count 511, with the iterator `src/main/iterator.vhd` and the job
module `src/main/job.vhd`, in 120 job modules with two DSPs each. The MEGA65
used them too, with 368 job modules, before it got the wide iterator. They
were removed when the Nexys 4 DDR got the wide iterator too (39 job modules
of six DSPs each), so that there is only one iterator. Their last version is
in commit 5572882. The rest of this section is their description from
ALGORITHM.md at the time.

**Multiplier.** The built-in DSP (DSP48E1) provides a 25x18-bit signed
multiplier, followed by a 48-bit adder (the post-adder). Each iterator uses
two of them, one for each of the two multiplications of an iteration:
* The first DSP is used as a 19x18-bit multiplier, with the first input
  (x+y or x-y) in 3.16 bit representation and the second input (the other
  one) in 2.16 bit representation (see [Overflow](ALGORITHM.md#overflow) for why the
  first input has 19 bits). The post-adder adds cx, so the output is the new
  value of x.
* The second DSP is used as an 18x18-bit multiplier, with the inputs x and y.
  The post-adder adds cy/2, so the output is half the new value of y.

The products are always between -4 and 4, and the sums between -6 and 6, so
they fit in 4.32 bit representation (36 bits), which is the lowest 36 bits of
the 48-bit output of the DSP.

The output of each DSP is registered in the DSP (the register P), and these
two registers *are* the values of x and y of the iterator: the inputs of the
multipliers are not registered, and neither are the products (the registers
A, B, and M are not used), so the DSPs calculate a complete iteration in each
clock cycle. The constants cx and cy/2 are registered (the register C), which
does not delay anything, because they do not change while a point is
calculated.

The DSPs are not instantiated directly. They are inferred by Vivado from the
process `p_dsp` in `src/main/iterator.vhd`, so the
simulation needs no model of the DSP. The "DSP Final Report" in `build/<board>/vivado.log`
shows how the DSPs are used (`(C'+A*B)'`, i.e. the registers C and P).

**Iterator.** Example: We start with the point -0.5+0.5i, i.e. cx = -0.5 and
cy = 0.5. This point is in the Mandelbrot set, so the iteration continues
until the maximum count. The expected sequence of points is then:
```
cnt |   x                |   y
----+--------------------+--------------------
 0  |  0.00000 (00000)   |  0.00000 (00000)
 1  | -0.50000 (38000)   |  0.50000 (08000)
 2  | -0.50000 (38000)   |  0.00000 (00000)
 3  | -0.25000 (3C000)   |  0.50000 (08000)
 4  | -0.68750 (35000)   |  0.25000 (04000)
 5  | -0.08984 (3E900)   |  0.15625 (02800)
 6  | -0.51634 (37BD1)   |  0.47192 (078D0)
 7  | -0.45612 (38B3C)   |  0.01265 (0033D)
 8  | -0.29213 (3B537)   |  0.48845 (07D0B)
```
The values in the parentheses are the (2.16 fixed point) hexadecimal
representation of the values, and the decimal numbers are these values rounded
to five decimals. The values are calculated with the bit-accurate model (see
below). Up to iteration 5 they are exact, but from iteration 6 the new values need
more than 16 fraction bits, and the iterator truncates them (rounds towards
minus infinity). So the values differ slightly from a calculation with real
numbers, e.g. x is -0.45610 in iteration 7 with real numbers.

The testbench for the iterator (`sim/iterator_tb.vhd`)
is self-checking. It runs a few starting values (in the set, escaping
immediately, escaping quickly, and escaping slowly), and compares the count
with one calculated using real (floating point) numbers. The counts must be
equal, within a small tolerance. For the points in the set it also checks that
the periodicity detection stops the iteration long before the maximum count.
Then it compares the count exactly with the bit-accurate model (see below) for
a grid of 40 x 30 points over the initial view, and for six points that were
found by a search with the model, where x or y alone repeats a saved value
before the point escapes. These fail if the detection compares only x or only
y. It also checks that the registers P do not change while the iterator is
idle (see below), also after a point in a cycle of period 2 and after a point
that escapes, where they would otherwise go on changing. The script
`sim/iterator_model.py` is a bit-accurate Python model
of the iterator, which follows the VHDL literally. It gives the same counts as
the testbench for the same points, and can be used to compare the iterator with
the real-number count for many more points (`./iterator_model.py --grid`).

The iterator calculates one iteration in each clock cycle, using two DSPs
(see [Multiplier](ALGORITHM.md#multiplier)). The registers P of the two DSPs hold x and
y (the first one x, the second one y/2, both in 4.32 bit representation), and
in each clock cycle:
* x+y and x-y are calculated (in 19 bits) from the outputs of the DSPs, in
  the FPGA fabric (see [Overflow](ALGORITHM.md#overflow)),
* the first DSP multiplies them and adds cx, which gives the new value of x,
* the second DSP multiplies x and y and adds cy/2, which gives half the new
  value of y,

and the new values are registered in the registers P. At the start of a point
the registers P are cleared (with the synchronous reset of the DSP), i.e.
x = y = 0, so a point that stops after n iterations takes n+1 clock cycles
from the start until done\_o is high. In each clock cycle the iterator also
checks the overflow and the periodicity of the values in the registers P (see
below), and stops when one of them is found, or after the maximum count.

After that, the registers P keep their value until the next start: their
clock enable (CEP) is the busy flag of the iterator (`busy_r`). So nothing in
the iterator toggles while it is idle, i.e. between the jobs and when no
picture is calculated (see [Redraw](ALGORITHM.md#redraw)). The clock enable is a
separate input of the DSP, so it is not in the longest path (below), and the
synchronous reset of the DSP (RSTP, the start) has priority over it, as in
the VHDL, so it needs no logic: the iterator still has 70 LUTs and 47
registers.

The path from the registers P, through the adder for x+y or x-y, the
multiplier, and the post-adder of the first DSP, and back to its register P,
is the longest path of the iterator, and it decides the clock frequency of
the whole design. About half of it is in the DSP (from its input to its
register P), and the rest is the adder and the routes from and to the DSPs.
So the two DSPs of an iterator must be next to each other, in the same
column: when the placer put them in different columns, the routes took up to
1.8 ns more. The build script (`mandelbrot.tcl`) puts each pair in a
relatively placed macro (`create_macro` and `update_macro`), which places the
two DSPs in adjacent sites.

Registering the inputs of the multipliers or the products (in the registers
A, B, or M of the DSP) would make the path much shorter, but each register
would add a clock cycle to each iteration. Two or three points could then be
calculated in turns by the same DSPs, but the job module would have to handle
several rows at the same time.

**Periodicity detection.** For the initial view, the detection stops 314879 of
the 351478 pixels in the set early, and the job module needs 46 clock cycles
per pixel on average (including 7 clock cycles to start the iterator and to
deliver the result, see [Timing](ALGORITHM.md#timing)), instead of 150. The
rest of the pixels in the set (near the edge of the set) do not reach a cycle
within 511 iterations.

**Overflow.** The two products are calculated in 4.32 format (36 bits), and
the new values are the sums
```
new_x   = (x+y)*(x-y) + cx
new_y/2 = x*y + cy/2
```
also in 4.32 format. The sums are calculated by the adder in the DSP. The
range is checked on these sums, and not on the
products alone. A product can be between -4 and 4, i.e. outside the range of
the final value, even when the sum with cx or cy/2 is inside the range, and the
other way around. The sums are between -6 and 6, so they can not overflow
the 36 bits. The new x is in range if the three top bits of the sum (bits 35
to 33) are equal. The new y is twice the second sum, so that is in range if
the four top bits of the second sum (bits 35 to 32) are equal. The new values of x and y are then bits 33 to 16 of
the first sum and bits 32 to 15 of the second sum, respectively.

The remaining differences, compared with a calculation using real numbers, come
from the limited precision of the 2.16 format. For the initial view about 1.4%
of the pixels have a different count, and about 0.1% (1390 pixels) are on the
other side of the boundary of the set (`sim/model.py`).

**Job module.** The job module of the 2.16 iterator calculated one row at a
time, with the same ports as `job_wide.vhd` (but with 18-bit values), and
`G_PIXELS` could be any power of two. When `G_PIXELS` is more than 1, the job
module keeps the counts of the first `G_PIXELS`-1 rows of a result in a
register, and starts the next row at once, in the clock cycle after the
iterator is done. So it only waits for the acknowledge after the last row of a
result. Before the next row, the count of the row is put at the top of the
register, which shifts the earlier counts down, so the count of the first row
ends up at the bottom. The register does not change from the last row of a
result until the next row has been calculated, i.e. until after the
acknowledge, so it is output directly, and only the count of the last row goes
through the output register of the job module. With an output register for all
36 bits, the MEGA65 build (then with 368 of these job modules) used 12,000
more registers.

The testbench for the job module (`sim/job_tb.vhd`)
is self-checking. It runs three jobs of 12 rows each, and checks that the
job module is busy only during a job, that the results come in order, with
the right row numbers, that a result stays unchanged until it is acknowledged
(the acknowledge is delayed by a varying number of clock cycles), and that the
count for each row is exactly the count calculated by the bit-accurate model
(see [Iterator](ALGORITHM.md#iterator)). The third job is near the top of the set, where
x+y or x-y is often out of range. It does this for 1, 2, and 4 rows in each
result, with three instances of the job module.

## The dispatcher
Earlier, the round-robin scheduler for the jobs was used for the results
too, and a job module waited up to 240 clock cycles (with 240 job modules)
for each result, also when no other job module had a result ready (see
[Timing](#timing)).

## The display memory
Before the MEGA65 had 320 blocks, the read address went directly to all the
BRAMs, the word was selected from all the blocks in one clock cycle, and the
pixel from the word in the next, i.e. three clock cycles of latency. With 320
blocks at 108 MHz, the route from the pixel counters to all the BRAMs alone
took 8.2 ns of the 9.26 ns.

Before the BRAMs had asymmetric ports, the read port read a whole word (36
bits with four pixels in each word) from the BRAM, and each group selected the
block and then the pixel in the word (`rd_sub_r`, a 32:1 multiplexer for each
of the 9 bits in each of the 40 groups on the MEGA65). Now the BRAM selects the
pixel itself, which saved about 2,600 LUTs on the MEGA65 (48,336 to 45,752).

Before only the BRAM that holds the pixel was read, all the BRAMs were read
in every clock cycle of the VGA clock, which was most of the power while the
job modules were idle (see [Power](#power)).

Before the display memory had no reset, a reset filled the whole memory with
the value 0x055, which took `G_NUM_BLOCKS`*4096/`G_PIXELS` clock cycles (2.31
ms on the MEGA65, and 1.09 ms on the Nexys 4 DDR). The write port ignored the
writes while this was in progress, so `main` had to wait for it (`wr_busy_o`)
before it started the first picture. Without the filling, the wait, the busy
signal, and the address counter and the multiplexer on the write port are
gone.

## When a picture is calculated
Before, a new picture was started as soon as the previous one was finished,
so the picture was recalculated continuously (402 pictures per second for
the initial view on the MEGA65, and 833 on the Nexys 4 DDR), all the job
modules were busy all the time, and the FPGA got too hot.

When the display memory was filled after reset (see
[Display memory](#the-display-memory)), the first picture had to wait until
it was finished, because the display memory ignored the writes until then.
Before that wait was added, on the MEGA65 (then at 144 MHz) the filling
(2.28 ms) took almost as long as the first picture (2.49 ms), so the screen
showed the colour of 0x055 (green) except for the last rows of the picture,
until the view was changed.

## The frame rate
When the picture was recalculated continuously, the time for the frame rate
was averaged over about 256 pictures (0.6 s for the initial view, 0.3 s on
the Nexys 4 DDR), because it varies a little from picture to picture, and
without the average the last digits changed all the time. With at most 18
pictures per second, this average would take about 14 seconds to follow a
change of the view, so `main` no longer averages.
The module `fps.vhd` could still average (the generic `G_AVG_SHIFT`, an
exponentially weighted moving average: for each picture, the difference
between its time and the average, divided by 2^`G_AVG_SHIFT`, was added to the
average, which had `G_AVG_SHIFT` fractional bits), but `main` used
`G_AVG_SHIFT` = 0, so it was removed. The calculation then took one clock
cycle more (59 clock cycles, 57 on the Nexys 4 DDR).

## The colours
An earlier version stored only the lower 8 bits of the count in the display
memory, so the (few) points with the count 255 had the same value as the set,
and were shown in the colour of the set.

## Timing
This follows the development of the design. Most of it is about the
iterator with a single DSP, which took three clock cycles for each
iteration, and about the Nexys 4 DDR at 640x480, where the design was first
developed. The numbers of the current design are in
[Timing](ALGORITHM.md#timing).

The time for the picture measured on the Nexys 4 DDR, with the main clock at
174.55 MHz and the initial view, was 472\*2^11 clock cycles, i.e. 5.5 ms at
174.55 MHz. This value is steady. The same number of clock cycles was measured
with the main clock at 140.625 MHz (6.9 ms), before the clock was raised (see
[Builds of the Nexys 4 DDR](#builds-of-the-nexys-4-ddr)). This was before the
periodicity detection (see [Iterator](ALGORITHM.md#iterator)), and before the
schedulers and the done flag were pipelined (see
[Dispatcher](ALGORITHM.md#dispatcher)).

This agreed with the model [`sim/model.py`](sim/model.py) at the time,
which estimated the time for the picture from the number of iterations of each
pixel, as follows. A job module uses 3 clock cycles per iteration, plus 7
clock cycles to start the iterator and to deliver the result, i.e. 3n+7 clock
cycles, where n is the number of iterations done when the iterator stops: the
count for a pixel that escapes, 510 for a pixel that reaches the maximum
count, and the iteration after the match for a pixel where a cycle is found.
Then the result must be accepted by the dispatcher. The scheduler for the
results was then the same round-robin scheduler as for the jobs, which checked
each job module once every 240 clock cycles, so the time from one result of
a job module to the next was always a multiple of 240 clock cycles. This was
checked in simulation. So:
* A pixel with a count up to 77 took 240 clock cycles, i.e. the iterator was
  idle for most of the time, waiting for the result to be accepted.
* A pixel in the set that does not reach a cycle took 3\*510+7 = 1537 clock
  cycles, which was rounded up to 1680 clock cycles. Before the periodicity
  detection, this was the case for all the pixels in the set.

Without the periodicity detection, the iterator needed 460 clock cycles per
pixel on average for the initial view (the average count is 151), but each
pixel took 652 clock cycles on average, including the waiting. A single
picture column through the middle of the set took up to 0.73 million clock
cycles, so these picture columns decided the total time. The model gave
472\*2^11 clock cycles for the picture, the same as measured.

With the periodicity detection, the iterator needs 132 clock cycles per pixel
on average, and each pixel took 316 clock cycles on average, including the
waiting. Most of the pixels took the minimum of 240 clock cycles, and the
longest picture column took 0.27 million clock cycles. When each job was a
whole picture column, the model gave 551040 clock cycles (269\*2^11) for the
picture, i.e. 2.9 ms at 188.24 MHz, 1.75 times faster than without the
detection (about 341 pictures per second).

With 640 jobs and 240 job modules, each job module got fewer than three
jobs, so the work was not shared evenly at the end of the picture: if the
work was spread evenly over the job modules, each of them would need
404875 clock cycles. With jobs of 120 rows (2560 jobs), the longest job took
0.11 million clock cycles, and the model gave 418560 clock cycles
(204\*2^11) for the picture, i.e. 2.22 ms at 188.24 MHz, 1.32 times faster
(about 450 pictures per second). The model gave 465840 clock cycles for jobs
of 240 rows, and 413040 clock cycles for jobs of 60 rows. Eight other views
(zoomed in at different places) were 1.07 to 1.31 times faster in the model
with jobs of 120 rows than with whole picture columns.

When the acknowledge was delayed by one more clock cycle (by the registers in
the groups, see [Dispatcher](ALGORITHM.md#dispatcher)), the time for the
picture did not change, because the time from one result of a job module to
the next was still rounded up to the same multiple of 240 clock cycles.

Without the waiting, the picture would take about 0.9 ms (if the work was
spread evenly over the job modules). So the time for the picture was
mostly decided by the round-robin scheduler for the results, which accepted a
result from each job module only once every 240 clock cycles.

The same time for the picture (472\*2^11 clock cycles) was measured earlier,
with an iterator which did not detect all overflows and which calculated x+y
and x-y in 18 bits (see [Overflow](ALGORITHM.md#overflow)), and with a main
clock of 150 MHz. The time for the picture did not change, because it is
decided by the picture columns through the middle of the set, where most of
the pixels reach the maximum count.

The display memory can take one result per clock cycle, so a picture takes at
least 307200 clock cycles (2.05 ms at 150 MHz). The round-robin scheduler gave
each job module an equal share of this, one result every 240 clock cycles,
also when the other job modules had no result ready. The scheduler for the
results now accepts a result from any job module of a group that has one
ready, visiting one group in each clock cycle (see
[Dispatcher](ALGORITHM.md#dispatcher)). The time for a pixel then depends on
the other job modules, so the model now simulates the dispatcher one clock
cycle at a time (`picture_cycles()` in `sim/model.py`). It used the time 3n+7
above for each pixel, and it includes the round-robin scheduler for the jobs.
(At the time it counted the 3n+7 clock cycles from the clock cycle before the
previous result was accepted, which is two clock cycles too short for each
result, see the end of this section; the numbers in this and the next
paragraphs are from that version.) For the initial view it gave 347123 clock
cycles for the picture, i.e. 1.84 ms at 188.24 MHz, the main clock at the time
(see [Builds of the Nexys 4 DDR](#builds-of-the-nexys-4-ddr)). At 150 MHz (the
main clock with the iterator with a single DSP) it is 2.31 ms, so the
7-segment display should show about 432 pictures per second. The same
simulation with the round-robin scheduler for the results gives 2.24 ms (0.02
ms more than above, because it includes the time to give out the jobs), so the
new scheduler is 1.21 times faster. The display memory is now written in 88%
of the clock cycles, and the job modules wait 127 clock cycles per pixel on
average. Eight other views were 1.11 to 1.21 times faster with the new
scheduler. Registering the ready flags in the groups (see
[Dispatcher](ALGORITHM.md#dispatcher)) makes no measurable difference: before,
the model gave 347682 clock cycles, and a simulation of a complete picture
with `main_tb` took 347110 clock cycles from the start to the last write to
the display memory, 0.2% less than the model, with all the pixels the same as
in the model. None of this was measured on a board (the current design was,
see the end of this section).

Storing a result in each job module, so the iterator could continue with
the next row while it waits, was considered too. With the round-robin
scheduler for the results it would have made the initial view only 4% faster
(and two results no better than one), because each job module could still
deliver only one result every 240 clock cycles.

### Several pixels in each write
With the scheduler for the results above, the time for the picture is mostly
decided by the write port of the display memory, which takes one result per
clock cycle. The BRAMs can be written in words of 36 bits instead of 9, i.e.
four pixels, with the same number of BRAMs (see [Display
memory](ALGORITHM.md#display-memory)). So each result can be four consecutive
rows of a picture column (the generic `G_PIXELS`), which the job module
calculates one after the other, keeping the counts of the first three (see
[Jobs](ALGORITHM.md#jobs)). A result then takes the sum of the times of its
four rows (less 4 clock cycles for each row after the first, because the
iterator starts the next row itself), and the dispatcher writes up to four
pixels per clock cycle. The model gives these times for the initial view at
640x480 (in clock cycles, and frames per second at 188.24 MHz in brackets):

| Job modules | 1 pixel in each write | 2 pixels | 4 pixels
| -------------- | --------------------- | -------- | --------
| 240            | 347123 (542)          | 241674 (779) | 209248 (900)
| 450            | 339741 (554)          | 203477 (925) | 161909 (1163)

A dispatcher where any
result can be written, with up to four writes per clock cycle, would take
about 152000 clock cycles with 450 job modules (estimated with a simpler
model), so four pixels in each write
gets most of what more writes per clock cycle can give. The rest is mostly
the end of the picture, when the last jobs finish one after the other, and
the iterators alone would need 89954 clock cycles (0.48 ms) for the initial
view with 450 job modules, if the work was spread evenly. Several
independent dispatchers, each with its own BRAMs (e.g. for the even and the
odd picture columns), would give about the same, but with all the control
logic duplicated. For views where the iterators need more time per pixel, the
gain is smaller: a view of Seahorse Valley (0.08 wide, centred near
-0.75+0.15i) takes 618735 clock cycles with one pixel and 517626 with four
pixels in each write (with 450 job modules), 1.20 times faster.

Four pixels in each write were first used on the MEGA65 (see
[MEGA65](ALGORITHM.md#mega65)), while the Nexys 4 DDR used one pixel in each
write until it got the iterator with two DSPs. Now both boards use four pixels
in each write, see *One iteration in each clock cycle* below. With the
iterator with a single DSP, a run of `make nexys4ddr` with four pixels in each
write fitted and met timing at 188.24 MHz, but only just: it used 15,459
slices (97.5%), 44,737 LUTs, and 55,538 registers, and had +0.012 ns of setup
slack and +0.005 ns of hold slack (in an iterator). The model gave 209248
clock cycles for it (1.39 ms at 150 MHz, about 716 pictures per second). A
simulation of a complete picture with `main_tb` and the design of the MEGA65
(then 640x480) took 161878 clock cycles from the start to the last write to
the display memory, 0.02% less than the model, with all the pixels the same as
in the model. The simulation took about an hour.

### One iteration in each clock cycle
All of the above is for the iterator with a single DSP, which took three clock
cycles for each iteration. The current iterator uses two DSPs and takes one
clock cycle for each iteration (see [Iterator](ALGORITHM.md#iterator)), so a
pixel takes n+7 clock cycles in the model (counted from the selection of the
previous result, see [Timing](ALGORITHM.md#timing)) instead of 3n+7, where n
is the number of iterations done when the iterator stops. It uses about half
the logic of the old one, so the job modules are now limited by the number of
DSPs: 368 job modules on the MEGA65 (736 of the 740 DSPs), and 120 on the
Nexys 4 DDR (240 DSPs). Both boards use four pixels in each write. For the
initial view the model gives the numbers in [Timing](ALGORITHM.md#timing).
Before, with one DSP in each job module, the model gave:

| | MEGA65 | Nexys 4 DDR
| --- | --- | ---
| Before (one DSP in each job module) | 256 job modules, 148.97 MHz: 732009 clock cycles (203 pictures per second) | 240 job modules, 150 MHz, one pixel in each write: 347123 clock cycles (432 pictures per second)

On the MEGA65 the initial view is 1.98 times as fast as before. Views that
need more iterations gain more: for the view of Seahorse Valley above (0.08
wide, centred near -0.75+0.15i) the model gives 806213 clock cycles on the
MEGA65 (176 pictures per second), against 3175765 clock cycles (47 pictures
per second) before, 3.8 times as fast, and the worst case (every pixel needs
the maximum count) is 4.1 times as fast. Jobs of 32 to 128 rows give 396 to
400 pictures per second on the MEGA65.

On the Nexys 4 DDR the main clock is lower (120 MHz instead of 150 MHz), see
[Nexys 4 DDR](ALGORITHM.md#nexys-4-ddr), and with one pixel in each write the
picture would be slower than before (2.73 ms), because the display memory
would decide the time. With four pixels in each write it is 1.93 times as fast
as before.

An earlier version of the model
selected a result two clock cycles after its ready flag was high, and gave
the next result n+6 clock cycles after the selection, i.e. two clock cycles
less for each result, and the first result of each job two clock cycles
later. It gave 143399 clock cycles for the initial view on the Nexys 4 DDR
(0.5% less than the simulation), and 357858 on the MEGA65. Most of the
numbers of the model in this document are from that version or earlier
ones.

### Timing of the 2.16 iterator
With the 2.16 iterator, a pixel took n+7 clock cycles in the model, counted
from the selection of the previous result, where n is the number of
iterations done when the iterator stopped, and a result of four rows the sum
of the times of its four rows (less 4 clock cycles for each row after the
first, because the iterator started the next row itself, see
[The 2.16 iterator](#the-216-iterator)).

For the initial view, with the maximum count 511, the model gave:

| | MEGA65 (1280x1024), 2.16 iterator | Nexys 4 DDR (640x480)
| --- | --- | ---
| Job modules, main clock | 368, 141.64 MHz | 120, 120 MHz
| Clock cycles for the picture | 357998 (2.53 ms, 396 pictures per second) | 143751 (1.20 ms, 835 pictures per second)
| The same, with one pixel in each write | 1315936 | 327300
| Limit of the display memory (four pixels in each write) | 327680 | 76800
| Every pixel needs the maximum count | 1875525 (13.2 ms, 75 pictures per second) | 1364897 (11.4 ms, 87 pictures per second)

On the MEGA65 the initial view with the 2.16 iterator is close to the limit
of the display memory.
For the view of Seahorse Valley (0.08 wide, centred near -0.75+0.15i) the
model gives 806213 clock cycles on the MEGA65 (176 pictures per second). Jobs
of 32 to 128 rows give 396 to 400 pictures per second on the MEGA65. On the
Nexys 4 DDR, with one pixel in each write, the picture would take 2.73 ms,
because the display memory would decide the time.

A simulation of a complete picture with `main_tb` and the design of the
Nexys 4 DDR wrote the last pixel after 144113 clock cycles (counted from the
beginning of the reset), 0.3% more than the model, with all the pixels the
same as in the model. The simulation took 42 minutes (on a busy machine,
without the waveform).

Both boards were measured with the initial view. The MEGA65 R6 showed 395
pictures per second with the 2.16 iterator at 141.64 MHz, where the model
gives 396, and an R3 showed 402 with the main clock at 144 MHz, the same as
the model. The Nexys 4 DDR showed 832 to 834 pictures per second, i.e. 143,900 to 144,200
clock cycles for the picture, which agreed with the simulation above. The
model gave 0.1% to 0.3% less, because it leaves out the clock cycles at the
start and the end of the picture (e.g. the reset, and the writes after the
last result has been selected).

## Builds of the MEGA65
The current results are in [MEGA65](ALGORITHM.md#mega65). The runs before
them go back in time, starting with the latest one.

The previous run of `make mega65-r6`, at 180 MHz and before stepy was
registered in each iterator, met timing with +0.083 ns (the same after the
routing), with +0.020 ns of hold slack (from the count of a slot of an
iterator, `cnt_r`, to the result register of its job module, `res_data_d`).
It used 23,173 slices, 58,422 LUTs, and 67,263 registers (77,805 LUT cells
and 67,267 registers after synthesis). The worst setup path was from
`grp_stepy_r` in `dispatcher_jobs` to the accumulator of cy in an iterator
(`cy_acc_r`), mostly routing (4.39 ns of 5.60 ns). The VGA clock had
+0.190 ns of setup slack (from `pix_x` to `rd_grp_addr`), and the paths from
the MAIN clock to the VGA clock +6.84 ns. The run for the R3 met timing with
+0.089 ns (22,219 slices, 58,503 LUTs) and +0.013 ns of hold slack, from
`grp_stepy_r` to `cy_acc_r` too, and +0.117 ns on the VGA clock.

The run before that, where the inputs of the last DSP of
each multiplication in the wide iterator were registered twice instead of
using the register M, met timing with +0.072 ns (+0.073 ns after the
routing), with +0.020 ns of hold slack (in the shift register of cy, `cy_r`,
of an iterator). Vivado left out one of the registers of the input A of the
last DSP of (x+y)\*(x-y), so the picture on the board was wrong (see
[Multiplier](ALGORITHM.md#multiplier)). It used 23,252 slices, 58,422
LUTs, and 67,263 registers, the same LUTs and registers as the run above.
The worst setup path was from `grp_stepy_r` to the register of cy of a job
module (`res_cy_r`), mostly routing (3.82 ns of 5.62 ns). The VGA clock had
+0.231 ns of setup slack (from `pix_y` to `rd_grp_addr`, only routing,
8.39 ns of 8.82 ns), and the 117 paths from the MAIN clock to the VGA clock
+6.77 ns. The router left about 7,600 nodes with overlaps after the initial
routing. The previous run of `make mega65-r3` used 22,219 slices and 58,503
LUTs (the same as the current run), and met timing with +0.074 ns (the same
after the routing), from `grp_stepy_r` to `cy_acc_r`, and +0.013 ns of hold
slack. Its VGA clock had +0.117 ns of setup slack, the paths from the MAIN
clock to the VGA clock +8.03 ns, and the input clock +5.43 ns.

The run of `make mega65-r6` before that, with the wide iterator, before it was
rebased onto the view in the top left corner, the palette selected with the
keys `1` to `4`, and the R3 reading the reset button from the MAX10, met
timing with +0.069 ns (+0.070 ns after the routing), with +0.008 ns of hold
slack (from the register of cx of a job module, `res_cx_r`, to the register
of cx in its iterator, `cx_r`). It used 22,974 slices, 58,111 LUTs, and
66,634 registers (77,416 LUT cells and 66,674 registers after synthesis).
The worst setup path was from `grp_stepy_r` to the accumulator of cy in an
iterator (`cy_acc_r`), mostly routing (4.41 ns of 5.62 ns). The VGA clock
had +0.238 ns of setup slack (from `pix_x` to `rd_grp_blk`, only routing,
8.24 ns of 8.59 ns), and the 40 paths from the MAIN clock to the VGA clock
+8.52 ns. The router left about 7,800 nodes with overlaps after the initial
routing. The run of `make mega65-r3` before that, which did not use the reset
button and had 49 IOBs, used 22,039 slices and 58,116 LUTs, and met timing
with +0.092 ns (the same after the routing), from `grp_stepy_r` to
`res_cy_r`, and +0.021 ns of hold slack. Its VGA clock had +0.112 ns of
setup slack (from `pix_y` to `rd_grp_addr`), and the paths from the MAIN
clock to the VGA clock +8.83 ns.

The run of `make mega65-r6` before that, with the wide iterator, before the
reset of the display memory was removed, the buttons and switches were
synchronized with two registers, and the asynchronous inputs were declared
as false paths, met timing with +0.109 ns (the same after the routing), with
+0.021 ns of hold slack (in the shift register of cy, `cy_r`, of an
iterator). It used 22,035 slices, 58,129 LUTs, and 66,648 registers (77,433
LUT cells and 66,674 registers after synthesis). The worst setup path was
the same as now, from `grp_stepy_r` to `cy_acc_r`. The VGA clock had
+0.150 ns of setup slack (from `pix_x` to `rd_grp_blk`), and the paths from
the MAIN clock to the VGA clock +8.91 ns. The run of `make mega65-r3` used
22,009 slices and 58,126 LUTs, and met timing with
+0.118 ns (+0.119 ns after the routing) and +0.019 ns of hold slack. Its VGA
clock had +0.174 ns of setup slack, and the paths from the MAIN clock to the
VGA clock +8.88 ns.

The run before that, the last one with the 2.16 iterator
(368 job modules, the maximum count 511, and a 141.64 MHz main clock: the
VCO divided by 7.625, on the output CLKOUT0 of the MMCM, the only output with
a fractional divider), before the wide iterator (see
[Iterator](ALGORITHM.md#iterator)) was rebased onto it, with the
design that is the same on all the boards in `core.vhd`, the moving palette,
the palettes with all 9 bits of the count, the BRAMs that select the pixel in
the word, and the keyboard ignored after power-on, gave:

| Resource         | Used     | Available | Used (%)
| ---------------- | -------- | --------- | --------
| DSP48E1          | 736      | 740       | 99
| Block RAM        | 320 RAMB36 + 2 RAMB18 | 365 RAMB36 | 88
| Slices           | 22,137   | 33,650    | 66
| LUTs             | 45,797   | 134,600   | 34
| Registers        | 60,891   | 269,200   | 23

| Check | Slack
| ----- | -----
| Setup (WNS) | +0.017 ns (TNS 0)
| Hold (WHS)  | +0.010 ns (THS 0)

The "Report Cell Usage" table gave 72,561 LUT cells and 59,785 registers
after synthesis. The run included the HDMI output. The worst setup path of
the main clock was in an iterator, from the register P of its second DSP,
through the adder for x+y or x-y, to the input of its first DSP (3.64 ns,
plus about 3.3 ns in the DSP from its input to its register P). The timing
was met after the routing, but only just (+0.017 ns, within the variation
between runs, see below). The worst hold path (+0.010 ns) was between two
registers of the text of the view (`text` and `text_r` in `view_text`). The
VGA clock had +0.146 ns of setup slack, from the row counter (`pix_y` in
`pix`) to the address of one of the groups of the display memory
(`rd_grp_addr`). The path through the palette had +0.916 ns. The 118 paths
from the MAIN clock to the VGA clock (the frame rate, the view, and their
toggle signal to `cdc_data`, and the palette and its movement from
`controls` to `vga`) had +8.15 ns of slack. The run of `make mega65-r3`,
which read the reset button from the MAX10 (in the clock domain of the
100 MHz input clock, with one more BUFG) and had 52 IOBs, used 21,551 slices
and 45,903 LUTs, and met timing with +0.002 ns, with +0.028 ns of hold slack.
Its VGA clock had +0.241 ns of setup slack, the paths from the MAIN clock to
the VGA clock +7.90 ns, and the input clock (in `max10`) +5.70 ns.

The run of `make mega65-r6` before that, before the keyboard was ignored after
power-on, met timing with +0.008 ns, and had 21,785 slices, 45,783 LUTs, and
60,881 registers (72,549 LUT cells and 59,775 registers after synthesis), and
+0.027 ns of hold slack (in the adder of the row number `res_cy_r` of a job
module). Its VGA clock had +0.153 ns of setup slack (from the column counter
`pix_x` to `rd_grp_blk`), the path through the palette +0.176 ns, and the 118
paths from the MAIN clock to the VGA clock +8.41 ns. The run of
`make mega65-r3` met timing with +0.074 ns, with 21,564 slices, 45,843 LUTs,
+0.028 ns of hold slack, +0.213 ns of setup slack for the VGA clock, and
+5.94 ns for the input clock.

The run of `make mega65-r6` before that, before the design that is the same on
all the boards was moved into `core.vhd` (which adds a level to the
hierarchy, `i_core`), met timing with +0.076 ns, and had 21,603 slices, 45,747
LUTs, and 60,881 registers (72,537 LUT cells and 59,775 registers after
synthesis), and +0.005 ns of hold slack (in the shift register of the keyboard
driver). Its VGA clock had +0.162 ns of setup slack (from the row counter
`pix_y` to `rd_grp_addr`), the path through the palette +0.977 ns, and the
118 paths from the MAIN clock to the VGA clock +8.51 ns. The previous run of
`make mega65-r3` met timing with +0.070 ns, with 21,883 slices, 45,862 LUTs,
+0.058 ns of hold slack, and +0.273 ns of setup slack for the VGA clock.

The run of `make mega65-r6` before that, before the palette could move, met
timing with +0.047 ns, and had 22,223 slices, 45,752 LUTs, and 60,864
registers (72,491 LUT cells and 59,758 registers after synthesis), and
+0.007 ns of hold slack (between two registers of `view_text`). Its VGA clock
had +0.100 ns of setup slack (from the column counter `pix_x` to `rd_grp_blk`
of one of the groups of the display memory), and the 117 paths from the MAIN
clock to the VGA clock +8.33 ns. The previous run of `make mega65-r3` met
timing with +0.091 ns, with 21,792 slices, 45,862 LUTs, +0.025 ns of hold
slack, and +0.160 ns of setup slack for the VGA clock.

The run of `make mega65-r6` before that, before the BRAMs of the display memory
selected the pixel in the word (the read port was 36 bits wide, and each group
selected the pixel with a 32:1 multiplexer for each of 9 bits), and before
three smaller changes (in `fps`, `viewport`, and `disp`), met timing
with +0.041 ns, and had 22,391 slices, 48,336 LUTs, and 60,887 registers
(75,061 LUT cells and 59,781 registers after synthesis), and +0.025 ns of hold
slack. Its VGA clock had +0.162 ns of setup slack, and the 117 paths from the
MAIN clock to the VGA clock +8.71 ns. The previous run of `make mega65-r3` met
timing with +0.070 ns, with 22,347 slices, 48,387 LUTs, +0.025 ns of hold
slack, and +0.163 ns of setup slack for the VGA clock. In those runs the worst
VGA path was from the row counter (`pix_y`) to the read address of one of the
groups (`rd_grp_addr`), and the worst hold path was in the adder of the row
number (`res_cy_r`) of a job module.

The run of `make mega65-r6` before that, before the palettes used all 9 bits
of the count (and had 512 entries instead of 256), met timing with
+0.086 ns, and had 22,151 slices, 48,267 LUTs, and 60,887 registers (75,017
LUT cells and 59,781 registers after synthesis). The worst setup path of the
main clock was in an iterator (3.71 ns, plus about 3.3 ns in the DSP from its
input to its register P), and was met after the routing (+0.085 ns). The
worst hold path (+0.025 ns) was in the adder of the row number (`res_cy_r`)
of a job module. The VGA clock had +0.212 ns of setup slack, from the column
counter (`pix_x` in `pix`) to the number of the block of one of the groups
of the display memory (`rd_grp_blk`), only routing (8.73 ns). The 117 paths
from the MAIN clock to the VGA clock had +7.68 ns of slack. The run of
`make mega65-r3` used 22,231 slices and 48,369 LUTs, and met timing with
+0.066 ns (+0.063 ns after the routing), with +0.022 ns of hold slack (in
`res_cy_r`). Its VGA clock had +0.161 ns of setup slack (from `pix_y` to
`rd_grp_addr`), the paths from the MAIN clock to the VGA clock +8.28 ns, and
the input clock (in `max10`) +5.35 ns.

With the 2.16 iterator the setup slack depended on the placement of the
iterators, and varied by about 0.1 ns between runs. At 144 MHz (1080 MHz
divided by 7.5) it varied from +0.091 to -0.076 ns, and at 148.97 MHz
(divided by 7.25) three runs failed by 0.12 to 0.24 ns, so the main clock was
141.64 MHz, which gave the iterators 0.116 ns more slack than 144 MHz (a
period of 7.060 ns instead of 6.944 ns), for 1.7% fewer pictures per second.
The router left about 19,000 nodes with overlaps after the initial routing,
and resolved them in a few iterations. A complete run took about 13 minutes.
With 320 or 368 job modules the routing also finished without the macros for
the DSPs (the complete runs took 15 and 22 minutes), but then timing failed
by 0.7 and 1.5 ns, because the two DSPs of an iterator were often in
different columns. So the number of job modules was limited by the number of
DSPs, not by the routing. A simulation of a partial picture with `main_tb`
and this design (200 us of simulated time: all 1280 columns, rows 0 to 87,
78,948 pixels, about 14 minutes) gave the same pixels as the model.

The run with the 2.16 iterator before that, before the view was shown in the
top left corner, the palette was selected with the keys `1` to `4`, and the
R3 read the reset button from the MAX10, met timing with +0.070 ns
(+0.069 ns after the routing), and had 21,814 slices, 47,954 LUTs, and
60,294 registers (74,636 LUT cells and 59,188 registers after synthesis).
Its worst setup path was in an iterator (3.57 ns), and its worst hold path
(+0.022 ns) in `res_cy_r`. The VGA clock had +0.219 ns of setup slack (from
`pix_y` to `rd_grp_addr`, only routing, 8.67 ns), and the 40 paths from the
MAIN clock to the VGA clock (the frame rate and its toggle signal) +8.87 ns.
The run of `make mega65-r3`, which did not use the reset button and had 49
IOBs, met timing with +0.033 ns (+0.005 ns after the routing), with 22,031
slices, 47,976 LUTs, and +0.025 ns of hold slack (in `res_cy_r`). Its VGA
clock had +0.165 ns of setup slack, and the paths from the MAIN clock to the
VGA clock +8.82 ns.

The run before that, before the buttons and switches were
synchronized with two registers, the asynchronous inputs were declared as
false paths, and the clock domain crossing of the frame rate was moved to an
entity of its own (fps_cdc.vhd, now the generic cdc_data.vhd), met timing with
+0.059 ns (+0.057 ns after the routing), and had 21,972 slices, 48,004 LUTs,
and 60,288 registers (74,629 LUT cells and 59,168 registers after synthesis).
Its worst hold path (+0.011 ns) was from the result register of a job module
(`res_word_r`) to the register of its group in `dispatcher_results`
(`grp_res_data_r`). The VGA clock had +0.161 ns of setup slack (from `pix_y`
to `rd_grp_addr`, only routing, 8.71 ns of the 9.06 ns), and the paths from
the MAIN clock to the VGA clock +8.88 ns. The run of `make mega65-r3` before
that met timing after the routing, with +0.079 ns, with 22,107 slices,
48,005 LUTs, and +0.024 ns of hold slack (in `res_cy_r`). Its VGA clock had +0.254 ns of
setup slack, and the paths from the MAIN clock to the VGA clock +8.94 ns.

The run of `make mega65-r6` before that, with the reset of the display memory
(see [Display memory](#the-display-memory)), met timing with +0.043 ns
(+0.041 ns after the routing), and had 21,954 slices, 47,950 LUTs, and
60,308 registers (74,653 LUT cells and 59,188 registers after synthesis).
The run before that, also at 141.64 MHz and with the HDMI output, but before
only the BRAM that holds the pixel was read, met timing with +0.004 ns
(+0.002 ns after the routing). The runs before that were at 144 MHz: without
the HDMI output the timing was met only after the post-route
`phys_opt_design` (+0.021 ns, and -0.005 ns after the routing). In the run
before that, without the wait for the display memory after reset, the timing
failed by 0.026 ns, on two endpoints in the same iterator, both after the
routing and after the post-route `phys_opt_design`, and an extra
`phys_opt_design` with `-directive AggressiveExplore` did not change it. The
run before that (before the pictures were only calculated when the view
changes) met timing after the routing (+0.082 ns). This is the variation
between runs described below.

In that run the worst hold path was in the adder of the row number
(`res_cy_r`) of a job module (+0.025 ns), and the worst path of the VGA clock
was from the column counter (`pix_x`) to the number of the block in one of
the groups (`rd_grp_blk`, +0.160 ns). In the earlier runs it was from the
read address of the display memory (`rd_addr`) to the position of the pixel
in the word in one of the groups (`rd_sub_r`, +0.181 ns), or from the row
counter (`pix_y`) to the read address of one of the groups
(`rd_grp_addr`), also almost only routing.

The run of `make mega65-r3` before that, with the reset of the display memory,
met timing with +0.090 ns, but only after the post-route `phys_opt_design`
(-0.108 ns after the routing), with 22,023 slices and +0.026 ns of hold slack.
The run before that, at 144 MHz and without the HDMI output, failed by 0.076
ns (TNS -0.191 ns, 6 endpoints, in an iterator, and -0.078 ns after the
routing), and the run before that, without the wait for the display memory
after reset, met timing with +0.010 ns.

**The main clock.** The setup slack depends on the placement of the iterators,
and varies by about 0.1 ns between runs: four runs with 368 job modules at 144
MHz, with small differences in the design or in the directive of the
placement, all met timing, with +0.002 to +0.091 ns (the same design, except
for the counter for the updates of the view in `main.vhd`, gave +0.091 ns).
The design where the pictures are only calculated when the view changes (which
adds the clock enable of the DSPs, and the comparison of the view in
`main.vhd`) gave +0.010 ns on the R3 and -0.026 ns on the R6. With the wait
for the display memory after reset added (one more input to the start of a
picture), the next runs gave -0.076 ns on the R3 and +0.021 ns on the R6, and
the slack of the Nexys 4 DDR went from +0.026 to -0.001 ns. At 148.97 MHz
(1080 MHz divided by 7.25) three runs failed by 0.12 to 0.24 ns, and at 146.44
MHz (divided by 7.375) one run met timing (+0.009 ns) and one failed (-0.030
ns). Because the slack at 144 MHz varied from +0.091 to -0.076 ns, the main
clock is now 141.64 MHz (divided by 7.625), which gives the iterators 0.116 ns
more slack (a period of 7.060 ns instead of 6.944 ns), for 1.7% fewer pictures
per second. The runs at 141.64 MHz (with the HDMI output) have all met timing:
+0.004 ns on the R6 before only the BRAM that holds the pixel was read, +0.043
ns on the R6 and +0.090 ns on the R3 after, and +0.059 ns on the R6 and +0.079
ns on the R3 without the reset of the display memory, and +0.070 ns on the R6
and +0.033 ns on the R3 after the buttons were synchronized with two
registers.

The MEGA65 was added after the design had been developed on the Nexys 4 DDR
(see [Builds of the Nexys 4 DDR](#builds-of-the-nexys-4-ddr)).
It first showed 640x480 like the Nexys 4 DDR, then 800x600, and then
1280x1024, first with the iterator with a single DSP, and then with two DSPs.
The paragraphs below go back in time, starting with the latest change.

**Two DSPs in each iterator.** With the iterator with a single DSP, the
design had 256 job modules and a 148.97 MHz main clock. A run of
`make mega65-r6` gave 19,316 slices (57%), 49,253 LUTs, and 52,144 registers
(78,846 LUT cells and 52,172 registers after synthesis), +0.301 ns of setup
slack and +0.045 ns of hold slack. The worst paths were long routes with no
logic: from the data register of a group of the display memory to one of its
BRAMs, from the registers of a group in the dispatcher to the job modules,
and (in the VGA clock domain) from the pixel counter to the copies of the
read address in the groups. The router first left 10,000 to 14,000 nodes
with overlaps, and the routing took 10 to 61 minutes in different runs of the
same design (once only meeting timing after the post-route
`phys_opt_design`, with +0.002 ns). With 450 job modules the router left
29,614 overlaps, and did not finish within an hour. The model gave 732009
clock cycles for the initial view (4.91 ms, 203 pictures per second).

The iterator with two DSPs was first built out of context (only the iterator),
where its first version used 74 LUTs and 47 registers (against 129 and 87; the
current version uses 70 LUTs, see [Iterator](ALGORITHM.md#iterator)), and its
longest path needed 6.45 ns. In the whole design with 256 job modules the
routing took a few minutes, but timing failed by 0.64 ns: the placer put the
two DSPs of many iterators in different columns of DSPs, and the route from
one to the other took 1.8 ns. The relatively placed macros (in
`mandelbrot.tcl`) fixed this; the first attempt placed the DSPs five sites
apart, because the relative locations of `update_macro` count DSP sites, not
the coordinates of the RPM grid (where two DSPs next to each other are 5
apart). With the DSPs next to each other the setup slack was -0.047 ns at
148.97 MHz with 256 job modules, and -0.138 ns with 368, all of it in the
iterators. The routes of the dispatcher and the display memory were no longer
a problem. The constants cx and cy/2 were then registered in the DSPs (the
register C): with 368 job modules the paths from the job modules to the input
C had failed by up to 0.86 ns in a run without the macros.

Two other changes to the longest path did not help in the whole design,
although they did out of context, so they were not kept:
* Writing the carry into the adders as an extra lowest bit, so that it goes
  through a LUT of the carry chain instead of the input CYINIT. Vivado still
  used CYINIT, and the path was only 0.07 ns shorter out of context.
* Taking the sign bits of x and y, which decide the carry into the adders
  and go to more than 40 inputs each, from the unused top bits of the
  registers P (bits 36 to 47 are copies of bit 35, and when x and y are in
  range, of their sign bits too). Out of context the path was 0.15 ns
  shorter, but in the whole design the median slack of the iterators did not
  improve (the route from a DSP to the fabric takes about 0.9 ns, also with
  fewer loads), and Vivado merged some of the copies again.

**1280x1024.** The main clock was 187.83 MHz (1080 MHz divided by 5.75) at
first, but with 450 job modules it failed timing by about 0.15 ns after the
placement, and the slices were 92% used. Leaving out the registers of the
write port of each block (about 15,000 registers) and lowering the main clock
to 180 MHz still left one path failing by 0.247 ns, so the main clock was
lowered to 148.97 MHz, and then the number of job modules (see
[MEGA65](ALGORITHM.md#mega65)). The registers of the read address in each group
were added when the VGA clock had only +0.207 ns of setup slack with 64 job
modules: the route from the pixel counters to all 320 BRAMs took 8.2 ns of
the 9.26 ns. With them the slack was +0.620 ns.

**800x600.** The 800x600 design used 450 job modules with a 188.24 MHz main
clock (1200 MHz divided by 6.375), and a display memory of 2^19 pixels (128
BRAMs), where each picture column had 600 addresses. A run of
`make mega65-r6` gave 29,964 slices (89%), 81,646 LUTs, 93,443 registers,
+0.186 ns of setup slack and +0.013 ns of hold slack. After synthesis there
were 107,980 LUT cells and 93,411 registers. The worst setup path was in the
tree of registers of the display memory (from the data register to the
register of a group), and the worst hold path was from the data register of a
block of the display memory to its BRAM. The VGA clock had +6.7 ns of setup
slack (of 25 ns). The run took about 14 minutes (synthesis 4.5 minutes,
placement 4.5 minutes, routing 3 minutes).

The first build with 800x600 failed timing by 0.226 ns, from the table
`job_addr_r` (a BRAM) through the multiplication by 600 in the dispatcher, and
used a DSP for the multiplication in `vga`, because Vivado ignored the
attribute `use_dsp` on the sum. The multiplication was moved one clock cycle
later (see [Dispatcher](ALGORITHM.md#dispatcher)), and the attribute put on
the product. The 800x600 picture costs about the same resources as 640x480 did
(30,114 slices, 81,630 LUTs, 93,491 registers, and +0.136 ns of setup slack).
A run of `make nexys4ddr` with the same version (still 640x480) gave +0.009 ns
of setup slack (in an iterator) and +0.021 ns of hold slack, with 14,790
slices, 42,131 LUTs, and 46,431 registers. Two earlier runs of it stopped with
a segmentation fault in Vivado (in the routing and in the `phys_opt_design`
after it), which also happened once before with `make mega65-r6`; running it
again helped.

With 800x600 (480,000 pixels, 56% more than 640x480), the model gave 248969
clock cycles for the initial view, i.e. 1.32 ms (about 756 pictures per
second). With one pixel in each write it would be 512370 clock cycles
(2.72 ms), and with two 299485 (1.59 ms). Even if every pixel needed the
maximum count, the picture would take 1663271 clock cycles (8.8 ms). A
simulation of a complete 800x600 picture with `main_tb` took about 248920
clock cycles from the start to the last write to the display memory, 0.02%
less than the model, with all the pixels the same as in the model. The
simulation took about 1.5 hours.

**640x480.** Before 800x600, the MEGA65 showed 640x480 like the Nexys 4 DDR.
With one pixel in each write, the model gave 339741 clock cycles for the
initial view with 450 job modules, i.e. 1.80 ms at 188.24 MHz (about 554
pictures per second), only 2% faster than with 240 job modules. The display
memory was then written in 90% of the clock cycles, so the time for the
picture was decided by the write port of the display memory (at least 307200
clock cycles, see [Timing](#timing)), not by the number of job modules. With
four pixels in each write, the model gave 161909 clock cycles, i.e. 0.86 ms
(about 1163 pictures per second), 2.1 times faster. This cost 16,165
registers (27 bits in each job module for the counts of the first three
rows, and the wider data in the dispatcher and in the tree of registers of
the display memory), 4,050 LUTs, and 3,881 slices, against the build with
one pixel in each write. The setup slack was +0.178 ns and the hold slack
+0.023 ns with one pixel in each write.

## Builds of the Nexys 4 DDR
The current results are in [Nexys 4 DDR](ALGORITHM.md#nexys-4-ddr). The runs
before them go back in time, starting with the latest one.

The previous run of `make nexys4ddr`, before stepy was registered in each
iterator, used 9,694 slices (61%), 20,567 LUTs, and 29,821 registers, and
all 234 DSPs of the 39 job modules. It met timing with +0.308 ns, with
+0.007 ns of hold slack. The worst setup path was in an iterator, from its
clock enable (`run_r`) to y\_r, mostly routing (6.94 ns of 7.46 ns). The 115
paths from the MAIN clock to the VGA clock had +7.91 ns of slack.

The run before that, the last one with the 2.16 iterator
(see [The 2.16 iterator](#the-216-iterator)) and 120 job modules, on main
before the wide iterator was rebased onto it, used 9,294 slices (59%), 15,838
LUTs, and 27,260 registers (20,160 LUT cells and 27,276 registers after
synthesis), and all 240 DSPs. It met timing with +0.090 ns (after the
routing), with +0.014 ns of hold slack (from the data register of a block of
the display memory to its BRAM). The worst setup path was in an iterator,
from the register P of its first DSP, through the adder for x+y or x-y (a LUT
and five CARRY4), to the input of its first DSP. The 115 paths from the MAIN
clock to the VGA clock had +8.55 ns of slack.

The run of `make nexys4ddr` with the 2.16 iterator on the branch of the wide
iterator, before it was rebased onto the design that is the same on all the
boards in `core.vhd`, the moving palette, the palettes with all 9 bits of the
count, and the BRAMs that select the pixel in the word (the design of the
Nexys 4 DDR was the same, but the number format was a generic), used 9,288
slices, 16,836 LUTs, and 27,276 registers (21,135 LUT cells and 27,292
registers after synthesis). It met timing with +0.028 ns (+0.004 ns after the
routing), with +0.007 ns of hold slack. The worst setup path was in an
iterator, from the register P of its second DSP. The 115 paths from the MAIN
clock to the VGA clock had +8.14 ns of slack.

The run of `make nexys4ddr` before that, before the design that is the same on
all the boards was moved into `core.vhd`, met timing with +0.046 ns, with
9,269 slices, 15,846 LUTs, 27,260 registers (20,160 LUT cells and 27,276
registers after synthesis), and +0.006 ns of hold slack. The 115 paths from the
MAIN clock to the VGA clock had +8.08 ns of slack.

The run of `make nexys4ddr` before that, before the palette could move, met
timing with +0.034 ns, with 10,391 slices, 15,844 LUTs, 27,246 registers
(20,119 LUT cells and 27,262 registers after synthesis), and +0.015 ns of
hold slack. The 115 paths from the MAIN clock to the VGA clock had +8.18 ns
of slack.

The run of `make nexys4ddr` before that, before the BRAMs of the display memory
selected the pixel in the word (and the three smaller changes), met timing with +0.051 ns, with 9,352 slices,
16,859 LUTs, 27,276 registers (21,171 LUT cells and 27,292 registers after
synthesis), and +0.006 ns of hold slack. The 115 paths from the MAIN clock to
the VGA clock had +8.14 ns of slack.

The run of `make nexys4ddr` before that, before the palettes used all 9 bits of
the count, met timing with +0.004 ns (+0.003 ns after the routing), with
9,352 slices, 16,815 LUTs, 27,276 registers (21,127 LUT cells and 27,292
registers after synthesis), and +0.010 ns of hold slack. The 115 paths from
the MAIN clock to the VGA clock had +8.50 ns of slack. A run of the wide
iterator before it was rebased onto the view in the top left corner used
9,132 slices, 16,512 LUTs, and 26,690 registers, and met timing with
+0.010 ns (+0.000 ns after the routing) and +0.007 ns of hold slack, and the
40 paths from the MAIN clock to the VGA clock had +8.16 ns of slack.

The run of `make nexys4ddr` before that, before the view was shown in the top
left corner, used 10,217 slices (64%), 16,510 LUTs, and 26,690 registers
(20,752 LUT cells and 26,706 registers after synthesis). It met timing with
+0.037 ns (+0.016 ns after the routing), with +0.050 ns of hold slack (from
the data register of a block of the display memory to its BRAM), and the
40 paths from the MAIN clock to the VGA clock had +8.35 ns of slack. The
worst setup path was the same as now, in an iterator.

The run of `make nexys4ddr` before that, before the buttons and switches were
synchronized with two registers and the asynchronous inputs were declared as
false paths, used 10,069 slices (64%), 16,533 LUTs, and 26,684 registers
(20,752 LUT cells and 26,686 registers after synthesis). It met timing with
+0.059 ns, only after the post-route `phys_opt_design` (-0.002 ns after the
routing), with +0.008 ns of hold slack, and the paths from the MAIN clock to
the VGA clock had +8.42 ns of slack.

The run of `make nexys4ddr` before that, with the reset of the display memory
(see [The display memory](#the-display-memory)), used 9,225 slices (58%),
16,539 LUTs, and 26,702 registers: almost the same logic, packed into fewer
slices.

That run, with the reset of the display memory,
met timing with +0.015 ns, also only after the post-route `phys_opt_design`
(-0.067 ns after the routing). The run before that, before only the BRAM that
holds the pixel was read (see [The display memory](#the-display-memory)),
failed by 0.001 ns, on one endpoint in an iterator, after the post-route
`phys_opt_design` (-0.026 ns after the routing). The run before that, without
the wait for the display memory after reset, met timing with +0.026 ns, but
only after the post-route `phys_opt_design` (-0.129 ns after the routing), and
so did the run before the pictures were only calculated when the view changes
(+0.032 ns, and -0.021 ns after the routing).

The design was first developed on the Nexys 4 DDR, so most parts of the
design were added and measured here, before the MEGA65 was added (see
[Builds of the MEGA65](#builds-of-the-mega65)).

**Two DSPs in each iterator.** Before the iterator with two DSPs (see
[Iterator](ALGORITHM.md#iterator)), the design had 240 job modules with one
DSP each, one pixel in each write, and a 150 MHz main clock. A run of `make
nexys4ddr` gave 14,407 slices (91%), 42,037 LUTs, and 43,610 registers (55,903
LUT cells and 43,628 registers after synthesis), +0.345 ns of setup slack and
+0.017 ns of hold slack. The worst setup path was a route from the registers
of a group in the dispatcher (`grp_cx_r`) to a job module (`res_cx_r`). The
model gave 347123 clock cycles for the initial view (2.31 ms, 432 pictures per
second). With the iterator with two DSPs there are only 120 job modules, and
the main clock is 120 MHz (the iterators are the longest paths, and they are
slower in speed grade -1), but the job modules use only half of the slices, so
there is room for four pixels in each write, and the picture is 1.93 times as
fast, see [Timing](#timing).

**What the parts of the design cost.** Most parts of the design were added one
at a time, and each was measured against the build before it:
* The periodicity detection (see [Iterator](ALGORITHM.md#iterator)) uses about
  5,500 LUT cells and 8,900 registers (36 registers for the saved values in
  each iterator), and increased the slices used from 81% to 93%. A first
  version, which cleared the saved values at the start of each point, used
  about 4,100 LUT cells more.
* Before the post-adder of the DSP was used (see
  [Multiplier](ALGORITHM.md#multiplier)), the design used 61,895 LUT cells and
  53,885 registers after synthesis, and 49,087 LUTs, 53,960 registers, and
  15,402 slices (97%) after routing. The timing slack was about the same
  (+0.116 ns), because the critical paths were not in the iterators.
* The registers that shorten the routes to the job modules and to the BRAMs
  (see [Dispatcher](ALGORITHM.md#dispatcher) and [Display
  memory](ALGORITHM.md#display-memory)) use about 4,600 registers and 500 LUT
  cells. Before they were added, the setup slack was +0.104 ns.
* Pipelining the next row in the job modules, the schedulers, and the done
  flag (see [Dispatcher](ALGORITHM.md#dispatcher)) costs about 700 LUT cells
  and 300 registers.
* The frame rate on the 7-segment display (see [Frame
  rate](ALGORITHM.md#frame-rate)) uses about 170 LUT cells and 180 registers.
* The scheduler for the results (see [Dispatcher](ALGORITHM.md#dispatcher))
  uses about 1,000 LUT cells more than the round-robin scheduler did. Before
  it, the design used 54,492 LUT cells and 42,708 registers after synthesis,
  and 41,284 LUTs, 44,562 registers, and 14,641 slices (92%) after routing,
  with a setup slack of +0.103 ns.
* The jobs of 120 rows (see [Dispatcher](ALGORITHM.md#dispatcher)) did not use
  more resources: before them, the design used 55,536 LUT cells and 43,656
  registers after synthesis, and 42,158 LUTs, 46,314 registers, and 14,764
  slices (93%) after routing, with a setup slack of +0.045 ns. The job modules
  need fewer bits for the row (7 instead of 9), which saves more than the
  dispatcher needs for the blocks.
* The frame rate overlay on the VGA output (see
  [Overlay](ALGORITHM.md#overlay)) uses about 100 LUT cells and 130 registers
  after synthesis, and no block RAM (the font table is in LUTs).
* Registering the ready flags in the scheduler for the results (see
  [Dispatcher](ALGORITHM.md#dispatcher)) uses about 240 registers more (one
  for each job module).
* The registers of the read address in each group of 8 blocks of the display
  memory (see [Display memory](ALGORITHM.md#display-memory)) use about 400
  registers, against the build before them (14,508 slices, 42,035 LUTs, and
  43,217 registers, with +0.355 ns of setup slack).

**The main clock.** The main clock was originally 150 MHz. The design with the
earlier version of the iterator met timing at that frequency (setup slack
+0.047 ns). After the overflow detection in the iterator was improved (see
[Overflow](ALGORITHM.md#overflow)), which uses more logic (about 1,400 more
LUTs), the design no longer met timing at 150 MHz (setup slack -0.055 ns, with
the critical paths in the dispatcher), and the main clock was lowered to
140.625 MHz. After the post-adder of the DSP was used and the registers in the
groups and the blocks were added, the design met timing at 140.625 MHz with
+0.342 ns of slack. The same design was then built for higher frequencies, by
changing only the MMCM:

| Main clock | Setup slack | Main clock | Setup slack
| ---------- | ----------- | ---------- | -----------
| 143.75 MHz | +0.274 ns   | 162.71 MHz | +0.129 ns
| 146.88 MHz | +0.131 ns   | 165.52 MHz | +0.125 ns
| 150.00 MHz | +0.187 ns   | 168.42 MHz | +0.046 ns
| 152.38 MHz | +0.237 ns   | 171.43 MHz | +0.018 ns
| 154.84 MHz | +0.160 ns   | 174.55 MHz | +0.094 ns
| 157.38 MHz | +0.058 ns   | 177.78 MHz | +0.004 ns
| 160.00 MHz | +0.093 ns   | 181.13 MHz | -0.099 ns

The slack does not decrease steadily with the frequency, because the tools
work harder when the timing is tighter, and the result of each run varies by
about 0.1 ns. Above 174.55 MHz the result depends on luck: 177.78 MHz (and
184.62 MHz) met timing by a few picoseconds, after the post-route physical
optimization, but 181.13 MHz did not. So the main clock was raised to
174.55 MHz, which is 24% faster than 140.625 MHz.

A later build had a setup slack of +0.229 ns at 174.55 MHz, instead of
+0.094 ns, so the frequency was tried again:

| Main clock | Setup slack | Hold slack
| ---------- | ----------- | ----------
| 177.78 MHz | +0.081 ns   | +0.012 ns
| 181.13 MHz | +0.040 ns   | +0.014 ns
| 184.62 MHz | +0.020 ns   | +0.021 ns
| 188.24 MHz | +0.003 ns   | +0.000 ns
| 192.00 MHz | -0.061 ns   | +0.007 ns

The main clock was raised to 177.78 MHz, which has about the same slack as
174.55 MHz had before.

Then the next row in the job modules, the schedulers, and the done flag were
pipelined, and the frequency was tried again:

| Main clock | Setup slack | Hold slack
| ---------- | ----------- | ----------
| 188.24 MHz | +0.027 ns   | +0.016 ns
| 192.00 MHz | +0.064 ns   | +0.014 ns
| 195.92 MHz | +0.132 ns   | +0.014 ns
| 200.00 MHz | +0.003 ns   | +0.021 ns
| 204.26 MHz | +0.001 ns   | +0.051 ns
| 208.70 MHz | -0.075 ns   | +0.014 ns

The main clock was raised to 195.92 MHz, which has more slack than the
frequencies just below and above it.

The periodicity detection then dropped the slack at 195.92 MHz to
+0.004 ns. With the detection:

| Main clock | Setup slack | Hold slack
| ---------- | ----------- | ----------
| 188.24 MHz | +0.088 ns   | +0.017 ns
| 192.00 MHz | +0.029 ns   | +0.016 ns
| 195.92 MHz | +0.004 ns   | +0.014 ns

So the main clock was lowered to 188.24 MHz, which has about the same slack as
the earlier choices. This is 4% slower than 195.92 MHz, but the detection
makes the picture 1.75 times faster. The main clock is 34% faster than
140.625 MHz.

The next builds at 188.24 MHz had these setup slacks:
* With the frame rate on the 7-segment display: +0.045 ns. The difference from
  +0.088 ns is the normal variation from one run to the next; the critical
  paths are the same.
* With the jobs of 120 rows: +0.103 ns.
* With the scheduler for the results: +0.037 ns.
* With the frame rate overlay on the VGA output: +0.006 ns. The worst path is
  in `viewport` (from `zoomx` to the clock enable of `dy`), which the overlay
  does not change, so this is the variation from one run to the next. The 40
  paths from the MAIN clock to the VGA clock had +8.19 ns of slack against the
  maximum delay of 10 ns, and `report_cdc` reports all of them as safe.
* With the ready flags registered in the scheduler for the results: +0.064 ns.
  The paths from the MAIN clock to the VGA clock then had +8.41 ns of slack.
* With the synchronizer for the frame rate moved from `overlay` to the top
  level: +0.092 ns. This is the same logic, and the cell counts after
  synthesis did not change. The 40 paths from the MAIN clock to the VGA clock
  had +8.39 ns of slack, and were all reported as safe by `report_cdc`.

The main clock of the Nexys 4 DDR was then lowered from 188.24 MHz to 150 MHz
(1200 MHz divided by 8 instead of 6.375), and the MEGA65 kept 188.24 MHz
(until it got 1280x1024 and 148.97 MHz, see
[Builds of the MEGA65](#builds-of-the-mega65)). Even if
every pixel needed the maximum count, the model gives 2040977 clock cycles for
the picture, i.e. 73 pictures per second at 150 MHz, still well above the
60 Hz of the VGA output. The setup slack rose from +0.092 ns to +0.355 ns,
which leaves room for more logic. The aim was a faster build, but the build
took the same time as before: the run time is decided by the directives in
`mandelbrot.tcl`, not by the slack. Only the two runs of `phys_opt_design` do
nothing now, because timing is already met, and they took only about 10
seconds before.

The display memory then got a register of the read address in each group of
8 blocks (for the MEGA65 at 1280x1024), which makes the read latency four
clock cycles. The build with them had +0.343 ns of setup slack, with the
worst path of the same kind, and the 40 paths from the MAIN clock to the VGA
clock were all reported as safe by `report_cdc`. A later run with the same
cell counts after synthesis gave the current results above (+0.345 ns).

**Critical paths at higher frequencies.** With the iterator with a single
DSP, at 188.24 MHz, the critical paths were in the iterators, and in the job
modules around them (the registers named here are those of that iterator):
* From the output of the DSP (which was not registered in that iterator) to
  the overflow flags.
* From x\_r and y\_r through the additions x+y and x-y and the selection of
  the inputs of the multiplier to the input registers of the DSP, with 6 or 7
  levels of logic.
* The acknowledge of the results (`res_ack_r`) to the row in the job
  modules, and the routes from the registers in the groups to the job
  modules.
* The state machine of the iterator (from cnt\_r and state\_r), and the
  periodicity detection (to match\_r and the saved values).
* The scheduler for the results: the round-robin selection in a group, from
  the registered ready flags (`req_r`) to the candidate of the group
  (`cand_r`), with 5 levels of logic. This was the worst path in the last
  build at 188.24 MHz (+0.092 ns). Before the ready flags were registered, the
  path started at the acknowledge (`res_ack_r`) in the dispatcher, with 6
  levels of logic, and had +0.037 ns of slack.
* The next row in the job modules (to `res_cy_r`, whose clock enable
  depends on the result of the iterator).

To go faster, that iterator would have had to be changed, e.g. by
registering the output of the DSP, which would have changed the three clock
cycles of an iteration. The iterator with two DSPs registers the output of
the DSPs (the P registers are x and y), but not their inputs, see
[Iterator](ALGORITHM.md#iterator).

At 177.78 MHz, before the next row in the job modules, the schedulers, and the
done flag were pipelined (see [Dispatcher](ALGORITHM.md#dispatcher)), these
were the critical paths, with up to 22 levels of logic (the done flag).

At 140.625 MHz, the critical paths were first the routes from single registers
to all 240 job modules (the job, the reset, and the index of the job
module whose result is accepted) or to all 128 BRAMs (the write address),
before the registers in the groups and the blocks were added, and before that
the selection of the job module in the schedulers, and the iterators (from
the multiplier through the addition of cx to x\_r, before the post-adder of
the DSP was used).

## Power
The current estimates are in [Power](ALGORITHM.md#power).

The previous runs of the MEGA65, at 180 MHz and before stepy was registered in
each iterator, gave 3.53 W busy and 0.86 W idle on the R6, of which `main`
used 2.82 W and 0.34 W, and the display memory 0.22 W and 0.05 W (3.53 W and
0.85 W on the R3). Their busy power was mostly the DSPs (1.21 W), the signals
(0.90 W), the logic (0.50 W), and the clocks (0.46 W). The previous run of the
Nexys 4 DDR, with the wide iterator and before stepy was registered, gave
1.09 W busy and 0.38 W idle, of which `main` used 0.74 W and 0.11 W, and the
display memory 0.11 W and 0.03 W.

The run of the Nexys 4 DDR before that, the last one with the 2.16 iterator
(120 job modules), on main before the wide iterator was rebased onto it, gave
1.20 W busy and 0.36 W idle, of which `main` used 0.82 W and 0.08 W, and the
display memory 0.13 W and 0.03 W. The run with the 2.16 iterator on the
branch of the wide iterator, before the rebase, gave the same totals.

The previous runs, where the last DSPs of the wide iterator had their inputs
registered twice instead of using the register M (and the picture on the
board was wrong), gave 3.56 W busy and 0.86 W idle on the R6, of which
`main` used 2.86 W and 0.34 W, and the display memory 0.22 W and 0.05 W
(3.57 W and 0.85 W on the R3). Their busy power was mostly the DSPs
(1.25 W), the signals (0.90 W), the logic (0.50 W), and the clocks (0.46 W).

The runs before those, with the wide iterator on the MEGA65, before it was
rebased onto the view in the top left corner, the palette selected with the
keys, and the R3 reading the reset button from the MAX10, gave 3.57 W busy
and 0.86 W idle on the R6, of which `main` used 2.81 W and 0.34 W, and the
display memory 0.22 W and 0.05 W (3.54 W and 0.84 W on the R3). Their busy
power was mostly the DSPs (1.25 W), the signals (0.91 W), the logic
(0.50 W), and the clocks (0.46 W). The run of the Nexys 4 DDR gave 1.19 W
busy and 0.36 W idle, of which `main` used 0.82 W and 0.08 W.

The runs before those, with the wide iterator on the MEGA65, before the reset
of the display memory was removed and the buttons and switches were
synchronized with two registers, gave 3.50 W busy and 0.85 W idle on the R6,
of which `main` used 2.84 W and 0.33 W, and the display memory 0.18 W and 0.05
W (3.50 W and 0.85 W on the R3). Their busy power was mostly the DSPs (1.25
W), the signals (0.86 W), the logic (0.50 W), and the clocks (0.44 W), and the
idle power the clocks (0.36 W).

The runs before those, the last ones of the MEGA65 with the 2.16 iterator (368
job modules at 141.64 MHz, with the HDMI output, the design that is the same
on all the boards in `core.vhd`, the moving palette, and the keyboard ignored
after power-on), gave 3.53 W busy and 0.74 W idle on the R6, of which `main`
used 2.87 W and 0.21 W, and the display memory 0.16 W and 0.04 W (3.49 W and
0.74 W on the R3). While a button was held down, the design was busy for
about 4.6% of the time on the MEGA65. The busy power was mostly the DSPs
(1.19 W), the signals (1.05 W), and the logic (0.54 W), almost all in the job
modules. The idle power was mostly the clocks (0.25 W), the I/O (0.17 W, the
VGA and HDMI outputs), the static power (0.16 W), and the MMCM (0.13 W). The
block RAM used 0.004 W, and the signals 0.02 W.

The runs before that, before the keyboard was ignored after power-on, gave
3.47 W busy and 0.73 W idle on the R6 (3.49 W and 0.74 W on the R3). The
Nexys 4 DDR was not built again, because it does not read the keyboard.

The runs before that, before the design that is the same on all the boards was
moved into `core.vhd`, gave 3.47 W busy and 0.73 W idle on the R6 (3.50 W and
0.74 W on the R3), and 1.20 W busy and 0.36 W idle on the Nexys 4 DDR.

The runs before that, before the palette could move, gave 3.52 W busy and 0.74 W
idle on the R6 (3.51 W and 0.74 W on the R3), and 1.22 W busy and 0.36 W idle
on the Nexys 4 DDR.

The runs before that, before the BRAMs of the display memory selected the
pixel in the word, gave 3.51 W busy and 0.75 W idle on the R6 (3.53 W and
0.75 W on the R3), and 1.20 W busy and 0.36 W idle on the Nexys 4 DDR. Of the
idle power on the R6, the display memory used 0.05 W.

The runs before that, before the view was shown in the top left corner, the
palette was selected with the keys, and the R3 read the reset button from the
MAX10, gave 3.47 W busy and 0.74 W idle on the R6 (3.51 W and 0.74 W on the
R3), and 1.22 W and 0.36 W on the Nexys 4 DDR. Of the busy power on the R6,
the main clock domain used 2.82 W, and the signals 0.98 W.

The runs before that, before the buttons were synchronized with two registers,
gave 3.53 W busy and 0.74 W idle on the R6 (3.48 W and 0.74 W on the R3), and
1.21 W and 0.36 W on the Nexys 4 DDR. Their busy power on the MEGA65 had
1.04 W in the signals. The runs before those, with the reset of the display
memory, gave about the same: 3.50 W and 0.74 W on the R6 (3.54 W
and 0.75 W on the R3), and 1.20 W and 0.37 W on the Nexys 4 DDR.

Before only the BRAM that holds the pixel was read, the read port of the
display memory read all 320 BRAMs in every clock cycle of the VGA clock
(108 MHz), although only one of them holds the pixel. The run before that,
of the MEGA65 R6 (at 141.64 MHz, with the HDMI output), gave 4.43 W busy and
1.66 W idle, of which the display memory used 1.05 W and 0.96 W, and the
block RAM 0.71 W. Now the read enable of a BRAM is only high when it holds
the pixel, so it reads in at most 1 of 320 clock cycles (the vectorless
estimate gives each read enable a static probability of 1/512, i.e. that the
9 bits of the number of the block are equal to the number of the BRAM), and
the outputs of the other BRAMs keep their values. This saved 0.92 W both
busy and idle, so the idle power is less than half: 0.71 W in the block RAM,
and the rest in the signals (0.18 W before and 0.02 W now, while idle) and
the logic (0.06 W and 0.02 W), because the outputs of all the BRAMs changed
in every clock cycle, and with them the multiplexers that select the pixel.
On the Nexys 4 DDR, with 128 BRAMs and a 25 MHz VGA clock, it saved less:
the run before that gave 1.27 W busy and 0.45 W idle, with 0.07 W in the block
RAM (now 0.003 W). Before a picture was only calculated when the view
changes, the MEGA65 R6 gave 4.33 W with the default activity (at 144 MHz,
without the HDMI output), but it was busy all the time.
