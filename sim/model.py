#!/usr/bin/env python3

# Vectorized (numpy) bit-accurate model of the picture calculated by the
# design, and a reference calculated using real (floating point) numbers.
#
# hw_count() follows src/main/iterator.vhd (2.16 fixed point, like
# iterator_model.py, but for many points at once) or src/main/iterator_wide.vhd
# (2.33 fixed point), and view() gives the values of c for each pixel,
# calculated in the same way as src/main/main.vhd, src/main/viewport.vhd,
# src/main/dispatcher.vhd and src/main/job.vhd (or job_wide.vhd). This module is
# used by cmp_rtl.py to compare the simulated design with the model.
#
# Run as a script, it compares the model with the reference for the initial
# view (1280x1024, as on the MEGA65), and prints how many pixels differ. It
# also estimates the time it takes the design to calculate the picture, and
# the time the job modules wait for their results to be accepted, see
# picture_cycles(). The same is done for the initial view on the Nexys 4 DDR
# (640x480, with 2.16 fixed point and the maximum count 511). For the times,
# hw_stop() follows the periodicity detection of the iterator, which stops the
# iteration early for most points in the set, and checks that it gives the same
# count as hw_count().
#
# Usage:
#   ./model.py           Compare the model with the reference.
#   ./model.py --png     Same, and write the pictures to model.png and ref.png
#                        (requires Pillow), using the same colours as the VGA
#                        output.
#
# Requires numpy.

import heapq
import sys
from typing import List
from typing import Optional
from typing import Tuple

import numpy as np
from numpy.typing import ArrayLike
from numpy.typing import NDArray

# Arrays of integers (e.g. 2.16 fixed point numbers or counts), real numbers,
# and booleans
IntArray = NDArray[np.int64]
RealArray = NDArray[np.float64]
BoolArray = NDArray[np.bool_]

MAX_COUNT = 1023     # Must match C_MAX_COUNT in mega65.vhd
FRAC_BITS = 33       # Must match C_FRAC_BITS in mega65.vhd
NUM_COLS  = 1280     # Must match C_VIDEO in mega65.vhd
NUM_ROWS  = 1024     # Must match C_VIDEO in mega65.vhd
ROWS_IN_JOB = 64     # Must match C_ROWS_IN_JOB in mega65.vhd
NUM_ITERATORS = 120  # Must match C_NUM_ITERATORS in mega65.vhd
PIXELS = 4           # Must match C_PIXELS in mega65.vhd
GROUP_SIZE = 16      # Must match G_GROUP_SIZE in dispatcher.vhd
MAIN_CLOCK_KHZ = 100e3 / 5 * 54 / 6.0   # Must match C_MAIN_DIVIDE in mega65.vhd
# The same for the Nexys 4 DDR, see nexys4ddr.vhd
NEXYS4DDR_MAX_COUNT = 511
NEXYS4DDR_FRAC_BITS = 16
NEXYS4DDR_NUM_COLS = 640
NEXYS4DDR_NUM_ROWS = 480
NEXYS4DDR_ROWS_IN_JOB = 120
NEXYS4DDR_NUM_ITERATORS = 120
NEXYS4DDR_PIXELS = 4
NEXYS4DDR_MAIN_CLOCK_KHZ = 1200e3 / 10.0   # Must match C_MAIN_DIVIDE in nexys4ddr.vhd

# The size of the real axis of the initial view, see main.vhd
SIZE_X = 8.0 / 3.0

# The lowest 17 bits of a number, see iterator_wide.vhd
LOW_BITS = (1 << 17) - 1


def wrap(v: ArrayLike, bits: int) -> IntArray:
    """Interpret the lowest 'bits' bits of v as two's complement numbers."""
    m = 1 << bits
    low: IntArray = np.asarray(v, dtype=np.int64) & (m - 1)
    return np.where(low >= m >> 1, low - m, low)


