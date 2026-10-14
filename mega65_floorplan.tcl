# Floorplan of the job modules on the MEGA65 (R3 and R6, XC7A200T), sourced by
# mandelbrot.tcl after synthesis. It is needed for the wide iterators
# (iterator_wide.vhd): without it, the placer puts the fabric logic of many
# iterators far from their DSPs (e.g. the DSPs at the right edge of the FPGA
# and the registers at the left edge), which gives long routes between the
# DSPs and the fabric, and congestion in the middle of the FPGA.
#
# Each job module gets a pblock with the six DSPs of its iterator (a column of
# six DSPs, see the macros in mandelbrot.tcl), and the slices next to them:
# 12 slice columns, in the 15 rows of slices that the six DSPs span (two DSPs
# are five rows of slices). That is 180 slices, and a job module uses about
# 110. The DSPs of the XC7A200T are in five columns of 100 DSPs (DSP48_X0, X1,
# X2, X7, and X8, rows 0 to 99) and four columns of 60 (X3 to X6, rows 20 to
# 79), which hold 16 and 10 job modules. The job modules are given to the
# columns in order, so each group of 16 job modules in the dispatcher (which
# share registers, see dispatcher.vhd) is in one or two neighbouring columns.
# Two columns that are close to each other (e.g. X0 and X1) use slices on
# different sides.
#
# Each entry is: the DSP column, the first and last slice column, the first
# DSP row, and the number of job modules.
set floorplan {
   {0   0  11  0 16}
   {1  12  23  0 16}
   {2  40  51  0 16}
   {7 132 143  0 16}
   {8 144 155  0 16}
   {3  54  65 20 10}
   {4  66  77 20 10}
   {5  80  91 20 10}
   {6  92 103 20 10}
}

set jobs [get_cells -quiet -hierarchical -filter {NAME =~ *gen_job[*].i_job}]
if {[llength $jobs] != 120} {
   puts "ERROR: The floorplan is for 120 wide job modules, but there are [llength $jobs]"
   exit 1
}
set i 0
foreach entry $floorplan {
   lassign $entry col x0 x1 dsp0 num
   for {set k 0} {$k < $num} {incr k} {
      set job [get_cells -hierarchical -filter "NAME =~ *gen_job\[$i\].i_job"]
      set d0 [expr {$dsp0 + 6*$k}]
      set y0 [expr {$d0 / 2 * 5}]
      set pb [create_pblock job_$i]
      resize_pblock $pb -add "SLICE_X${x0}Y${y0}:SLICE_X${x1}Y[expr {$y0 + 14}]"
      resize_pblock $pb -add "DSP48_X${col}Y${d0}:DSP48_X${col}Y[expr {$d0 + 5}]"
      add_cells_to_pblock $pb $job
      incr i
   }
}
