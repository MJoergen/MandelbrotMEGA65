# This is a tcl command script for the Vivado tool chain.
# The board name, the FPGA part, the top level module, the VHDL source files,
# and the constraint files (.xdc) are given as arguments (-tclargs), so this
# information is only in the Makefile. Use "make mega65-r3", "make mega65-r6",
# or "make nexys4ddr". The Makefile runs Vivado in build/<board>, so the output
# files (<board>.dcp, <board>.bit, logs, etc.) are written there.
#
# The reports of the routed design (timing.rpt, utilization.rpt, and
# power.rpt) are written to build/<board> too. The bit-file is only written
# when the design meets timing (setup and hold). Otherwise any old bit-file
# is deleted, and the script stops with an error, so "make fpga" can not
# load a design that fails timing. The routed checkpoint is still written,
# so the failing paths can be examined.
if {[llength $argv] < 4} {
   puts "ERROR: No board and source files given. Use \"make mega65-r3\", \"make mega65-r6\", or \"make nexys4ddr\"."
   exit 1
}
lassign $argv board part top
foreach src [lrange $argv 3 end] {
   if {[file extension $src] eq ".xdc"} {
      read_xdc $src
   } else {
      read_vhdl -vhdl2008 $src
   }
}
set_param messaging.defaultLimit 3000
synth_design -verbose -top $top -part $part -flatten_hierarchy none -directive AreaOptimized_medium
# The two DSPs of each iterator are placed next to each other in the same
# column, because the path from each of them to the other one is the longest
# path of the iterator (see iterator.vhd). The relative locations are in DSP
# sites.
set n 0
foreach it [get_cells -hierarchical -filter {NAME =~ *i_iterator}] {
   create_macro iterator_$n
   update_macro iterator_$n [list $it/px_r_reg X0Y0 $it/py_r_reg X0Y1]
   incr n
}
# All the DSPs are in the iterators, two in each. If the names of the cells
# change, the filter above finds no iterators, no macros are made, and timing
# fails by 0.7 to 1.5 ns without a hint why.
set num_dsps [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E1}]]
puts "INFO: Created $n macros for the iterators, with $num_dsps DSPs in the design."
if {$n == 0 || 2*$n != $num_dsps} {
   puts "ERROR: Found $n iterators for $num_dsps DSPs, expected two DSPs for each iterator."
   exit 1
}
opt_design -verbose -directive ExploreWithRemap
place_design -directive ExtraTimingOpt
phys_opt_design -verbose -directive AlternateFlowWithRetiming
route_design
phys_opt_design -verbose -directive AlternateFlowWithRetiming
write_checkpoint -force $board.dcp
report_timing_summary -file timing.rpt
report_utilization -file utilization.rpt
report_power -file power.rpt
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "INFO: Setup slack (WNS) $wns ns, hold slack (WHS) $whs ns."
if {$wns < 0 || $whs < 0} {
   file delete -force $board.bit
   puts "ERROR: The design does not meet timing (WNS $wns ns, WHS $whs ns), so no bit-file is written. See timing.rpt."
   exit 1
}
write_bitstream -force $board.bit
exit
