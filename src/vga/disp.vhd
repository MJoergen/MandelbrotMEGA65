-- This module generates the VGA output signals for the video mode G_MODE (see
-- video_pkg.vhd) from the pixel counters. The value of the pixel at
-- (vga_pix_x_i, vga_pix_y_i), i.e. its iteration count (9 bits), must be given
-- on vga_col_d3_i C_DISP_LATENCY (three) clock cycles later, see video_pkg.vhd
-- and vga.vhd. It is converted to the colour by the palette selected by
-- vga_palette_i (see palette_pkg.vhd). The colour is only output inside the
-- visible area, which is also shown by vga_de_o (data enable, used by the HDMI
-- output). Whether the pixel is in the visible area is decided from the pixel
-- counters, and only that bit is delayed.
--
-- While vga_move_i is set, the palette is offset by a value that is
-- incremented once for every G_FRAMES_PER_STEP frames (modulo 511, the number
-- of counts outside the set), so the colours seem to move towards the
-- set. The offset is changed at the start of the vertical sync pulse, so it
-- is the same for the whole picture. When vga_move_i is cleared, the
-- offset stays where it is.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.palette_pkg.all;
use work.video_pkg.all;

entity disp is
   generic (
      G_MODE            : video_mode_t;
      G_FRAMES_PER_STEP : positive := 6
   );
   port (
      vga_clk_i     : in  std_logic;
      vga_pix_x_i   : in  std_logic_vector(10 downto 0);
      vga_pix_y_i   : in  std_logic_vector(10 downto 0);
      vga_col_d3_i  : in  std_logic_vector(8 downto 0);
      vga_palette_i : in  std_logic_vector(1 downto 0);
      vga_move_i    : in  std_logic;
      vga_hs_o      : out std_logic;
      vga_vs_o      : out std_logic;
      vga_de_o      : out std_logic;
      vga_col_o     : out std_logic_vector(7 downto 0)
   );
end entity disp;

architecture rtl of disp is

   -- Define visible screen size
   constant C_H_PIXELS : natural := G_MODE.h_visible;
   constant C_V_PIXELS : natural := G_MODE.v_visible;

   -- Define VGA timing constants. The sync pulses are at the level
   -- G_MODE.sync_active, e.g. active low (negative polarity) for 640x480.
   constant C_HS_START : natural := G_MODE.h_visible + G_MODE.h_front;
   constant C_HS_TIME  : natural := G_MODE.h_sync;
   constant C_VS_START : natural := G_MODE.v_visible + G_MODE.v_front;
   constant C_VS_TIME  : natural := G_MODE.v_sync;

   signal vga_hs_d     : std_logic;
   signal vga_vs_d     : std_logic;
   signal vga_vis_d    : std_logic;

   signal vga_hs_d2    : std_logic;
   signal vga_vs_d2    : std_logic;
   signal vga_vis_d2   : std_logic;

   signal vga_hs_d3    : std_logic;
   signal vga_vs_d3    : std_logic;
   signal vga_vis_d3   : std_logic;

   -- The offset of the palette, and the frames since it was last changed
   signal vga_offset   : std_logic_vector(8 downto 0) := (others => '0');
   signal vga_frames   : natural range 0 to G_FRAMES_PER_STEP-1 := 0;

   signal vga_hs_d4    : std_logic;
   signal vga_vs_d4    : std_logic;
   signal vga_de_d4    : std_logic;
   signal vga_col_d4   : std_logic_vector(7 downto 0);

begin

   ----------------------------------------
   -- Generate VGA synchronization signals
   ----------------------------------------

   p_sync : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then

         vga_hs_d <= not G_MODE.sync_active;
         vga_vs_d <= not G_MODE.sync_active;

         if vga_pix_x_i >= C_HS_START and vga_pix_x_i < C_HS_START+C_HS_TIME then
            vga_hs_d   <= G_MODE.sync_active;
         end if;

         if vga_pix_y_i >= C_VS_START and vga_pix_y_i < C_VS_START+C_VS_TIME then
            vga_vs_d   <= G_MODE.sync_active;
         end if;

         vga_vis_d <= '0';
         if vga_pix_x_i < C_H_PIXELS and vga_pix_y_i < C_V_PIXELS then
            vga_vis_d <= '1';
         end if;
      end if;
   end process p_sync;


   ----------------------------------------
   -- Move the palette
   ----------------------------------------

   p_offset : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         if vga_pix_x_i = 0 and vga_pix_y_i = C_VS_START then
            if vga_frames = G_FRAMES_PER_STEP-1 then
               vga_frames <= 0;
               if vga_move_i = '1' then
                  if vga_offset = C_SET-1 then
                     vga_offset <= (others => '0');
                  else
                     vga_offset <= vga_offset + 1;
                  end if;
               end if;
            else
               vga_frames <= vga_frames + 1;
            end if;
         end if;
      end if;
   end process p_offset;


   ------------------------------------------------------------------
   -- Add two more pipeline stages, so the total delay of three clock
   -- cycles matches the read latency of the display memory (see above)
   ------------------------------------------------------------------

   p_pipe : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         vga_hs_d2    <= vga_hs_d;
         vga_vs_d2    <= vga_vs_d;
         vga_vis_d2   <= vga_vis_d;

         vga_hs_d3    <= vga_hs_d2;
         vga_vs_d3    <= vga_vs_d2;
         vga_vis_d3   <= vga_vis_d2;
      end if;
   end process p_pipe;


   ---------------------------
   -- Generate output signals
   ---------------------------

   p_out : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         vga_col_d4 <= (others => '0');
         vga_de_d4  <= '0';

         -- Only set colour output inside visible area
         if vga_vis_d3 = '1' then
            vga_col_d4 <= palette_colour(vga_palette_i, vga_col_d3_i, vga_offset);
            vga_de_d4  <= '1';
         end if;

         vga_hs_d4 <= vga_hs_d3;
         vga_vs_d4 <= vga_vs_d3;
      end if;
   end process p_out;


   --------------------------
   -- Connect output signals
   --------------------------

   vga_hs_o  <= vga_hs_d4;
   vga_vs_o  <= vga_vs_d4;
   vga_de_o  <= vga_de_d4;
   vga_col_o <= vga_col_d4;

end architecture rtl;

