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
--   select the colour palette in vga.vhd (see palette_pkg.vhd). The decimal
--   point of the 7-segment display is not used, so it is switched off here.
--
-- The frame rate is moved to the VGA clock domain by fps_cdc.vhd, as in
-- mega65.vhd. The constraints for this are in nexys4ddr.xdc.

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

   -- The number of job modules. The XC7A100T has 240 DSPs, two for each
   -- job module (see iterator.vhd).
   constant C_NUM_ITERATORS : positive := 120;

   -- The number of pixels in each write to the display memory. Writing more
   -- than one pixel at a time makes the picture faster (see mega65.vhd).
   -- With four pixels the model estimates 1.20 ms for the initial picture,
   -- against 2.73 ms with one.
   constant C_PIXELS        : positive := 4;

   -- The VCO of the MMCM (see clk_rst.vhd): 100 MHz / 1 * 12 = 1200 MHz.
   constant C_VCO_DIVIDE    : positive := 1;
   constant C_VCO_MULT      : real    := 12.0;

   -- The video mode (see video_pkg.vhd), and the divider of the VGA clock,
   -- which gives the pixel clock (1200 MHz / 48 = 25 MHz, see clk_rst.vhd).
   constant C_VIDEO         : video_mode_t := C_VIDEO_640X480;
   constant C_VGA_DIVIDE    : positive := 48;

   -- The divider of the MAIN clock (see clk_rst.vhd), and its frequency in Hz.
   -- 1200 MHz / 10 = 120 MHz. The longest path is in the iterators (see
   -- iterator.vhd), which are slower in the speed grade -1 of the XC7A100T
   -- than on the MEGA65. The model (sim/model.py) estimates 1.36 million
   -- clock cycles for the worst case picture (every pixel needs the maximum
   -- count), i.e. 87 pictures per second, still well above the 60 Hz of the
   -- VGA output.
   constant C_MAIN_DIVIDE   : real    := 10.0;
   constant C_MAIN_FREQ     : natural :=
      natural(100.0E6 / real(C_VCO_DIVIDE) * C_VCO_MULT / C_MAIN_DIVIDE);

   -- Rows in each job given to a job module, see dispatcher.vhd. The
   -- number of rows (480) must be a multiple of it.
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

   signal wr_addr        : std_logic_vector(C_ADDR_BITS-1 downto 0);
   signal wr_data        : std_logic_vector(9*C_PIXELS-1 downto 0);
   signal wr_en          : std_logic;

   signal rd_addr        : std_logic_vector(C_ADDR_BITS-1 downto 0);
   signal rd_data        : std_logic_vector( 8 downto 0);

   signal fps_digits     : std_logic_vector(31 downto 0);
   signal fps_blank      : std_logic_vector( 7 downto 0);
   signal fps_valid      : std_logic;

   -- The frame rate in the VGA clock domain
   signal vga_fps_digits : std_logic_vector(31 downto 0);
   signal vga_fps_blank  : std_logic_vector( 7 downto 0);

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
   -- Instantiate MAIN clock domain
   --------------------------------------------------

   i_main : entity work.main
      generic map (
         G_CLK_FREQ      => C_MAIN_FREQ,
         G_NUM_ITERATORS => C_NUM_ITERATORS,
         G_PIXELS        => C_PIXELS,
         G_ROWS_IN_JOB   => C_ROWS_IN_JOB,
         G_NUM_COLS      => C_VIDEO.h_visible,
         G_NUM_ROWS      => C_VIDEO.v_visible,
         G_COL_STRIDE    => C_COL_STRIDE,
         G_ADDR_BITS     => C_ADDR_BITS
      )
      port map (
         clk_i        => main_clk,
         rst_i        => main_rst,
         btn_i        => btn_i,
         sw_i         => sw_i,
         seg_o        => seg_o,
         seg_an_o     => seg_an_o,
         fps_digits_o => fps_digits,
         fps_blank_o  => fps_blank,
         fps_valid_o  => fps_valid,
         wr_addr_o    => wr_addr,
         wr_data_o    => wr_data,
         wr_en_o      => wr_en
      ); -- i_main


   ------------------------------
   -- Instantiate display memory
   ------------------------------

   i_disp_mem : entity work.disp_mem
      generic map (
         G_ADDR_BITS  => C_ADDR_BITS,
         G_NUM_BLOCKS => C_MEM_BLOCKS,
         G_BLOCK_REGS => C_BLOCK_REGS,
         G_PIXELS     => C_PIXELS
      )
      port map (
         wr_clk_i  => main_clk,
         wr_addr_i => wr_addr,
         wr_data_i => wr_data,
         wr_en_i   => wr_en,
         --
         rd_clk_i  => vga_clk,
         rd_addr_i => rd_addr,
         rd_data_o => rd_data
      ); -- i_disp_mem


   seg_dp_o <= '1';


   --------------------------------------------------
   -- Move the frame rate to the VGA clock domain
   --------------------------------------------------

   i_fps_cdc : entity work.fps_cdc
      port map (
         main_clk_i    => main_clk,
         main_digits_i => fps_digits,
         main_blank_i  => fps_blank,
         main_valid_i  => fps_valid,
         vga_clk_i     => vga_clk,
         vga_digits_o  => vga_fps_digits,
         vga_blank_o   => vga_fps_blank
      ); -- i_fps_cdc


   --------------------------------------------------
   -- Instantiate VGA clock domain
   --------------------------------------------------

   i_vga : entity work.vga
      generic map (
         G_MODE       => C_VIDEO,
         G_COL_STRIDE => C_COL_STRIDE,
         G_ADDR_BITS  => C_ADDR_BITS
      )
      port map (
         clk_i        => vga_clk,
         rd_addr_o    => rd_addr,
         rd_data_i    => rd_data,
         palette_i    => sw_i(1 downto 0),
         fps_digits_i => vga_fps_digits,
         fps_blank_i  => vga_fps_blank,
         vga_hs_o     => vga_hs_o,
         vga_vs_o     => vga_vs_o,
         vga_col_o    => vga_col_o
      ); -- i_vga

end architecture structural;
