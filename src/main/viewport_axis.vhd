-- This module controls the view along one axis, i.e. the position of the
-- first column (row) and the size of a pixel, both in 2.33 fixed point format.
-- It is instantiated twice by viewport.vhd, once for x and once for y. See
-- viewport.vhd for the description of the view, and of the limits that are
-- kept.
--
-- The module has no state machine of its own. The state is given by
-- viewport, so that both axes are always in the same step of the update, and
-- change their outputs at the same time. The only thing shared between the
-- axes is the decision to zoom, which needs the new size of a pixel to be in
-- range in both: zoom_ok_o says that this axis wants to zoom, and that the
-- new size is in range, and zoom_i is the combined decision of both axes.
-- zoom_ok_o is valid in STEP_ST, and zoom_i is used in STEP_ST.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;
use ieee.math_real.all;

use work.viewport_pkg.all;

entity viewport_axis is
   generic (
      G_NUM_PIXELS : integer;  -- Number of columns (rows)
      G_PAN_PIXELS : positive; -- Pan step in pixels
      G_START      : real;     -- Initial view
      G_SIZE       : real
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      state_i    : in  state_t;
      upd_i      : in  std_logic;
      zoom_btn_i : in  std_logic;
      inc_btn_i  : in  std_logic;  -- Pan towards larger values (right, down)
      dec_btn_i  : in  std_logic;  -- Pan towards smaller values (left, up)
      zoom_out_i : in  std_logic;
      zoom_i     : in  std_logic;
      zoom_ok_o  : out std_logic;
      done_o     : out std_logic;  -- The serial multiplications are finished
      start_o    : out std_logic_vector(34 downto 0);
      step_o     : out std_logic_vector(34 downto 0)
   );
end entity viewport_axis;

