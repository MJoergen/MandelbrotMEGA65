# This is a tcl command script for the Vivado tool chain.
# The board name, the FPGA part, the top level module, the source files, and
# the constraint files (.xdc) are given as arguments (-tclargs), so this
# information is only in the Makefile. The source files are VHDL files, and
# the floorplan of the board (a .tcl file, sourced after the synthesis), if it
# has one. Use "make mega65-r3", "make mega65-r6", or "make nexys4ddr". The
# Makefile runs Vivado in build/<board>, so the output files (<board>.dcp,
# <board>.bit, logs, etc.) are written there.
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
set floorplans {}
foreach src [lrange $argv 3 end] {
   if {[file extension $src] eq ".xdc"} {
      read_xdc $src
   } elseif {[file extension $src] eq ".tcl"} {
      lappend floorplans $src
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
# The wide iterator (iterator_wide.vhd, on the MEGA65) has two cascades of
# three DSPs, and they are placed in a column of six DSPs, so the paths from
# the DSPs to the fabric and back are short. The last DSP of each cascade is
# p3_r_reg and p6_r_reg, and the DSP before each DSP is the one that drives
# its cascade input (PCIN), because the first DSPs have names given by the
# synthesis.
proc pcin_driver {dsp} {
   set net [get_nets -of_objects [get_pins $dsp/PCIN[0]]]
   return [get_cells -of_objects [get_pins -leaf -of_objects $net -filter {DIRECTION == OUT}]]
}
set n 0
set macro_dsps 0
foreach it [get_cells -hierarchical -filter {NAME =~ *i_iterator}] {
   create_macro iterator_$n
   if {[llength [get_cells -quiet $it/px_r_reg]] > 0} {
      update_macro iterator_$n [list $it/px_r_reg X0Y0 $it/py_r_reg X0Y1]
      incr macro_dsps 2
   } else {
      set locs {}
      set y 0
      foreach last {p3_r_reg p6_r_reg} {
         set dsp3 [get_cells $it/$last]
         set dsp2 [pcin_driver $dsp3]
         set dsp1 [pcin_driver $dsp2]
         foreach dsp [list $dsp1 $dsp2 $dsp3] {
            lappend locs $dsp X0Y$y
            incr y
         }
      }
      update_macro iterator_$n $locs
      incr macro_dsps 6
   }
   incr n
}
# All the DSPs are in the iterators, two in each (six in a wide iterator). If
# the names of the cells change, the filter above finds no iterators, no
# macros are made, and timing fails by 0.7 to 1.5 ns without a hint why.
set num_dsps [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E1}]]
puts "INFO: Created $n macros for the iterators, with $num_dsps DSPs in the design."
if {$n == 0 || $macro_dsps != $num_dsps} {
   puts "ERROR: Found $n iterators with $macro_dsps DSPs, but $num_dsps DSPs in the design."
   exit 1
}
# The floorplan of the board, if there is one. The MEGA65 has one for the
# wide iterators (mega65_floorplan.tcl).
foreach floorplan $floorplans {
   source $floorplan
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