def wide_iteration(x: IntArray, y: IntArray, cx: IntArray,
                   cy: IntArray) -> Tuple[IntArray, IntArray]:
    """One iteration of src/main/iterator_wide.vhd, for 2.33 fixed point
    numbers (35-bit signed integers). Returns the new values of x and y, before
    they are truncated to 35 bits. The products are calculated as in the DSPs
    (see p_dsp in iterator_wide.vhd), without the product of the low parts, so
    they fit in 64 bits. Half an LSB is added by the bits 15 (14 for y) of the
    registers P of the second DSP. The result does not depend on which of x+y
    and x-y is called a."""
    a = x + y
    b = x - y
    p2 = (a & LOW_BITS) * (b >> 17) + (a >> 17) * (b & LOW_BITS)
    p3 = (p2 >> 17) + (a >> 17) * (b >> 17)
    new_x = 2 * p3 + ((p2 >> 16) & 1) + ((p2 >> 15) & 1) + cx
    p5 = (x & LOW_BITS) * (y >> 17) + (x >> 17) * (y & LOW_BITS)
    p6 = (p5 >> 17) + (x >> 17) * (y >> 17)
    new_y = 4 * p6 + ((p5 >> 15) & 3) + ((p5 >> 14) & 1) + cy
    return new_x, new_y


def hw_count(cx: ArrayLike, cy: ArrayLike, max_count: int = MAX_COUNT,
             frac: int = FRAC_BITS) -> IntArray:
    """Iteration count of src/main/iterator_wide.vhd (frac = 33, the MEGA65).
    cx and cy are 2.33 fixed point numbers, i.e. 35-bit signed integers. With
    frac = 16, the iteration count of src/main/iterator.vhd (the Nexys 4 DDR),
    where cx and cy are 2.16 fixed point numbers (18-bit signed integers)."""
    if frac == 33:
        return hw_stop(cx, cy, max_count, frac)[0]
    cx_i: IntArray = np.asarray(cx, np.int64)
    cy_i: IntArray = np.asarray(cy, np.int64)
    cx_s: IntArray = cx_i << 16              # 4.32
    cy_div_2_s: IntArray = cy_i << 15        # 4.32, this is cy/2
    x: IntArray = np.zeros_like(cx_i)        # 2.16
    y: IntArray = np.zeros_like(cx_i)        # 2.16
    cnt: IntArray = np.zeros_like(cx_i)
    done: BoolArray = np.zeros(cx_i.shape, bool)
    ovf: BoolArray = np.zeros(cx_i.shape, bool)
    while True:
        # The count, and the end of the iteration
        done |= ovf
        active = ~done
        cnt = np.where(active, cnt + 1, cnt)
        done |= active & (cnt == max_count)
        if done.all():
            return cnt

        # x+y and x-y do not wrap around, because the one that may be out of
        # range goes to the 19-bit input of the multiplier. The products are
        # 4.32, and can not overflow.
        new_x_s = (x + y) * (x - y) + cx_s
        new_y_half_s = x * y + cy_div_2_s

        # The new x is in range (-2 <= x < 2) if the top three bits are equal.
        # The new y/2 is in range (-1 <= y/2 < 1) if the top four bits are equal.
        ovf_x = (new_x_s < -(1 << 33)) | (new_x_s >= (1 << 33))
        ovf_y = (new_y_half_s < -(1 << 32)) | (new_y_half_s >= (1 << 32))
        ovf = np.where(done, ovf, ovf_x | ovf_y)
        x = np.where(done, x, wrap(new_x_s >> 16, 18))         # Bits 33 downto 16
        y = np.where(done, y, wrap(new_y_half_s >> 15, 18))    # Bits 32 downto 15


def ref_count(cx: ArrayLike, cy: ArrayLike,
              max_count: int = MAX_COUNT) -> IntArray:
    """Iteration count using real numbers (cx and cy are real numbers). Same
    counting as the iterator: The number of the first iteration where x or y is
    outside the range -2 to 2, or max_count if this does not happen."""
    cx_r: RealArray = np.asarray(cx, np.float64)
    cy_r: RealArray = np.asarray(cy, np.float64)
    x: RealArray = np.zeros_like(cx_r)
    y: RealArray = np.zeros_like(cx_r)
    cnt: IntArray = np.full(cx_r.shape, max_count, np.int64)
    done: BoolArray = np.zeros(cx_r.shape, bool)
    for n in range(1, max_count):
        x, y = x*x - y*y + cx_r, 2*x*y + cy_r
        out = ~((x >= -2) & (x < 2) & (y >= -2) & (y < 2)) & ~done
        cnt[out] = n
        done |= out
        # Stop iterating the points that are done, so they do not overflow
        x = np.where(done, 0.0, x)
        y = np.where(done, 0.0, y)
    return cnt


