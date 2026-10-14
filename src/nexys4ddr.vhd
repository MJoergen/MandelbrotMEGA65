-- This is the top level module for the Nexys 4 DDR board. The ports on this
-- entity are mapped directly to pins on the FPGA, see nexys4ddr.xdc.
--
-- It is the same design as mega65.vhd (the design for the MEGA65), see the
-- description there, only the size of the design, the resolution, and the
-- ports are different:
-- * The VGA output is 640x480 @ 60 Hz, with a pixel clock of 25 MHz, instead
--   of 1280x1024. There is no HDMI output.
-- * The XC7A100T is smaller, so there are fewer job modules, and the display
--   memory is smaller, see the constants below.
-- * The buttons, switches, and the 7-segment display are handled by
--   main.vhd, see the description there, except switches 0 and 1, which
--   select the colour palette in vga.vhd (see palette_pkg.vhd), and switch 3
--   moves the palette (see disp.vhd). The decimal point of the 7-segment
--   display is not used, so it is switched off here.
--
-- The design itself is in core.vhd, as for the MEGA65. This module holds the
-- constants of the Nexys 4 DDR, and instantiates the clock and reset
-- generation and core. The constraints for the frame rate and the view, which
-- are moved to the VGA clock domain in core.vhd, are in nexys4ddr.xdc.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.video_pkg.all;

entity nexys4ddr is
   port (
      clk_i     : in  std_logic;                      -- 100 MHz
      rstn_i    : in  std_logic;

      btn_i     : in  std_logic_vector( 4 downto 0);  -- "CLRUD"
      sw_i      : in  std_logic_vector( 7 downto 0);
      seg_o     : out std_logic_vector( 6 downto 0);  -- "GFEDCBA", active low
      seg_dp_o  : out std_logic;                      -- Active low
      seg_an_o  : out std_logic_vector( 7 downto 0);  -- Active low

      vga_hs_o  : out std_logic;
      vga_vs_o  : out std_logic;
      vga_col_o : out std_logic_vector( 7 downto 0)    -- RRRGGGBB
   );
end entity nexys4ddr;

architecture structural of nexys4ddr is

   -- The number of job modules, with six DSPs each, in two cascades of three
   -- (see iterator_wide.vhd). The XC7A100T has 240 DSPs, in three columns of
   -- 80, and a cascade must be in one column, so a column has room for 13
   -- iterators (a column of six DSPs, see mandelbrot.tcl), i.e. 39 in all
   -- (234 DSPs).
   constant C_NUM_ITERATORS : positive := 39;

   -- The maximum count, as on the MEGA65 (see main.vhd and job_wide.vhd)
   constant C_MAX_COUNT     : positive := 1023;

   -- The number of pixels in each write to the display memory. The wide
   -- iterator calculates the four rows of a result at the same time, so this
   -- must be 4. The model (sim/model.py) estimates 849,000 clock cycles for
   -- the initial picture (7.08 ms, i.e. 141 pictures per second).
   constant C_PIXELS        : positive := 4;

   -- The VCO of the MMCM (see clk_rst.vhd): 100 MHz / 1 * 12 = 1200 MHz.
   constant C_VCO_DIVIDE    : positive := 1;
   constant C_VCO_MULT      : real    := 12.0;

   -- The video mode (see video_pkg.vhd), and the divider of the VGA clock,
   -- which gives the pixel clock (1200 MHz / 48 = 25 MHz, see clk_rst.vhd).
   constant C_VIDEO         : video_mode_t := C_VIDEO_640X480;
   constant C_VGA_DIVIDE    : positive := 48;

   -- The divider of the MAIN clock (see clk_rst.vhd), and its frequency in Hz.
   -- 1200 MHz / 10 = 120 MHz. The XC7A100T has the speed grade -1, which is
   -- slower than the MEGA65. The model (sim/model.py) estimates 8.08 million
   -- clock cycles for the worst case picture (every pixel needs the maximum
   -- count), i.e. 15 pictures per second.
   constant C_MAIN_DIVIDE   : real    := 10.0;
   constant C_MAIN_FREQ     : natural :=
      natural(100.0E6 / real(C_VCO_DIVIDE) * C_VCO_MULT / C_MAIN_DIVIDE);

   -- Rows in each job given to a job module, see dispatcher.vhd. The
   -- number of rows (480) must be a multiple of it, and of C_PIXELS. The
   -- model gives 141 to 142 pictures per second for 16 to 240 rows.
   constant C_ROWS_IN_JOB   : positive := 120;

   -- The address distance between two picture columns in the display memory,
   -- see dispatcher.vhd. 512 rows per column means the address is the column
   -- followed by the row.
   constant C_COL_STRIDE    : positive := 512;

   -- The display memory (see disp_mem.vhd): 2^19 pixels, i.e. 128 blocks
   -- (BRAMs) of 4096 pixels, with 19 bits of address, and a register for the
   -- write port of each block. The picture only uses the first 80 blocks (640
   -- columns of 512 addresses).
   constant C_ADDR_BITS     : positive := 19;
   constant C_MEM_BLOCKS    : positive := 128;
   constant C_BLOCK_REGS    : boolean := true;

   signal main_clk       : std_logic;
   signal main_rst       : std_logic;

   signal vga_clk        : std_logic;

begin

   --------------------------------------------------
   -- Instantiate clock and reset generation
   --------------------------------------------------

   i_clk_rst : entity work.clk_rst
      generic map (
         G_VCO_DIVIDE  => C_VCO_DIVIDE,
         G_VCO_MULT    => C_VCO_MULT,
         G_MAIN_DIVIDE => C_MAIN_DIVIDE,
         G_VGA_DIVIDE  => C_VGA_DIVIDE
      )
      port map (
         clk_i      => clk_i,
         rstn_i     => rstn_i,
         main_clk_o => main_clk,
         main_rst_o => main_rst,
         vga_clk_o  => vga_clk,
         vga_rst_o  => open      -- Only the HDMI output of the MEGA65 uses it
      ); -- i_clk_rst


   --------------------------------------------------
   -- Instantiate the design
   --------------------------------------------------

   i_core : entity work.core
      generic map (
         G_CLK_FREQ      => C_MAIN_FREQ,
         G_NUM_ITERATORS => C_NUM_ITERATORS,
         G_PIXELS        => C_PIXELS,
         G_ROWS_IN_JOB   => C_ROWS_IN_JOB,
         G_VIDEO         => C_VIDEO,
         G_COL_STRIDE    => C_COL_STRIDE,
         G_ADDR_BITS     => C_ADDR_BITS,
         G_MEM_BLOCKS    => C_MEM_BLOCKS,
         G_BLOCK_REGS    => C_BLOCK_REGS,
         G_MAX_COUNT     => C_MAX_COUNT
      )
      port map (
         main_clk_i => main_clk,
         main_rst_i => main_rst,
         vga_clk_i  => vga_clk,
         btn_i      => btn_i,
         sw_i       => sw_i,
         seg_o      => seg_o,
         seg_an_o   => seg_an_o,
         vga_hs_o   => vga_hs_o,
         vga_vs_o   => vga_vs_o,
         vga_de_o   => open,
         vga_col_o  => vga_col_o
      ); -- i_core


   seg_dp_o <= '1';


end architecture structural;
