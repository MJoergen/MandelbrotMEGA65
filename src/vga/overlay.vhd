-- This module shows a line of text as an overlay at the top of the VGA
-- output: the view (the centre and the zoom, see view_text.vhd) on the left,
-- and the frame rate (the same value as on the 7-segment display) on the
-- right, see vga.vhd. The text has G_CHARS characters (see text_pkg.vhd),
-- shown in white on a black background with the 16x32 font in font_pkg.vhd.
-- The characters with the code 15 (e.g. the blanked leading zeros of the
-- frame rate) are not shown, i.e. the picture is shown there.
--
-- The text is calculated in the MAIN clock domain (view_text.vhd and fps.vhd),
-- and it is moved to the VGA clock domain in the top level module, so chars_i
-- is in the VGA clock domain. It may change at any time: the text is copied at
-- the first pixel of each frame (pixel (0,0)), well before the rows of the
-- overlay, so a new text is shown from the next frame on, and a frame never
-- shows two different texts.
--
-- The overlay is added to the output of disp.vhd, which is delayed by one
-- clock cycle (all of vga_hs_o, vga_vs_o, vga_de_o, and vga_col_o). The pixel
-- counters (vga_pix_x_i and vga_pix_y_i) are those of the pixel, which is at
-- the input (vga_col_d4_i) four clock cycles later.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.font_pkg.all;
use work.text_pkg.all;

entity overlay is
   generic (
      G_CHARS : natural;
      G_X     : natural;                      -- Left edge of the overlay
      G_Y     : natural := 8                  -- Top edge of the overlay
   );
   port (
      vga_clk_i    : in  std_logic;

      -- The text (in the VGA clock domain), see text_pkg.vhd
      chars_i      : in  std_logic_vector(4*G_CHARS-1 downto 0);

      vga_pix_x_i  : in  std_logic_vector(10 downto 0);
      vga_pix_y_i  : in  std_logic_vector(10 downto 0);
      vga_hs_d4_i  : in  std_logic;
      vga_vs_d4_i  : in  std_logic;
      vga_de_d4_i  : in  std_logic;
      vga_col_d4_i : in  std_logic_vector(7 downto 0);

      vga_hs_o     : out std_logic;
      vga_vs_o     : out std_logic;
      vga_de_o     : out std_logic;
      vga_col_o    : out std_logic_vector(7 downto 0)
   );
end entity overlay;

architecture rtl of overlay is

   constant C_WIDTH   : natural := 16;                          -- Size of a character in pixels
   constant C_HEIGHT  : natural := 32;
   constant C_FG      : std_logic_vector(7 downto 0) := X"FF";  -- White
   constant C_BG      : std_logic_vector(7 downto 0) := X"00";  -- Black

   -- The text shown in the current frame
   signal chars       : std_logic_vector(4*G_CHARS-1 downto 0) := (others => '1');

   -- Stage 1: The position inside the overlay
   signal show_d1     : std_logic := '0';
   signal pos_d1      : natural range 0 to G_CHARS-1 := 0;   -- Leftmost is 0
   signal col_d1      : std_logic_vector(3 downto 0) := (others => '0');
   signal row_d1      : std_logic_vector(4 downto 0) := (others => '0');

   -- Stage 2: The character
   signal show_d2     : std_logic := '0';
   signal char_d2     : std_logic_vector(3 downto 0) := (others => '0');
   signal col_d2      : std_logic_vector(3 downto 0) := (others => '0');
   signal row_d2      : std_logic_vector(4 downto 0) := (others => '0');

   -- Stage 3: The row of the character from the font
   signal show_d3     : std_logic := '0';
   signal font_d3     : std_logic_vector(C_WIDTH-1 downto 0);
   signal col_d3      : std_logic_vector(3 downto 0) := (others => '0');

   -- Stage 4: The pixel of the character
   signal show_d4     : std_logic := '0';
   signal fg_d4       : std_logic;

   -- Stage 5: Output
   signal vga_hs_d5   : std_logic;
   signal vga_vs_d5   : std_logic;
   signal vga_de_d5   : std_logic;
   signal vga_col_d5  : std_logic_vector(7 downto 0);

begin

   --------------------------------------------------
   -- Change the text shown at the start of a frame
   --------------------------------------------------

   p_value : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         if vga_pix_x_i = 0 and vga_pix_y_i = 0 then
            chars <= chars_i;
         end if;
      end if;
   end process p_value;


   --------------------------------------------------
   -- Generate the overlay
   --------------------------------------------------

   p_overlay : process (vga_clk_i)
      variable x_v    : std_logic_vector(10 downto 0);
      variable y_v    : std_logic_vector(10 downto 0);
      variable char_v : std_logic_vector( 3 downto 0);
   begin
      if rising_edge(vga_clk_i) then
         -- Stage 1
         x_v := vga_pix_x_i - G_X;
         y_v := vga_pix_y_i - G_Y;
         show_d1 <= '0';
         if vga_pix_x_i >= G_X and vga_pix_x_i < G_X + C_WIDTH*G_CHARS and
            vga_pix_y_i >= G_Y and vga_pix_y_i < G_Y + C_HEIGHT
         then
            show_d1 <= '1';
         end if;
         -- Outside the overlay the position is not used, so it is only
         -- limited to the range.
         pos_d1 <= G_CHARS-1;
         if x_v(10 downto 4) < G_CHARS then
            pos_d1 <= to_integer(x_v(10 downto 4));
         end if;
         col_d1 <= x_v(3 downto 0);
         row_d1 <= y_v(4 downto 0);

         -- Stage 2. The leftmost character is in the highest bits.
         char_v  := chars(4*(G_CHARS-1-pos_d1)+3 downto 4*(G_CHARS-1-pos_d1));
         show_d2 <= '0';
         if show_d1 = '1' and char_v /= C_CHAR_NONE then
            show_d2 <= '1';
         end if;
         char_d2 <= char_v;
         col_d2  <= col_d1;
         row_d2  <= row_d1;

         -- Stage 3
         show_d3 <= show_d2;
         font_d3 <= C_FONT(to_integer(char_d2 & row_d2));
         col_d3  <= col_d2;

         -- Stage 4
         show_d4 <= show_d3;
         fg_d4   <= font_d3(C_WIDTH-1-to_integer(col_d3));

         -- Stage 5
         vga_col_d5 <= vga_col_d4_i;
         if show_d4 = '1' then
            vga_col_d5 <= C_FG when fg_d4 = '1' else C_BG;
         end if;
         vga_hs_d5 <= vga_hs_d4_i;
         vga_vs_d5 <= vga_vs_d4_i;
         vga_de_d5 <= vga_de_d4_i;
      end if;
   end process p_overlay;


   --------------------------
   -- Connect output signals
   --------------------------

   vga_hs_o  <= vga_hs_d5;
   vga_vs_o  <= vga_vs_d5;
   vga_de_o  <= vga_de_d5;
   vga_col_o <= vga_col_d5;

end architecture rtl;