architecture rtl of viewport_axis is

   -- The number of fraction bits, and the number of bits of the values
   constant C_FRAC_BITS : natural := 33;
   constant C_BITS      : natural := C_FRAC_BITS + 2;

   -- Convert a real number r, which is an integer from 0 to 2^bits-1, to a
   -- vector. It is converted in two parts, because it may not fit in an
   -- integer.
   function to_slv (r : real; bits : natural) return std_logic_vector is
      variable hi_v : real := floor(r / 2.0**16);
   begin
      return to_slv(natural(hi_v), bits-16) & to_slv(natural(r - hi_v * 2.0**16), 16);
   end function to_slv;

   -- The largest position, i.e. 2-2^-C_FRAC_BITS, in offset binary. Some of
   -- the constants (e.g. this one) do not fit in an integer, so they are
   -- calculated as real numbers, which are exact for integers up to 2^53.
   constant C_MAX_POS_R : real := 2.0**C_BITS - 1.0;
   constant C_MAX_POS   : std_logic_vector(C_BITS-1 downto 0) := (others => '1');

   -- The smallest size of a pixel (one LSB)
   constant C_MIN_STEP  : natural := 1;

   -- The largest size of a pixel, such that the view from the first to the
   -- last column (row), i.e. step*(num-1), is at most C_MAX_POS. For a small
   -- picture (e.g. in the testbenches) this does not fit in an integer.
   constant C_MAX_STEP_R : real := floor(C_MAX_POS_R / real(G_NUM_PIXELS-1));
   constant C_MAX_STEP   : std_logic_vector(C_BITS-1 downto 0) := to_slv(C_MAX_STEP_R, C_BITS);

   -- The column (row) of the pixel that is kept fixed when zooming
   constant C_CENTRE    : natural := G_NUM_PIXELS/2;

   -- Inverts the sign bit, to convert between fixed point and offset binary
   constant C_SIGN      : std_logic_vector(C_BITS-1 downto 0) := '1' & (C_BITS-2 downto 0 => '0');

   -- Initial view, as real numbers. The position is in offset binary, rounded
   -- to the nearest integer, and the size of a pixel is rounded down (after
   -- rounding the size of the view). They are checked below.
   constant C_INIT_POS  : real := floor((G_START+2.0) * 2.0**C_FRAC_BITS + 0.5);
   constant C_INIT_D    : real :=
      floor(floor(G_SIZE * 2.0**C_FRAC_BITS + 0.5) / real(G_NUM_PIXELS));

   -- The same in fixed point format. The values are limited to the range of
   -- the format here, so that an initial view outside the range is reported by
   -- the checks below, and not as an error in the conversion.
   constant C_INIT_START : std_logic_vector(C_BITS-1 downto 0) :=
      to_slv(realmax(0.0, realmin(C_INIT_POS, C_MAX_POS_R)), C_BITS) xor C_SIGN;
   constant C_INIT_STEP  : std_logic_vector(C_BITS-1 downto 0) :=
      to_slv(realmax(0.0, realmin(C_INIT_D, C_MAX_POS_R)), C_BITS);

   -- The outputs
   signal start : std_logic_vector(C_BITS-1 downto 0);
   signal step  : std_logic_vector(C_BITS-1 downto 0);

   -- The new view, while it is calculated
   signal zoom_btn : std_logic := '0';
   signal inc_btn  : std_logic;
   signal dec_btn  : std_logic;
   signal zoom_out : std_logic;
   signal pos      : std_logic_vector(C_BITS downto 0);    -- Offset binary
   signal d        : std_logic_vector(C_BITS-1 downto 0);  -- Size of a pixel
   signal delta    : std_logic_vector(C_BITS downto 0);    -- Change of size when zooming
   signal zoomed   : std_logic;                            -- The size has been changed

   -- Size of a pixel after zooming
   signal zoom     : std_logic_vector(C_BITS downto 0) := (others => '0');

   -- Serial multiplication by the constant number of columns (rows) minus one,
   -- one bit of the constant per clock cycle. The product is subtracted from
   -- C_MAX_POS, which gives the largest position of the first column (row).
   -- The multiplication uses only shifts and subtractions. This makes sure
   -- that synthesis does not use a DSP for it, because they are all used by
   -- the iterators.
   signal mult     : std_logic_vector(C_BITS+10 downto 0);
   signal k        : std_logic_vector(10 downto 0) := (others => '0');
   signal lim      : std_logic_vector(C_BITS+10 downto 0);

   -- Serial multiplication of the change of the size of a pixel (delta) by
   -- the column (row) of the centre, at the same time as the one above. This
   -- gives the distance the first column (row) must move, to keep the centre
   -- fixed when zooming. This is small: delta is at most C_MAX_STEP/64+1, so
   -- off is less than 2^C_BITS.
   signal multd    : std_logic_vector(C_BITS downto 0);
   signal kc       : std_logic_vector(10 downto 0) := (others => '0');
   signal off      : std_logic_vector(C_BITS downto 0);

   -- Serial multiplication of the size of a pixel (d) by G_PAN_PIXELS, at the
   -- same time as the ones above, and using the same shifted multiplicand
   -- (mult). This gives the pan step. It is small: d is at most C_MAX_STEP,
   -- and G_PAN_PIXELS is less than G_NUM_PIXELS-1, so pan is less than
   -- 2^C_BITS. Only the lower C_BITS+1 bits of mult are used, which is enough,
   -- because when mult is added it is at most the final value of pan.
   signal kp       : std_logic_vector(10 downto 0) := (others => '0');
   signal pan      : std_logic_vector(C_BITS downto 0);