def view(startx: Optional[int] = None, starty: Optional[int] = None,
         stepx: Optional[int] = None, stepy: Optional[int] = None,
         cols: int = NUM_COLS, rows: int = NUM_ROWS,
         frac: int = FRAC_BITS) -> Tuple[IntArray, IntArray]:
    """The values of cx and cy (2.frac fixed point) for each pixel, as arrays
    indexed by [row, column]. The default is the initial view in main.vhd,
    where the imaginary axis is centred on 0, with square pixels. It is
    calculated as in viewport.vhd (the positions are rounded to the nearest
    value, and the sizes of a pixel rounded down)."""
    one = float(1 << frac)
    size_y = SIZE_X * rows / cols
    if startx is None:
        startx = int(np.floor((-1.6667 + 2.0) * one + 0.5)) - (2 << frac)
    if starty is None:
        starty = int(np.floor((-size_y / 2 + 2.0) * one + 0.5)) - (2 << frac)
    if stepx is None:
        stepx = int(np.floor(SIZE_X * one + 0.5)) // cols
    if stepy is None:
        stepy = int(np.floor(size_y * one + 0.5)) // rows
    # The dispatcher and the job modules add the step in frac+2 bits, so the
    # values wrap around.
    cx = wrap(startx + np.arange(cols, dtype=np.int64) * stepx, frac + 2)
    cy = wrap(starty + np.arange(rows, dtype=np.int64) * stepy, frac + 2)
    cx_grid, cy_grid = np.meshgrid(cx, cy)
    return cx_grid, cy_grid


def pixel(cnt: ArrayLike, max_count: int) -> IntArray:
    """The value written to the display memory by job_wide.vhd for the count
    cnt: 511 for the points in the set (the count is max_count), and otherwise
    the count modulo 256."""
    c: IntArray = np.asarray(cnt, np.int64)
    return np.where(c == max_count, 511, c & 0xFF)


def hw_stop(cx: ArrayLike, cy: ArrayLike, max_count: int = MAX_COUNT,
            frac: int = FRAC_BITS) -> Tuple[IntArray, IntArray]:
    """Follow the iterator including the periodicity detection. Returns the
    count (which must be the same as from hw_count()), and the number of
    iterations done when the iterator stops, i.e. the value of cnt_r of
    src/main/iterator.vhd (frac = 16) when it stops, or it_r of the slot of
    src/main/iterator_wide.vhd (frac = 33, the default). x and y are saved
    after iterations 1, 2, 4, 8, ..., and compared with the saved values in
    each iteration from iteration 2. A match stops the iteration at once, with
    the count max_count."""
    if frac == 33:
        return hw_stop_wide(cx, cy, max_count)
    cx_i: IntArray = np.asarray(cx, np.int64)
    cy_i: IntArray = np.asarray(cy, np.int64)
    x: IntArray = np.zeros_like(cx_i)
    y: IntArray = np.zeros_like(cx_i)
    sx: IntArray = np.zeros_like(cx_i)
    sy: IntArray = np.zeros_like(cx_i)
    cnt: IntArray = np.zeros_like(cx_i)
    stop: IntArray = np.zeros_like(cx_i)
    done: BoolArray = np.zeros(cx_i.shape, bool)
    ovf: BoolArray = np.zeros(cx_i.shape, bool)
    while True:
        # p_ctrl, with x and y after cnt iterations, and ovf from the last
        # iteration
        active = ~done
        match = (cnt >= 2) & (x == sx) & (y == sy)
        save = active & (cnt != 0) & ((cnt & (cnt - 1)) == 0)
        stop = np.where(active, cnt, stop)
        found = active & ~ovf & (match | (cnt == max_count - 1))
        cnt = np.where(found, max_count, cnt)
        done |= active & (ovf | found)
        cnt = np.where(~done, cnt + 1, cnt)
        sx = np.where(save, x, sx)
        sy = np.where(save, y, sy)
        if done.all():
            return cnt, stop

        # The iteration (the DSPs), as in hw_count()
        new_x_s = (x + y) * (x - y) + (cx_i << 16)
        new_y_half_s = x * y + (cy_i << 15)
        ovf_x = (new_x_s < -(1 << 33)) | (new_x_s >= (1 << 33))
        ovf_y = (new_y_half_s < -(1 << 32)) | (new_y_half_s >= (1 << 32))
        ovf = np.where(done, ovf, ovf_x | ovf_y)
        x = np.where(done, x, wrap(new_x_s >> 16, 18))
        y = np.where(done, y, wrap(new_y_half_s >> 15, 18))


