-- This is the design that is the same on all the boards: the MAIN clock
-- domain (main.vhd), the display memory (disp_mem.vhd), the frame rate and the
-- view moved to the VGA clock domain (cdc_data.vhd), and the VGA clock domain
-- (vga.vhd). The top levels of the boards (mega65.vhd and nexys4ddr.vhd) are
-- left with the clock and reset generation, the inputs, the video outputs,
-- and the pins. The constants of each board (the number of job modules, the
-- resolution, the size of the display memory, etc.) are the generics, see the
-- top levels.
--
-- This module has no Xilinx primitives, so the whole design from the buttons
-- to the VGA output can be simulated with GHDL.
--
-- The clocks and the resets are inputs. The reset is synchronous to the MAIN
-- clock, and the VGA clock domain needs no reset.
--
-- The frame rate and the view (as text) are calculated in main.vhd, and shown
-- on the VGA output by vga.vhd. They are moved to the VGA clock domain by
-- cdc_data.vhd. The only other signals between the two clock domains are the
-- display memory, and the switches of the palette and its movement (sw_i(0),
-- sw_i(1), and sw_i(3)), which vga.vhd synchronizes.

library ieee;
use ieee.std_logic_1164.all;

use work.video_pkg.all;

entity core is
   generic (
      G_CLK_FREQ      : natural;         -- Frequency of the MAIN clock, in Hz
      G_NUM_ITERATORS : positive;
      G_PIXELS        : positive;        -- Pixels in each write to the display memory
      G_ROWS_IN_JOB   : positive;
      G_VIDEO         : video_mode_t;
      G_COL_STRIDE    : positive;
      G_ADDR_BITS     : positive;
      G_MEM_BLOCKS    : positive;
      G_BLOCK_REGS    : boolean;
      G_MAX_COUNT     : positive
   );
   port (
      main_clk_i : in  std_logic;
      main_rst_i : in  std_logic;
      vga_clk_i  : in  std_logic;

      btn_i      : in  std_logic_vector( 4 downto 0);  -- "CLRUD"
      sw_i       : in  std_logic_vector( 7 downto 0);
      seg_o      : out std_logic_vector( 6 downto 0);  -- "GFEDCBA", active low
      seg_an_o   : out std_logic_vector( 7 downto 0);  -- Active low

      vga_hs_o   : out std_logic;
      vga_vs_o   : out std_logic;
      vga_de_o   : out std_logic;
      vga_col_o  : out std_logic_vector( 7 downto 0)   -- RRRGGGBB
   );
end entity core;

architecture structural of core is

   signal wr_addr        : std_logic_vector(G_ADDR_BITS-1 downto 0);
   signal wr_data        : std_logic_vector(9*G_PIXELS-1 downto 0);
   signal wr_en          : std_logic;

   signal rd_addr        : std_logic_vector(G_ADDR_BITS-1 downto 0);
   signal rd_data        : std_logic_vector( 8 downto 0);

   signal fps_digits     : std_logic_vector(31 downto 0);
   signal fps_blank      : std_logic_vector( 7 downto 0);
   signal fps_valid      : std_logic;

   signal view_text      : std_logic_vector(99 downto 0);

   -- The frame rate (the digits followed by the blanking) and the view (25
   -- characters) in the MAIN clock domain, and in the VGA clock domain. Until
   -- the first frame rate, all the digits are blanked, and all the characters
   -- are 15 (not shown), so nothing is shown.
   constant C_FPS_INIT   : std_logic_vector(139 downto 0) :=
      X"00000000FF" & X"FFFFFFFFFFFFFFFFFFFFFFFFF";
   signal fps            : std_logic_vector(139 downto 0);
   signal vga_fps        : std_logic_vector(139 downto 0);
   signal vga_fps_digits : std_logic_vector(31 downto 0);
   signal vga_fps_blank  : std_logic_vector( 7 downto 0);
   signal vga_view_text  : std_logic_vector(99 downto 0);

begin

   --------------------------------------------------
   -- Instantiate MAIN clock domain
   --------------------------------------------------

   i_main : entity work.main
      generic map (
         G_CLK_FREQ      => G_CLK_FREQ,
         G_NUM_ITERATORS => G_NUM_ITERATORS,
         G_PIXELS        => G_PIXELS,
         G_ROWS_IN_JOB   => G_ROWS_IN_JOB,
         G_NUM_COLS      => G_VIDEO.h_visible,
         G_NUM_ROWS      => G_VIDEO.v_visible,
         G_COL_STRIDE    => G_COL_STRIDE,
         G_ADDR_BITS     => G_ADDR_BITS,
         G_MAX_COUNT     => G_MAX_COUNT
      )
      port map (
         clk_i        => main_clk_i,
         rst_i        => main_rst_i,
         btn_i        => btn_i,
         sw_i         => sw_i,
         seg_o        => seg_o,
         seg_an_o     => seg_an_o,
         fps_digits_o => fps_digits,
         fps_blank_o  => fps_blank,
         fps_valid_o  => fps_valid,
         view_text_o  => view_text,
         wr_addr_o    => wr_addr,
         wr_data_o    => wr_data,
         wr_en_o      => wr_en
      ); -- i_main


   ------------------------------
   -- Instantiate display memory
   ------------------------------

   i_disp_mem : entity work.disp_mem
      generic map (
         G_ADDR_BITS  => G_ADDR_BITS,
         G_NUM_BLOCKS => G_MEM_BLOCKS,
         G_BLOCK_REGS => G_BLOCK_REGS,
         G_PIXELS     => G_PIXELS
      )
      port map (
         wr_clk_i  => main_clk_i,
         wr_addr_i => wr_addr,
         wr_data_i => wr_data,
         wr_en_i   => wr_en,
         --
         rd_clk_i  => vga_clk_i,
         rd_addr_i => rd_addr,
         rd_data_o => rd_data
      ); -- i_disp_mem


   --------------------------------------------------
   -- Move the frame rate to the VGA clock domain
   --------------------------------------------------

   fps <= fps_digits & fps_blank & view_text;

   i_cdc_data : entity work.cdc_data
      generic map (
         G_DATA_SIZE => fps'length,
         G_INIT      => C_FPS_INIT
      )
      port map (
         s_clk_i   => main_clk_i,
         s_data_i  => fps,
         s_valid_i => fps_valid,
         m_clk_i   => vga_clk_i,
         m_data_o  => vga_fps
      ); -- i_cdc_data

   vga_fps_digits <= vga_fps(139 downto 108);
   vga_fps_blank  <= vga_fps(107 downto 100);
   vga_view_text  <= vga_fps( 99 downto   0);


   --------------------------------------------------
   -- Instantiate VGA clock domain
   --------------------------------------------------

   i_vga : entity work.vga
      generic map (
         G_MODE       => G_VIDEO,
         G_COL_STRIDE => G_COL_STRIDE,
         G_ADDR_BITS  => G_ADDR_BITS
      )
      port map (
         clk_i        => vga_clk_i,
         rd_addr_o    => rd_addr,
         rd_data_i    => rd_data,
         palette_i    => sw_i(1 downto 0),
         move_i       => sw_i(3),
         fps_digits_i => vga_fps_digits,
         fps_blank_i  => vga_fps_blank,
         view_text_i  => vga_view_text,
         vga_hs_o     => vga_hs_o,
         vga_vs_o     => vga_vs_o,
         vga_de_o     => vga_de_o,
         vga_col_o    => vga_col_o
      ); -- i_vga

end architecture structural;