begin

   assert G_NUM_PIXELS <= 2**11
      report "The serial multiplication only supports constants below 2^11"
      severity failure;

   -- The initial view must be inside the range, like the view after every
   -- update: The first column (row) is at least -2, the last column (row) is
   -- less than 2, and the size of a pixel is at least one LSB.
   assert C_INIT_POS >= 0.0
      report "The initial view starts below -2"
      severity failure;

   assert C_INIT_D >= real(C_MIN_STEP)
      report "The initial size of a pixel is less than one LSB"
      severity failure;

   assert C_INIT_D <= C_MAX_STEP_R and
          C_INIT_POS + C_INIT_D*real(G_NUM_PIXELS-1) <= C_MAX_POS_R
      report "The initial view ends at 2 or above"
      severity failure;

   -- The size of a pixel after zooming is in range
   zoom_ok_o <= '1' when zoom_btn = '1' and
                         zoom >= C_MIN_STEP and zoom <= C_MAX_STEP else
                '0';

   done_o <= '1' when k = 0 and kc = 0 and kp = 0 else
             '0';

   p_axis : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case state_i is
            when IDLE_ST =>
               if upd_i = '1' then
                  zoom_btn <= zoom_btn_i;
                  inc_btn  <= inc_btn_i;
                  dec_btn  <= dec_btn_i;
                  zoom_out <= zoom_out_i;
                  pos      <= "0" & (start xor C_SIGN);
                  d        <= step;
                  delta    <= ("0000000" & step(C_BITS-1 downto 6)) + 1;
               end if;

            when ZOOM_ST =>
               -- The size of a pixel changes by 1/64 of its value plus one LSB.
               -- When zooming in this is never negative, because d is at least
               -- one LSB.
               if zoom_out = '1' then
                  zoom <= ("0" & d) + delta;
               else
                  zoom <= ("0" & d) - delta;
               end if;

            when STEP_ST =>
               -- Zoom. This is only done if the new view fits in the range, in
               -- both axes.
               zoomed <= '0';
               if zoom_i = '1' then
                  d      <= zoom(C_BITS-1 downto 0);
                  zoomed <= '1';
               end if;

            when PREP_ST =>
               -- Prepare the multiplications
               mult  <= "00000000000" & d;
               k     <= to_std_logic_vector(G_NUM_PIXELS-1, 11);
               lim   <= "00000000000" & C_MAX_POS;
               multd <= delta;
               kc    <= to_std_logic_vector(C_CENTRE, 11);
               off   <= (others => '0');
               kp    <= to_std_logic_vector(G_PAN_PIXELS, 11);
               pan   <= (others => '0');

            when MULT_ST =>
               -- Calculate lim = C_MAX_POS - d*(G_NUM_PIXELS-1). This is never
               -- negative, because d is at most C_MAX_STEP.
               if k(0) = '1' then
                  lim <= lim - mult;
               end if;
               mult <= mult(C_BITS+9 downto 0) & "0";
               k    <= "0" & k(10 downto 1);

               -- Calculate off = delta*C_CENTRE
               if kc(0) = '1' then
                  off <= off + multd;
               end if;
               multd <= multd(C_BITS-1 downto 0) & "0";
               kc    <= "0" & kc(10 downto 1);

               -- Calculate pan = d*G_PAN_PIXELS
               if kp(0) = '1' then
                  pan <= pan + mult(C_BITS downto 0);
               end if;
               kp <= "0" & kp(10 downto 1);

            when CENTRE_ST =>
               -- Keep the centre fixed when zooming: When the size of a pixel
               -- decreases by delta (zoom in), the first column moves right
               -- by delta*C_CENTRE, and the other way around (zoom out). It
               -- is never moved to before the start of the range. The right
               -- (bottom) edge is checked at the end.
               if zoomed = '1' then
                  if zoom_out = '0' then
                     pos <= pos + off;
                  else
                     if pos >= off then
                        pos <= pos - off;
                     else
                        pos <= (others => '0');
                     end if;
                  end if;
               end if;

            when PAN_ST =>
               -- Pan. The button for larger values has priority over the
               -- other one.
               if inc_btn = '1' then
                  pos <= pos + pan;
               elsif dec_btn = '1' then
                  if pos >= pan then
                     pos <= pos - pan;
                  else
                     pos <= (others => '0');
                  end if;
               end if;

            when CLAMP_ST =>
               -- Keep the right and bottom edges in range. This is needed after
               -- panning right or down, and after zooming out.
               if pos > lim then
                  start <= lim(C_BITS-1 downto 0) xor C_SIGN;
               else
                  start <= pos(C_BITS-1 downto 0) xor C_SIGN;
               end if;
               step <= d;
         end case;

         if rst_i = '1' then
            start <= C_INIT_START;
            step  <= C_INIT_STEP;
         end if;
      end if;
   end process p_axis;

   start_o <= start;
   step_o  <= step;

end architecture rtl;