def hw_stop_wide(cx: ArrayLike, cy: ArrayLike,
                 max_count: int) -> Tuple[IntArray, IntArray]:
    """hw_stop() for src/main/iterator_wide.vhd (2.33 fixed point). The points
    that are done are removed from the arrays, which makes it much faster than
    hw_stop() for the many iterations of the maximum count 1023."""
    shape = np.shape(cx)
    cx_i: IntArray = np.asarray(cx, np.int64).ravel()
    cy_i: IntArray = np.asarray(cy, np.int64).ravel()
    cnt_out: IntArray = np.zeros(cx_i.size, np.int64)
    stop_out: IntArray = np.zeros(cx_i.size, np.int64)
    idx: IntArray = np.arange(cx_i.size)
    x: IntArray = np.zeros_like(cx_i)
    y: IntArray = np.zeros_like(cx_i)
    sx: IntArray = np.zeros_like(cx_i)
    sy: IntArray = np.zeros_like(cx_i)
    ovf: BoolArray = np.zeros(cx_i.size, bool)
    lim = 1 << 34
    cnt = 0
    while idx.size:
        # p_ctrl, with x and y after cnt iterations, and ovf from the last
        # iteration
        match = (cnt >= 2) & (x == sx) & (y == sy)
        found = ~ovf & (match | (cnt == max_count - 1))
        done = ovf | found
        stop_out[idx[done]] = cnt
        cnt_out[idx[done & ovf]] = cnt
        cnt_out[idx[found]] = max_count
        if cnt != 0 and (cnt & (cnt - 1)) == 0:
            sx, sy = x, y
        keep = ~done
        idx, x, y, sx, sy, cx_i, cy_i = (
            v[keep] for v in (idx, x, y, sx, sy, cx_i, cy_i))
        cnt += 1
        new_x, new_y = wide_iteration(x, y, cx_i, cy_i)
        ovf = (new_x < -lim) | (new_x >= lim) | (new_y < -lim) | (new_y >= lim)
        x = wrap(new_x, 35)
        y = wrap(new_y, 35)
    return cnt_out.reshape(shape), stop_out.reshape(shape)


def iterating_cycles(stop: ArrayLike) -> IntArray:
    """The number of clock cycles the job module needs for each pixel: one clock
    cycle per iteration, plus 7 to start the iterator and to deliver the result
    (from the clock cycle in which i_res_scheduler selects the previous result
    of the job module, until the ready flag of this result is high, see
    picture_cycles()). stop is the number of iterations done when the iterator
    stops (see hw_stop())."""
    return np.asarray(stop, np.int64) + 7


