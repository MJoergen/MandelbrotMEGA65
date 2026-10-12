-- This module runs entirely in the VGA clock domain. It generates the pixel
-- position, reads the value of each pixel from the display memory, converts it
-- to a colour with the palette selected by palette_i, and generates the VGA
-- output signals for the video mode G_MODE (see video_pkg.vhd). A line of text
-- is shown at the top, see overlay.vhd: the view (the centre and the zoom, see
-- view_text.vhd) in the top left corner, and the frame rate in the top right
-- corner.
--
-- The address of the pixel in column x and row y of the picture is
-- x*G_COL_STRIDE + y, with G_ADDR_BITS bits, the same as in dispatcher.vhd.
--
-- The read latency of the display memory is four clock cycles (see
-- disp_mem.vhd). disp.vhd and overlay.vhd expect three clock cycles, so they
-- get the pixel counters delayed by one clock cycle.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.util_pkg.all;
use work.video_pkg.all;
use work.text_pkg.all;

entity vga is
   generic (
      G_MODE       : video_mode_t;
      G_COL_STRIDE : positive;
      G_ADDR_BITS  : positive
   );
   port (
      clk_i        : in  std_logic;                      -- The pixel clock

      -- Read port of the display memory
      rd_addr_o    : out std_logic_vector(G_ADDR_BITS-1 downto 0);
      rd_data_i    : in  std_logic_vector( 8 downto 0);

      -- Selects the palette, see palette_pkg.vhd. This is asynchronous (from
      -- the switches), and it is synchronized here.
      palette_i    : in  std_logic_vector( 1 downto 0);

      -- The frame rate, moved from the MAIN clock domain in the top level
      -- (mega65.vhd or nexys4ddr.vhd), see overlay.vhd
      fps_digits_i : in  std_logic_vector(31 downto 0);
      fps_blank_i  : in  std_logic_vector( 7 downto 0);

      -- The view, moved from the MAIN clock domain together with the frame
      -- rate, see view_text.vhd and text_pkg.vhd
      view_text_i  : in  std_logic_vector(99 downto 0);

      vga_hs_o     : out std_logic;
      vga_vs_o     : out std_logic;
      vga_de_o     : out std_logic;                       -- Visible area
      vga_col_o    : out std_logic_vector( 7 downto 0)    -- RRRGGGBB
   );
end entity vga;

architecture structural of vga is

   -- The number of bits of the rows in the visible area
   constant C_ROW_BITS : natural := log2(G_MODE.v_visible);

   -- The line of text of the overlay, from 8 pixels from the left edge to 8
   -- pixels from the right edge, in characters of 16 pixels (see
   -- overlay.vhd): 79 characters for 1280 pixels, and 39 for 640. The view is
   -- on the left, and the frame rate (C_DIGITS digits) on the right, with the
   -- characters in between not shown.
   constant C_DIGITS   : natural := fps_blank_i'length;
   constant C_VIEW     : natural := view_text_i'length / 4;
   constant C_CHARS    : natural := (G_MODE.h_visible - 16) / 16;
   constant C_GAP      : natural := C_CHARS - C_VIEW - C_DIGITS;

   -- The frame rate as characters, with the blanked digits not shown
   signal fps_chars : std_logic_vector(4*C_DIGITS-1 downto 0);
   signal chars     : std_logic_vector(4*C_CHARS-1 downto 0);

   signal pix_x : std_logic_vector(10 downto 0);
   signal pix_y : std_logic_vector(10 downto 0);

   -- The pixel counters for disp and overlay, delayed by one clock cycle
   signal disp_x : std_logic_vector(10 downto 0) := (others => '0');
   signal disp_y : std_logic_vector(10 downto 0) := (others => '0');

   -- The address of the pixel, and the address of its column. Only the lowest
   -- G_ADDR_BITS bits are used. The multiplication by the constant G_COL_STRIDE uses
   -- LUTs, because the DSPs are for the iterators. When G_COL_STRIDE is
   -- 2**C_ROW_BITS (as on both boards), it is only wires.
   signal rd_addr : std_logic_vector(21 downto 0);
   signal rd_col  : std_logic_vector(21 downto 0);

   attribute use_dsp : string;
   attribute use_dsp of rd_col : signal is "no";

   signal disp_hs  : std_logic;
   signal disp_vs  : std_logic;
   signal disp_de  : std_logic;
   signal disp_col : std_logic_vector(7 downto 0);

   signal palette_meta : std_logic_vector(1 downto 0) := "00";
   signal palette_sync : std_logic_vector(1 downto 0) := "00";

   attribute async_reg : string;
   attribute async_reg of palette_meta : signal is "true";
   attribute async_reg of palette_sync : signal is "true";

