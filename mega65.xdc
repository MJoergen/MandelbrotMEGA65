# This file is common to the MEGA65 board revisions R3 and R6. It contains
# the timing constraints and the configuration of the bitstream. The pins are
# in mega65-r3.xdc and mega65-r6.xdc.

# Clock definition
create_clock -name sys_clk -period 10.00 [get_ports {clk_i}];                          # 100 MHz

# The frame rate and the view are moved from the MAIN clock domain to the VGA
# clock domain with a toggle signal, which is synchronized, see cdc_data.vhd.
# These are the only paths from the MAIN clock to the VGA clock. Their delay
# only has to be shorter than the synchronizer (two VGA clock cycles), so the
# relation between the two clocks is ignored.
set_max_delay -datapath_only -from [get_clocks -of_objects [get_pins i_mega65/i_clk_rst/i_mmcm_adv/CLKOUT0]] -to [get_clocks -of_objects [get_pins i_mega65/i_clk_rst/i_mmcm_adv/CLKOUT1]] 10.000

# All the inputs apart from the clock are asynchronous to the clocks of the
# design: they are synchronized with two registers (the reset button of the R6
# in clk_rst.vhd, and the joystick lines in main.vhd), or sampled long after
# they change (the data from the keyboard, once in each cycle of the keyboard
# clock of about 312 kHz, see mega65kbd_to_matrix.vhd, and the data from the
# MAX10 of the R3, half a cycle (20 ns) after the edge of the 25 MHz clock that
# the FPGA sends to it, see max10.vhd). So they have no input delay, and the
# paths from them are not timed.
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk_i}]

# Configuration Bank Voltage Select
set_property CONFIG_VOLTAGE                  3.3   [current_design]
set_property CFGBVS                          VCCO  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS      TRUE  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE     66    [current_design]
set_property CONFIG_MODE                     SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES   [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   4     [current_design]