def picture_cycles(stop: ArrayLike, num_iterators: int = NUM_ITERATORS,
                   rows_in_job: int = ROWS_IN_JOB,
                   group_size: int = GROUP_SIZE,
                   pixels: int = PIXELS,
                   wide: bool = True) -> Tuple[int, int]:
    """Estimate the number of clock cycles used to calculate the picture, by
    simulating the dispatcher one clock cycle at a time. stop is the number of
    iterations done by the iterator for each pixel (see hw_stop()), indexed by
    [row, column]. Returns the number of clock cycles, and the total number of
    clock cycles the job modules wait for their results to be accepted.

    Each job is rows_in_job rows of a picture column, and the jobs are given in
    the same order as by the dispatcher (all the picture columns of the top
    block of rows, then all the picture columns of the next block, and so
    on). The clock cycles are counted as in src/main/dispatcher.vhd:
    * The scheduler for the jobs (i_job_scheduler) visits each job module once
      every num_iterators clock cycles, and gives it the next job if its busy
      flag is low in the clock cycle of the visit. The job starts (job_start_i
      of the job module is high) four clock cycles after the visit. The busy
      flag is low from three clock cycles after the last result of the job is
      selected.
    * The ready flag of the first result of a job (res_ready_s) is high
      iterating_cycles() - 2 clock cycles after the job starts.
    * The scheduler for the results (i_res_scheduler) visits one group of
      group_size job modules in each clock cycle, and selects one of the job
      modules of the group whose ready flag was high three clock cycles
      before (the ready flags and the candidate of the group are registered),
      in round-robin order within the group.
    * The ready flag of the next result is high iterating_cycles() clock
      cycles after the previous result was selected (the acknowledge reaches
      the job module two clock cycles after the selection, and the job module
      starts the next row in the clock cycle after that).
    The waiting time of a result is counted from the clock cycle in which it
    could have been selected at the earliest (three clock cycles after its
    ready flag is high), until the clock cycle in which it is selected.

    Each result is pixels consecutive rows. With wide = False (job.vhd, the
    Nexys 4 DDR), the job module keeps the counts of the first pixels-1 rows of
    a result, and starts the next row four clock cycles before the iterator
    would be done with it after an acknowledge (the done flag of the iterator
    starts it directly), so a result takes the sum of iterating_cycles() of its
    rows, less 4 for each row after the first.

    With wide = True (the default), the job modules are job_wide.vhd (the
    MEGA65), and pixels must be 4. The wide iterator calculates the four rows of a result at the
    same time, in four slots, and slot k is done 4n+k+3 clock cycles after the
    start (in the iterator), where n is the number of iterations done. So a
    result takes 4n+k+10 clock cycles, from the selection of the previous
    result until the ready flag is high, where n is the largest number of
    iterations of its rows, and k the last of the rows with n iterations (the
    first result of a job is ready 4n+k+8 clock cycles after the job starts,
    as above)."""
    stop_i: IntArray = np.asarray(stop, np.int64)
    rows, cols = stop_i.shape
    iter_cycles: IntArray
    if wide:
        group: IntArray = stop_i.reshape(rows // 4, 4, cols)
        most: IntArray = group.max(axis=1)
        last: IntArray = 3 - np.argmax((group == most[:, None, :])[:, ::-1, :], axis=1)
        iter_cycles = 4*most + last + 10
    else:
        row_cycles: IntArray = iterating_cycles(stop_i)
        iter_cycles = (
            row_cycles.reshape(rows // pixels, pixels, cols).sum(axis=1)
            - 4*(pixels - 1))
    rows //= pixels
    rows_in_job //= pixels
    jobs: List[List[int]] = [
        iter_cycles[b*rows_in_job:(b+1)*rows_in_job, c].tolist()
        for b in range(rows // rows_in_job) for c in range(cols)]
    num_groups = -(-num_iterators // group_size)
    period = max(num_groups, 5)
    job_latency = 4      # From the visit of i_job_scheduler to the start of the job

    next_job = 0
    job: List[List[int]] = [[] for _ in range(num_iterators)]
    row = [0] * num_iterators
    # The clock cycle from which the ready flag of each job module is high,
    # or None when it has no job
    ready: List[Optional[int]] = [None] * num_iterators
    ptr = [0] * num_groups
    # The clock cycles when idle job modules start their next job, as
    # (clock cycle, job module). i_job_scheduler visits job module i in the
    # clock cycles i, i+num_iterators, and so on.
    requests: List[Tuple[int, int]] = [
        (i + job_latency, i) for i in range(num_iterators)]
    heapq.heapify(requests)
    finished = 0
    last = 0
    waiting = 0
    k = 0
    while True:
        while requests and requests[0][0] <= k:
            t, i = heapq.heappop(requests)
            if next_job < len(jobs):
                job[i] = jobs[next_job]
                next_job += 1
                row[i] = 0
                ready[i] = t + job[i][0] - 2
            else:
                finished += 1
        if finished == num_iterators:
            return last, waiting

        # The result selected in clock cycle k, from the ready flags sampled
        # in clock cycle k-3
        g = k % period
        if g < num_groups:
            first: Optional[int] = None
            after: Optional[int] = None
            since = [0] * group_size
            for j in range(min(group_size, num_iterators - g*group_size)):
                r = ready[g*group_size + j]
                if r is not None and r <= k-3:
                    since[j] = r
                    if first is None:
                        first = j
                    if after is None and j >= ptr[g]:
                        after = j
            if first is not None:
                j = after if after is not None else first
                ptr[g] = (j + 1) % group_size
                i = g*group_size + j
                waiting += k - (since[j] + 3)
                last = k
                row[i] += 1
                if row[i] < len(job[i]):
                    ready[i] = k + job[i][row[i]]
                else:
                    # The next visit with the busy flag low
                    ready[i] = None
                    v = k + 3
                    v += (i - v) % num_iterators
                    heapq.heappush(requests, (v + job_latency, i))
        k += 1


def rgb(cnt: ArrayLike) -> NDArray[np.uint8]:
    """The colour shown on the VGA output: The lowest 8 bits of the count, as
    RRRGGGBB. Returns an array of 8-bit RGB values."""
    v: IntArray = np.asarray(cnt, np.int64) & 0xFF
    r = ((v >> 5) & 7) * 255 // 7
    g = ((v >> 2) & 7) * 255 // 7
    b = (v & 3) * 255 // 3
    return np.stack([r, g, b], -1).astype(np.uint8)


def main() -> None:
    args: List[str] = sys.argv[1:]
    if args not in ([], ["--png"]):
        print("Usage: model.py [--png]")
        sys.exit(2)

    # The MEGA65, with 2.33 fixed point and the maximum count 1023
    cx, cy = view()
    hw, stop = hw_stop(cx, cy)
    one = float(1 << FRAC_BITS)
    ref = ref_count(cx / one, cy / one)
    diff = hw - ref
    print(f"MEGA65: {hw.size} pixels, 2.{FRAC_BITS} fixed point, "
          f"maximum count {MAX_COUNT}")
    print("Difference in count (model vs. real) : number of pixels")
    values, counts = np.unique(np.clip(np.abs(diff), 0, 5), return_counts=True)
    for v, c in zip(values, counts):
        print(f"  {v:3d}{'+' if v == 5 else ' '}: {c}")
    in_set = hw == MAX_COUNT
    print(f"Pixels in the set: model {in_set.sum()}, "
          f"real {(ref == MAX_COUNT).sum()}, "
          f"different {(in_set != (ref == MAX_COUNT)).sum()}")
    print(f"Periodicity detection: it stops "
          f"{(in_set & (stop < MAX_COUNT - 1)).sum()} of the "
          f"{in_set.sum()} pixels in the set early, after "
          f"{stop[in_set].mean():.0f} iterations on average. Average count "
          f"{hw.mean():.1f}, average iterations {stop.mean():.1f}")
    cycles, waiting = picture_cycles(stop)
    print(f"Estimated time for the picture ({NUM_COLS}x{NUM_ROWS}, "
          f"{NUM_ITERATORS} job modules, {PIXELS} pixels in "
          f"each write): {cycles} clock cycles, i.e. "
          f"{cycles / MAIN_CLOCK_KHZ:.2f} ms at "
          f"{MAIN_CLOCK_KHZ / 1000:.3f} MHz "
          f"({MAIN_CLOCK_KHZ * 1000 / cycles:.0f} pictures per second), "
          f"the job modules wait {waiting / hw.size:.1f} clock cycles per pixel "
          f"on average")
    # If every pixel needed the maximum count, each result would take
    # 4*(MAX_COUNT-1)+3+10 clock cycles (see picture_cycles()), and the
    # results would be shared evenly between the job modules
    worst = (hw.size // PIXELS * (4 * (MAX_COUNT - 1) + 13)
             // NUM_ITERATORS)
    print(f"If every pixel needed the maximum count: about {worst} clock "
          f"cycles, i.e. {worst / MAIN_CLOCK_KHZ:.1f} ms "
          f"({MAIN_CLOCK_KHZ * 1000 / worst:.0f} pictures per second)")

    # The Nexys 4 DDR, with 2.16 fixed point and the maximum count 511
    print()
    cx, cy = view(cols=NEXYS4DDR_NUM_COLS, rows=NEXYS4DDR_NUM_ROWS,
                  frac=NEXYS4DDR_FRAC_BITS)
    hw_n = hw_count(cx, cy, NEXYS4DDR_MAX_COUNT, NEXYS4DDR_FRAC_BITS)
    one = float(1 << NEXYS4DDR_FRAC_BITS)
    ref_n = ref_count(cx / one, cy / one, NEXYS4DDR_MAX_COUNT)
    diff = hw_n - ref_n
    print(f"Nexys 4 DDR: {hw_n.size} pixels, 2.{NEXYS4DDR_FRAC_BITS} fixed "
          f"point, maximum count {NEXYS4DDR_MAX_COUNT}")
    print("Difference in count (model vs. real) : number of pixels")
    values, counts = np.unique(np.clip(np.abs(diff), 0, 5), return_counts=True)
    for v, c in zip(values, counts):
        print(f"  {v:3d}{'+' if v == 5 else ' '}: {c}")
    in_set = hw_n == NEXYS4DDR_MAX_COUNT
    print(f"Pixels in the set: model {in_set.sum()}, "
          f"real {(ref_n == NEXYS4DDR_MAX_COUNT).sum()}, "
          f"different {(in_set != (ref_n == NEXYS4DDR_MAX_COUNT)).sum()}")

    detected, stop = hw_stop(cx, cy, NEXYS4DDR_MAX_COUNT, NEXYS4DDR_FRAC_BITS)
    print(f"Periodicity detection: same count as without it for all pixels: "
          f"{bool((detected == hw_n).all())}. It stops "
          f"{(in_set & (stop < NEXYS4DDR_MAX_COUNT - 1)).sum()} of the "
          f"{in_set.sum()} pixels in the set early, after "
          f"{stop[in_set].mean():.0f} iterations on average")

    cycles, waiting = picture_cycles(stop, NEXYS4DDR_NUM_ITERATORS,
                                     rows_in_job=NEXYS4DDR_ROWS_IN_JOB,
                                     pixels=NEXYS4DDR_PIXELS, wide=False)
    iterating = iterating_cycles(stop).mean()
    print(f"Average count {hw_n.mean():.1f}. The iterator needs {iterating:.0f} "
          f"clock cycles per pixel, and the job modules wait "
          f"{waiting / hw_n.size:.0f} clock cycles per pixel on average for the "
          f"result to be accepted")
    print(f"Estimated time for the picture ({NEXYS4DDR_NUM_COLS}x"
          f"{NEXYS4DDR_NUM_ROWS}, {NEXYS4DDR_NUM_ITERATORS} job modules, "
          f"{NEXYS4DDR_PIXELS} pixels in each write): {cycles} clock cycles, "
          f"i.e. {cycles / NEXYS4DDR_MAIN_CLOCK_KHZ:.2f} ms at "
          f"{NEXYS4DDR_MAIN_CLOCK_KHZ / 1000:.3f} MHz "
          f"({NEXYS4DDR_MAIN_CLOCK_KHZ * 1000 / cycles:.0f} pictures per second)")

    if args == ["--png"]:
        from PIL import Image
        Image.fromarray(rgb(hw)).save("model.png")
        Image.fromarray(rgb(ref)).save("ref.png")
        print("Pictures written to model.png and ref.png")


if __name__ == "__main__":
    main()
