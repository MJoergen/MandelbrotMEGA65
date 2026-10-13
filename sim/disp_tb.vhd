-- This is a self-checking testbench for the conversion of the iteration counts
-- to colours (disp.vhd, with the palettes in palette_pkg.vhd), in particular
-- the movement of the palette. It uses a very small video mode, so that many
-- frames can be simulated. The palette is offset by a value that is
-- incremented modulo 511 for every G_FRAMES_PER_STEP frames (here 2) while
-- vga_move_i is set. It checks:
-- * The colour of every pixel in 2200 frames, i.e. more than two
--   turns through all 511 offsets, for all four palettes: it must be the
--   colour of the count minus the offset (modulo 511) in the palette, and the
--   colour of the set for the count 511. The expected colours are calculated
--   here from the tables C_PALETTES, not with palette_colour. The counts of
--   the pixels are different in every frame, and include 0, 510, and 511.
-- * The offset is incremented by one for every second frame, it wraps from 510
--   to 0, and it stays the same while vga_move_i is cleared (during a few
--   frames in the middle of the test), and for the whole of every frame.
-- * The colour is black and vga_de_o is low outside the visible area, and
--   vga_de_o is high inside.
-- The model of the offset is updated at the start of the vertical sync pulse,
-- like disp.vhd. This is far from the visible area, so every pixel is checked
-- against the offset that is used for it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.palette_pkg.all;
use work.video_pkg.all;

entity disp_tb is
end entity disp_tb;

architecture simulation of disp_tb is

   constant C_MODE : video_mode_t := (
      h_visible => 8, h_front => 2, h_sync => 2, h_back => 2,
      v_visible => 4, v_front => 1, v_sync => 1, v_back => 2,
      sync_active => '1');

   constant C_FRAMES_PER_STEP : positive := 2;
   constant C_FRAMES          : natural  := 2200;

   -- The frames in which the movement is stopped
   constant C_STOP_START : natural := 400;
   constant C_STOP_END   : natural := 460;

   signal clk      : std_logic;
   signal pix_x    : std_logic_vector(10 downto 0);
   signal pix_y    : std_logic_vector(10 downto 0);
   signal palette  : std_logic_vector(1 downto 0) := "00";
   signal move     : std_logic                    := '1';
   signal col_d3   : std_logic_vector(8 downto 0);
   signal vga_de   : std_logic;
   signal vga_col  : std_logic_vector(7 downto 0);

   -- The count of the pixel (x, y) in a frame. It is different in every frame.
   function count (x : natural; y : natural; frame : natural) return natural is
   begin
      return (x*61 + y*149 + frame*53 + ((x*y*frame) mod 7)) mod 512;
   end function count;

   -- The expected colour of the count cnt in the palette sel, offset by off,
   -- from the tables
   function expected (sel : natural; cnt : natural; off : natural)
      return std_logic_vector is
   begin
      if cnt = C_SET then
         return C_SET_COLOURS(sel);
      end if;
      return C_PALETTES(sel)((cnt + C_SET - off) mod C_SET);
   end function expected;

   signal frame_no : natural := 0;   -- The number of vertical sync pulses
   signal offset   : natural := 0;   -- The expected offset
   signal wraps    : natural := 0;   -- The number of times the offset wrapped

   -- The count of the pixel delayed by one to three clock cycles
   type cnt_vector is array (1 to 3) of natural;
   signal cnt_d    : cnt_vector := (others => 0);

   -- The expected colour, and whether the pixel is visible, delayed by one to
   -- four clock cycles
   type col_vector is array (1 to 4) of std_logic_vector(7 downto 0);
   signal exp_col_d : col_vector := (others => (others => '0'));
   signal exp_de_d  : std_logic_vector(1 to 4) := (others => '0');

