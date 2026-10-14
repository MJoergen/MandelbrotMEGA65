-- This module controls the view, i.e. the position of the top left corner of
-- the picture (startx, starty) and the size of a pixel (stepx, stepy), all in
-- 2.33 fixed point format. The view is changed by the buttons, once for each
-- pulse on upd_i:
--   btn_i(4)         : Zoom in, or zoom out if zoom_out_i is set. The size of
--                      a pixel changes by 1/64 of its value plus one LSB.
--   btn_i(3 downto 2): Pan left and right by C_PAN_PIXELS pixels.
--   btn_i(1 downto 0): Pan up and down by C_PAN_PIXELS pixels.
-- The pan step is a constant fraction (1/C_PAN_FRACTION) of the width of the
-- picture, i.e. 2 pixels for 640 columns and 4 pixels for 1280 columns, so
-- panning takes the same time on every board. Panning up and down uses the
-- same number of pixels as left and right.
--
-- The view is always kept inside the range of the number format, i.e. -2 to 2
-- (not including 2), so that the values of cx and cy calculated by the
-- dispatcher and the job modules never wrap around. This means:
-- * The left (top) edge is never less than -2. Panning stops there.
-- * The right (bottom) edge, i.e. the value of the last column (row), is never
--   2 or more. Panning stops there.
-- * The size of a pixel is at least one LSB (2^-33). Zooming in stops there.
-- * Zooming keeps the centre of the picture fixed, i.e. the pixel in column
--   G_NUM_COLS/2 and row G_NUM_ROWS/2 (just right of and below the centre of
--   the screen) shows the same point before and after the zoom. When zooming
--   out would move an edge out of range, the view is moved instead, so the
--   edge stays at the end of the range. Zooming out stops when the view can
--   not get any larger.
--
-- Internally the positions are handled in offset binary, i.e. as the value
-- plus 2, which is in the range 0 to 4. This is the fixed point value with the
-- sign bit inverted, interpreted as an unsigned number. The values have 35
-- bits.
--
-- The update is calculated over several clock cycles (17, or 18 for 1280
-- columns), one small step at a time, because all of it in a single clock
-- cycle is far too slow for the MAIN clock. The outputs are all changed at
-- the same time, at the end of the update. Pulses on upd_i during an update
-- are ignored.
--
-- The calculation of one axis is in viewport_axis.vhd, instantiated for x and
-- for y. This module holds the state machine, which is common to both axes, and
-- combines the decision to zoom: The size of a pixel is only changed if the
-- new size is in range in both axes.

library ieee;
use ieee.std_logic_1164.all;

use work.viewport_pkg.all;

entity viewport is
   generic (
      G_NUM_COLS : integer;
      G_NUM_ROWS : integer;
      G_START_X  : real;     -- Initial view
      G_START_Y  : real;
      G_SIZE_X   : real;
      G_SIZE_Y   : real
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      upd_i      : in  std_logic;
      btn_i      : in  std_logic_vector( 4 downto 0);  -- "CLRUD"
      zoom_out_i : in  std_logic;
      startx_o   : out std_logic_vector(34 downto 0);
      starty_o   : out std_logic_vector(34 downto 0);
      stepx_o    : out std_logic_vector(34 downto 0);
      stepy_o    : out std_logic_vector(34 downto 0)
   );
end entity viewport;

architecture rtl of viewport is

   -- The pan step in pixels, a fraction of the number of columns
   constant C_PAN_FRACTION : positive := 320;
   constant C_PAN_PIXELS   : positive := maximum(1, G_NUM_COLS / C_PAN_FRACTION);

   signal state   : state_t := IDLE_ST;

   signal zoom_okx : std_logic;
   signal zoom_oky : std_logic;
   signal zoom     : std_logic;
   signal donex    : std_logic;
   signal doney    : std_logic;

begin

   zoom <= zoom_okx and zoom_oky;

   i_viewport_axis_x : entity work.viewport_axis
      generic map (
         G_NUM_PIXELS => G_NUM_COLS,
         G_PAN_PIXELS => C_PAN_PIXELS,
         G_START      => G_START_X,
         G_SIZE       => G_SIZE_X
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         state_i    => state,
         upd_i      => upd_i,
         zoom_btn_i => btn_i(4),
         inc_btn_i  => btn_i(2),
         dec_btn_i  => btn_i(3),
         zoom_out_i => zoom_out_i,
         zoom_i     => zoom,
         zoom_ok_o  => zoom_okx,
         done_o     => donex,
         start_o    => startx_o,
         step_o     => stepx_o
      ); -- i_viewport_axis_x

   i_viewport_axis_y : entity work.viewport_axis
      generic map (
         G_NUM_PIXELS => G_NUM_ROWS,
         G_PAN_PIXELS => C_PAN_PIXELS,
         G_START      => G_START_Y,
         G_SIZE       => G_SIZE_Y
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         state_i    => state,
         upd_i      => upd_i,
         zoom_btn_i => btn_i(4),
         inc_btn_i  => btn_i(0),
         dec_btn_i  => btn_i(1),
         zoom_out_i => zoom_out_i,
         zoom_i     => zoom,
         zoom_ok_o  => zoom_oky,
         done_o     => doney,
         start_o    => starty_o,
         step_o     => stepy_o
      ); -- i_viewport_axis_y

   p_state : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case state is
            when IDLE_ST =>
               if upd_i = '1' then
                  state <= ZOOM_ST;
               end if;

            when ZOOM_ST =>
               state <= STEP_ST;

            when STEP_ST =>
               state <= PREP_ST;

            when PREP_ST =>
               state <= MULT_ST;

            when MULT_ST =>
               if donex = '1' and doney = '1' then
                  state <= CENTRE_ST;
               end if;

            when CENTRE_ST =>
               state <= PAN_ST;

            when PAN_ST =>
               state <= CLAMP_ST;

            when CLAMP_ST =>
               state <= IDLE_ST;
         end case;

         if rst_i = '1' then
            state <= IDLE_ST;
         end if;
      end if;
   end process p_state;

end architecture rtl;