begin

   assert G_COL_STRIDE >= G_MODE.v_visible and
          (G_MODE.h_visible-1)*G_COL_STRIDE + G_MODE.v_visible <= 2**G_ADDR_BITS
      report "The picture does not fit in the display memory"
      severity failure;

   -- The column stride is multiplied as 11 bits, and the address has at most
   -- the 22 bits of rd_addr
   assert G_COL_STRIDE < 2**11 and G_ADDR_BITS <= rd_addr'length
      report "The column stride must be less than 2048, and the address at most 22 bits"
      severity failure;

   assert C_VIEW + C_DIGITS < C_CHARS
      report "The text does not fit in the line"
      severity failure;

   --------------------------------------------------
   -- Synchronize the palette selection
   --------------------------------------------------

   p_palette : process (clk_i)
   begin
      if rising_edge(clk_i) then
         palette_meta <= palette_i;
         palette_sync <= palette_meta;
      end if;
   end process p_palette;


   --------------------------------------------------
   -- Instantiate pixel counters
   --------------------------------------------------

   i_pix : entity work.pix
      generic map (
         G_MODE => G_MODE
      )
      port map (
         clk_i   => clk_i,
         pix_x_o => pix_x,
         pix_y_o => pix_y
      ); -- i_pix


   -- Outside the visible area the address is not used, so the row is reduced
   -- to C_ROW_BITS bits, and the address may wrap around.
   rd_col    <= pix_x * to_slv(G_COL_STRIDE, 11);
   rd_addr   <= rd_col + pix_y(C_ROW_BITS-1 downto 0);
   rd_addr_o <= rd_addr(G_ADDR_BITS-1 downto 0);

   p_disp_delay : process (clk_i)
   begin
      if rising_edge(clk_i) then
         disp_x <= pix_x;
         disp_y <= pix_y;
      end if;
   end process p_disp_delay;


   --------------------------------------------------
   -- Instantiate display
   --------------------------------------------------

   i_disp : entity work.disp
      generic map (
         G_MODE => G_MODE
      )
      port map (
         vga_clk_i     => clk_i,
         vga_pix_x_i   => disp_x,
         vga_pix_y_i   => disp_y,
         vga_col_d3_i  => rd_data_i,
         vga_palette_i => palette_sync,
         vga_hs_o      => disp_hs,
         vga_vs_o      => disp_vs,
         vga_de_o      => disp_de,
         vga_col_o     => disp_col
      ); -- i_disp


   --------------------------------------------------
   -- Instantiate the overlay of the view and the
   -- frame rate
   --------------------------------------------------

   gen_fps_chars : for i in 0 to C_DIGITS-1 generate
      fps_chars(4*i+3 downto 4*i) <= C_CHAR_NONE when fps_blank_i(i) = '1' else
                                     fps_digits_i(4*i+3 downto 4*i);
   end generate gen_fps_chars;

   chars <= view_text_i & (4*C_GAP-1 downto 0 => '1') & fps_chars;

   i_overlay : entity work.overlay
      generic map (
         G_CHARS => C_CHARS,
         G_X     => 8
      )
      port map (
         vga_clk_i    => clk_i,
         chars_i      => chars,
         vga_pix_x_i  => disp_x,
         vga_pix_y_i  => disp_y,
         vga_hs_d4_i  => disp_hs,
         vga_vs_d4_i  => disp_vs,
         vga_de_d4_i  => disp_de,
         vga_col_d4_i => disp_col,
         vga_hs_o     => vga_hs_o,
         vga_vs_o     => vga_vs_o,
         vga_de_o     => vga_de_o,
         vga_col_o    => vga_col_o
      ); -- i_overlay

end architecture structural;