begin

   p_clk : process
   begin
      clk <= '0', '1' after 5 ns;
      wait for 10 ns;
   end process p_clk;

   i_pix : entity work.pix
      generic map (
         G_MODE => C_MODE
      )
      port map (
         clk_i   => clk,
         pix_x_o => pix_x,
         pix_y_o => pix_y
      ); -- i_pix

   col_d3 <= std_logic_vector(to_unsigned(cnt_d(3), 9));

   i_disp : entity work.disp
      generic map (
         G_MODE            => C_MODE,
         G_FRAMES_PER_STEP => C_FRAMES_PER_STEP
      )
      port map (
         vga_clk_i     => clk,
         vga_pix_x_i   => pix_x,
         vga_pix_y_i   => pix_y,
         vga_col_d3_i  => col_d3,
         vga_palette_i => palette,
         vga_move_i    => move,
         vga_hs_o      => open,
         vga_vs_o      => open,
         vga_de_o      => vga_de,
         vga_col_o     => vga_col
      ); -- i_disp


   ----------------------------
   -- Model
   ----------------------------

   p_model : process (clk)
      variable x_v       : natural;
      variable y_v       : natural;
      variable cnt_v     : natural;
      variable visible_v : boolean;
      variable frames_v  : natural := 0;   -- Frames since the last step
   begin
      if rising_edge(clk) then
         x_v       := to_integer(unsigned(pix_x));
         y_v       := to_integer(unsigned(pix_y));
         cnt_v     := count(x_v, y_v, frame_no);
         visible_v := x_v < C_MODE.h_visible and y_v < C_MODE.v_visible;

         -- The pixel, and the expected colour, through the pipeline
         cnt_d(1)   <= cnt_v;
         cnt_d(2 to 3) <= cnt_d(1 to 2);
         exp_de_d(2 to 4)  <= exp_de_d(1 to 3);
         exp_col_d(2 to 4) <= exp_col_d(1 to 3);
         exp_de_d(1)       <= '0';
         exp_col_d(1)      <= (others => '0');
         if visible_v then
            exp_de_d(1)  <= '1';
            exp_col_d(1) <= expected(to_integer(unsigned(palette)), cnt_v, offset);
         end if;

         -- The start of the vertical sync pulse
         if x_v = 0 and y_v = C_MODE.v_visible + C_MODE.v_front then
            frame_no <= frame_no + 1;
            palette  <= std_logic_vector(to_unsigned((frame_no / 3) mod 4, 2));
            if frame_no >= C_STOP_START and frame_no < C_STOP_END then
               move <= '0';
            else
               move <= '1';
            end if;

            if frames_v = C_FRAMES_PER_STEP-1 then
               frames_v := 0;
               if move = '1' then
                  if offset = C_SET-1 then
                     offset <= 0;
                     wraps  <= wraps + 1;
                  else
                     offset <= offset + 1;
                  end if;
               end if;
            else
               frames_v := frames_v + 1;
            end if;
         end if;
      end if;
   end process p_model;


   ----------------------------
   -- Checking
   ----------------------------

   p_check : process
      variable errors_v : natural := 0;
   begin
      -- Wait until the pipeline is filled
      for i in 1 to 10 loop
         wait until falling_edge(clk);
      end loop;

      while frame_no < C_FRAMES loop
         wait until falling_edge(clk);
         assert vga_de = exp_de_d(4)
            report "Wrong vga_de_o in frame " & to_string(frame_no)
            severity error;
         if vga_col /= exp_col_d(4) then
            if errors_v < 10 then
               report "Wrong colour in frame " & to_string(frame_no) & ": got " &
                      to_string(vga_col) & ", expected " & to_string(exp_col_d(4)) &
                      " (offset " & to_string(offset) & ")"
                  severity error;
            end if;
            errors_v := errors_v + 1;
         end if;
      end loop;

      assert errors_v = 0
         report to_string(errors_v) & " pixels with the wrong colour"
         severity error;
      assert wraps >= 2
         report "The offset wrapped " & to_string(wraps) & " times, expected at least 2"
         severity error;

      report "disp_tb: finished";
      std.env.finish;
   end process p_check;

end architecture simulation;
