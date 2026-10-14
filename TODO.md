# TODO

5. Measure the design (2.33 numbers, wide iterator) on the boards. Its frame
   rates (163 pictures per second for the initial view on the MEGA65, and 141
   on the Nexys 4 DDR) are only estimated by the model (`sim/model.py`). The
   model agrees with a simulation of a complete 160x128 picture within 0.4%.
   The design runs on the MEGA65 R6, but its frame rate has not been measured
   yet.

The next items are ideas for making the MEGA65 design faster. The numbers are
from the model unless stated otherwise. See
[Iterator](ALGORITHM.md#iterator) and [MEGA65](ALGORITHM.md#mega65)
for the current design.

6. Test for the main cardioid and the period-2 bulb. Points inside them are in
   the set, and there is a closed-form test for both, so the iterator does not
   need to iterate them at all. In the initial view 24% of the pixels are
   inside them, and they take most of the iterations. With the test, the model
   gives 356 instead of 163 pictures per second for the initial view, and 133
   instead of 40 for Seahorse Valley (0.08 wide, centred near -0.75+0.15i). It
   does not help for deep zooms away from the cardioid and the bulb, or for the
   worst case. The test needs a few multiplications for each pixel, but only
   with low precision (with a safety margin), so it could be done in LUTs, or
   in the DSPs of the iterator before the iteration starts. The model must
   include the test, so that the design can still be compared with it bit for
   bit.

7. Shorter routes from the dispatcher to the job modules. Since the floorplan,
   the worst path at 180 MHz (+0.102 ns) is no longer in an iterator, but from
   the register of a group in the dispatcher (stepy, `grp_stepy_r` in
   `dispatcher_jobs.vhd`) to the accumulator of cy in an iterator, which is
   mostly routing (4.6 ns of 5.6 ns). The values of the job (cx, starty, stepy)
   are now 35 bits each. Possible fixes: register stepy once more in each job
   module (it is constant during a picture), place the group registers next to
   the regions of their job modules in the floorplan, or add a second level of
   group registers. This is needed before the main clock can go above 180 MHz
   (the next step of the MMCM is 1080/5.75 = 187.8 MHz).

8. A deeper pipeline in the wide iterator. The iterator has four pipeline
   stages, and two of them have a route between the DSPs and the fabric with
   logic (the adders) on the same path. With eight stages (e.g. two groups of
   four slots, each calculating its own four rows, with a register after each
   adder and after the DSPs), each of these routes would have a whole clock
   cycle. That would make the timing much less dependent on the placement,
   maybe without the floorplan, and allow a faster clock. The job module would
   then handle two results at the same time (they could be delivered in any
   order, because each result has its row number).

9. Do not wait for the slowest of the four rows. The four rows of a result are
   calculated together, so the slots that finish early wait for the slowest
   one: in the initial view the iterator is busy with points that are not done
   yet 89% of the time (83% to 98% in other views). With independent slots
   (each slot taking the next row as soon as it is done) this would be close
   to 100%, but the job module would have to collect the counts of each result
   from different slots.

10. Start the next rows before the result is acknowledged. The job module waits
    for the acknowledge of a result before it starts the iterator with the next
    four rows, and the job modules wait 7 clock cycles per pixel on average for
    their results to be accepted (about 7% of the 101 clock cycles of a pixel
    in the initial view). With a second output register, the iterator could
    start the next rows at once.

11. Use the last 20 DSPs. The floorplan uses 720 of the 740 DSPs (120
    iterators): the four DSPs at the top of each of the five tall DSP columns
    are not used. Three more iterators would need the two cascades of an
    iterator in different places, i.e. a different macro and floorplan for
    them, for about 2.5% more pictures per second.

12. Approximate periodicity detection. With 35 bits the values take longer to
    repeat exactly (275 iterations on average for the points in the set in the
    initial view, against 124 with 18 bits). Comparing only the top bits of x
    and y (e.g. down to 2^-24) gives 10% to 18% fewer iterations, with no
    different pixels in the views that were tried, but it is no longer exactly
    the same count as without the detection, and coarser comparisons give
    wrong pixels at deep zoom. A tolerance that follows the size of a pixel
    might be safe.

The last items are not about speed, but they are related to the MEGA65 design.

13. Exact products. The low product of each multiplication (17 x 17 bits) is
    left out, so the new values differ from the truncated exact product by -2
    to +1 LSB (x) and -4 to +1 LSB (y). The low product could be calculated in
    LUTs (only its top 17 bits are needed) and added in the input C of the
    first DSP of each cascade, without more DSPs. Vivado did not use the
    cascade when the input C of the first DSP had a constant (see the history
    of the MEGA65 build), so this may need the DSPs to be instantiated.

14. Faster zooming. At about 1.6% per update, it takes about a minute to zoom
    from the initial view to the smallest pixel (2^-33). A faster zoom (e.g.
    faster while the button is held down) would make the deep zoom easier to
    reach.

15. A higher maximum count. In deep zooms near the boundary of the set, 1023
    iterations are often not enough (e.g. 82% of the pixels reach 1023 in
    Seahorse Valley at a width of 10^-6, and most of them are not in the set).
    The maximum count is a generic (`C_MAX_COUNT` in `src/mega65.vhd`), but a
    higher one makes the worst case slower in proportion.

16. The view as text in 2.33. `view_text.vhd` only handles 2.16, so
    `main.vhd` gives it the view truncated to 2.16. The centre shown is then
    off by up to about 0.01 (it is calculated with the truncated size of a
    pixel, times 640), and the zoom stops at 136.00x, although the view can
    be zoomed in 2^17 times further. Calculating `view_text.vhd` in 2.33
    would fix the centre: the multiplication by the column of the centre at
    the full width (47 bits instead of 30), rounded to 2.16 before the digits.
    The zoom needs a wider field in the text (up to about 18 million, 8
    digits before the point), i.e. more characters in `text_pkg.vhd` and the
    overlay, and a wider division.

17. Investigate whether using HyperRAM is worth it. The maximum read speed is
    200 MB/s so a resolution of 1920x1280 @ 60 Hz should be possible. It will
    require rewriting the logic, so that pixels are generated horizontally
    rather than vertically.

