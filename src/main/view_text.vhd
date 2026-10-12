-- This module converts the view (see viewport.vhd) to the text shown in the top
-- left corner of the VGA output (see overlay.vhd and text_pkg.vhd): the
-- centre of the picture as a complex number, and the zoom, in decimal, e.g.
--
--    -0.33855-0.00417i   1.00x
--
-- * The centre is the point of the pixel in column G_NUM_COLS/2 and row
--   G_NUM_ROWS/2, i.e. the one that is kept fixed when zooming (see
--   viewport.vhd): startx + stepx*G_NUM_COLS/2, and the same for y. The rows
--   go down the screen, so the imaginary part increases downwards. The real
--   and the imaginary part are each shown with a sign ("+" or "-"), one digit
--   before the point, and five after it, rounded to the nearest (2^-16 is
--   about 0.000015). E.g. -2 is "-2.00000", and 1.99999237 (the largest
--   value) is "+1.99999".
-- * The zoom is the initial size of a pixel (G_INIT_STEP, i.e. stepx after
--   reset) divided by stepx, so it is 1 for the initial view, more than 1
--   when zoomed in, and less than 1 when zoomed out. It is shown with two
--   digits after the point, rounded to the nearest, and the leading zeros of
--   the integer part (except the last one) are not shown, e.g. "  1.00x" or
--   "136.00x". The size of a pixel is an integer number of LSBs, so the zoom
--   has only a few possible values when zoomed in far, e.g. 136.00 and 68.00
--   for a pixel of 1 and 2 LSBs on the MEGA65 (the initial size is 136 LSBs).
--   A zoom above 999.99 is shown as 999.99, but that needs an initial size
--   above 999 LSBs (a picture of fewer than 175 columns, as in redraw_tb.vhd).
--
-- The text has C_VIEW_CHARS (25) characters:
--
--    Position :  0  1 2 3-7  8  9 10 11-15 16 17 18-20 21 22-23 24
--    Character: +- d . ddddd +- d  .  ddddd  i     ddd  .  dd    x
--
-- The conversion starts with a pulse on start_i, which takes the view, and
-- takes 130 clock cycles for 1280x1024 (fewer for smaller pictures). At
-- the end, text_o is changed, and valid_o is high for one clock cycle. A pulse
-- on start_i during a conversion is ignored. text_o shows nothing (all the
-- characters are 15) until the first conversion is finished.
--
-- Each step is done one bit per clock cycle, with one addition or subtraction
-- of at most 30 bits per clock cycle, because a single-cycle multiplication
-- or division would be far too slow for the MAIN clock, and the DSPs are for
-- the iterators:
-- * The centre: The multiplication by the constant G_NUM_COLS/2 (G_NUM_ROWS/2)
--   is done with shifts and additions, one bit of the constant per clock
--   cycle.
-- * The five digits after the point: The magnitude of the centre (a 2.16
--   number) is multiplied by 100000 and divided by 2^16, i.e. multiplied by
--   3125 and divided by 2^11, with 2^10 added first for the rounding. This
--   is also done with shifts and additions.
-- * The zoom: 100*G_INIT_STEP is divided by stepx with a restoring division,
--   one bit of the quotient per clock cycle (as in fps.vhd). Half of stepx is
--   added to the dividend first, for the rounding.
-- * The conversion to decimal (BCD) is done with the double dabble algorithm
--   (as in fps.vhd): For each bit, 3 is added to each digit which is 5 or
--   more, and then the digits and the binary value are shifted left together
--   by one bit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.text_pkg.all;

entity view_text is
   generic (
      G_NUM_COLS  : positive;
      G_NUM_ROWS  : positive;
      G_INIT_STEP : positive        -- The size of a pixel after reset, in LSBs
   );
   port (
      clk_i    : in  std_logic;
      rst_i    : in  std_logic;
      start_i  : in  std_logic;
      startx_i : in  std_logic_vector(17 downto 0);
      starty_i : in  std_logic_vector(17 downto 0);
      stepx_i  : in  std_logic_vector(17 downto 0);
      stepy_i  : in  std_logic_vector(17 downto 0);
      text_o   : out std_logic_vector(4*C_VIEW_CHARS-1 downto 0);
      valid_o  : out std_logic
   );
end entity view_text;

architecture rtl of view_text is

   -- The column and row of the centre, see viewport.vhd
   constant C_CENTRE_X : natural := G_NUM_COLS/2;
   constant C_CENTRE_Y : natural := G_NUM_ROWS/2;

   -- The fraction is multiplied by 100000/2^16 = 3125/2^11, and 2^10 is
   -- added, for the rounding.
   constant C_SCALE    : natural := 3125;
   constant C_SHIFT    : natural := 11;

   -- The zoom, times 100, is C_ZOOM / stepx
   constant C_ZOOM     : natural := 100*G_INIT_STEP;

   -- The largest zoom shown, times 100, i.e. 999.99
   constant C_MAX_ZOOM : natural := 99999;

   -- The number of bits needed for the value n
   function num_bits (n : natural) return natural is
      variable val_v : natural := n;
      variable r_v   : natural := 0;
   begin
      while val_v > 0 loop
         val_v := val_v / 2;
         r_v   := r_v + 1;
      end loop;
      return r_v;
   end function num_bits;

   -- The width of the dividend of the zoom, i.e. C_ZOOM plus half of stepx
   -- (less than 2^17), which is also the width of the quotient, and of the
   -- binary value converted to decimal. The values converted are at most
   -- 200000 (the centre times 100000, 18 bits) and C_MAX_ZOOM. The top bits
   -- of the multiplications give 19 bits.
   constant C_BITS     : natural := maximum(19, num_bits(C_ZOOM + 2**17 - 1));

   constant C_DIGITS   : natural := 6;

   type state_t is (IDLE_ST, LOAD_ST, CENTRE_ST, ABS_ST, SCALE_ST, DIV_ST,
                    BIN_ST, BCD_ST, TEXT_ST);
   signal state : state_t := IDLE_ST;

   -- The value converted: 0 is the real part, 1 the imaginary part, and 2
   -- the zoom
   signal part  : natural range 0 to 2;

   -- The view, taken at the start
   signal startx : std_logic_vector(17 downto 0);
   signal starty : std_logic_vector(17 downto 0);
   signal stepx  : std_logic_vector(17 downto 0);
   signal stepy  : std_logic_vector(17 downto 0);

   -- The serial multiplications: acc is the sum, mult the multiplicand,
   -- shifted left by one bit in each clock cycle, and k the remaining bits of
   -- the constant. Both products are less than 2^30.
   signal acc   : std_logic_vector(29 downto 0);
   signal mult  : std_logic_vector(29 downto 0);
   signal k     : std_logic_vector(11 downto 0);
   signal neg   : std_logic;

   -- The division: During the division, quot holds the remaining bits of the
   -- dividend, followed by the bits of the quotient found so far, as in
   -- fps.vhd. At the end it holds the quotient.
   signal quot      : std_logic_vector(C_BITS-1 downto 0);
   signal remainder : std_logic_vector(17 downto 0);

   -- The conversion to decimal: bin is shifted out into bcd, one bit per
   -- clock cycle.
   signal bin     : std_logic_vector(C_BITS-1 downto 0);
   signal bcd     : std_logic_vector(4*C_DIGITS-1 downto 0);
   signal bit_cnt : natural range 0 to C_BITS-1;

   -- The text, while it is calculated, and the output
   signal text    : std_logic_vector(4*C_VIEW_CHARS-1 downto 0);
   signal text_r  : std_logic_vector(4*C_VIEW_CHARS-1 downto 0) := (others => '1');
   signal valid_r : std_logic := '0';

   -- The digit i of the BCD value
   function digit (bcd_v : std_logic_vector; i : natural) return std_logic_vector is
   begin
      return bcd_v(4*i+3 downto 4*i);
   end function digit;

begin

   assert C_CENTRE_X < 2**k'length and C_CENTRE_Y < 2**k'length and C_SCALE < 2**k'length
      report "The constants of the multiplications are too large"
      severity failure;

   assert C_VIEW_CHARS = 25
      report "The text has the wrong length"
      severity failure;

   p_text : process (clk_i)
      variable rem_v  : std_logic_vector(18 downto 0);
      variable diff_v : std_logic_vector(19 downto 0);
      variable bcd_v  : std_logic_vector(4*C_DIGITS-1 downto 0);
      variable sign_v : std_logic_vector( 3 downto 0);
      variable z4_v   : std_logic_vector( 3 downto 0);
      variable z3_v   : std_logic_vector( 3 downto 0);
   begin
      if rising_edge(clk_i) then
         valid_r <= '0';

         case state is
            when IDLE_ST =>
               if start_i = '1' then
                  startx <= startx_i;
                  starty <= starty_i;
                  stepx  <= stepx_i;
                  stepy  <= stepy_i;
                  part   <= 0;
                  state  <= LOAD_ST;
               end if;

            when LOAD_ST =>
               -- Prepare the calculation of the centre (sign extended), or
               -- the division
               case part is
                  when 0 =>
                     acc   <= (29 downto 18 => startx(17)) & startx;
                     mult  <= (29 downto 18 => '0') & stepx;
                     k     <= to_slv(C_CENTRE_X, k'length);
                     state <= CENTRE_ST;

                  when 1 =>
                     acc   <= (29 downto 18 => starty(17)) & starty;
                     mult  <= (29 downto 18 => '0') & stepy;
                     k     <= to_slv(C_CENTRE_Y, k'length);
                     state <= CENTRE_ST;

                  when 2 =>
                     quot      <= to_slv(C_ZOOM, C_BITS) + stepx(17 downto 1);
                     remainder <= (others => '0');
                     bit_cnt   <= C_BITS-1;
                     state     <= DIV_ST;
               end case;

            when CENTRE_ST =>
               -- acc = start + step*C_CENTRE_X (or y). The view is inside the
               -- range (see viewport.vhd), so the sum is from -2 to 2. The
               -- multiplicand is only too large for acc beyond the highest
               -- bit of the constant, where it is not used.
               if k(0) = '1' then
                  acc <= acc + mult;
               end if;
               mult <= mult(28 downto 0) & "0";
               k    <= "0" & k(k'high downto 1);
               if k(k'high downto 1) = 0 then
                  state <= ABS_ST;
               end if;

            when ABS_ST =>
               -- The magnitude of the centre (at most 2^17), times 3125, plus
               -- 2^10 for the rounding. The centre is from -2 to 2 (not
               -- including 2), i.e. from -2^17 to 2^17-1, so its sign is bit
               -- 17, and the negation of -2^17 is 2^17 (as an unsigned value).
               neg <= acc(17);
               if acc(17) = '1' then
                  mult <= (29 downto 18 => '0') & (0 - acc(17 downto 0));
               else
                  mult <= (29 downto 18 => '0') & acc(17 downto 0);
               end if;
               acc   <= to_slv(2**(C_SHIFT-1), 30);
               k     <= to_slv(C_SCALE, k'length);
               state <= SCALE_ST;

            when SCALE_ST =>
               if k(0) = '1' then
                  acc <= acc + mult;
               end if;
               mult <= mult(28 downto 0) & "0";
               k    <= "0" & k(k'high downto 1);
               if k(k'high downto 1) = 0 then
                  state <= BIN_ST;
               end if;

            when DIV_ST =>
               -- Shift the next bit of the dividend into the remainder, and
               -- subtract the divisor, if the remainder is large enough.
               rem_v  := remainder & quot(C_BITS-1);
               diff_v := ("0" & rem_v) - ("00" & stepx);
               if diff_v(19) = '0' then
                  remainder <= diff_v(17 downto 0);
                  quot      <= quot(C_BITS-2 downto 0) & "1";
               else
                  remainder <= rem_v(17 downto 0);
                  quot      <= quot(C_BITS-2 downto 0) & "0";
               end if;

               if bit_cnt = 0 then
                  state <= BIN_ST;
               else
                  bit_cnt <= bit_cnt - 1;
               end if;

            when BIN_ST =>
               -- The value converted to decimal: The centre times 100000 (at
               -- most 200000), i.e. acc / 2^11, or the zoom times 100, which
               -- is limited to 999.99.
               if part = 2 then
                  bin <= quot;
                  if quot > C_MAX_ZOOM then
                     bin <= to_slv(C_MAX_ZOOM, C_BITS);
                  end if;
               else
                  bin <= (C_BITS-1 downto 19 => '0') & acc(29 downto C_SHIFT);
               end if;
               bcd     <= (others => '0');
               bit_cnt <= C_BITS-1;
               state   <= BCD_ST;

            when BCD_ST =>
               bcd_v := bcd;
               for i in 0 to C_DIGITS-1 loop
                  if digit(bcd_v, i) >= 5 then
                     bcd_v(4*i+3 downto 4*i) := digit(bcd_v, i) + 3;
                  end if;
               end loop;
               bcd <= bcd_v(4*C_DIGITS-2 downto 0) & bin(C_BITS-1);
               bin <= bin(C_BITS-2 downto 0) & "0";

               if bit_cnt = 0 then
                  state <= TEXT_ST;
               else
                  bit_cnt <= bit_cnt - 1;
               end if;

            when TEXT_ST =>
               -- The characters, from the left: The real part (0 to 7), the
               -- imaginary part (8 to 16), and the zoom (17 to 24).
               sign_v := C_CHAR_PLUS;
               if neg = '1' then
                  sign_v := C_CHAR_MINUS;
               end if;
               case part is
                  when 0 =>
                     text(99 downto 68) <= sign_v & digit(bcd, 5) & C_CHAR_DOT &
                                           bcd(19 downto 0);
                     part  <= 1;
                     state <= LOAD_ST;

                  when 1 =>
                     text(67 downto 32) <= sign_v & digit(bcd, 5) & C_CHAR_DOT &
                                           bcd(19 downto 0) & C_CHAR_I;
                     part  <= 2;
                     state <= LOAD_ST;

                  when 2 =>
                     -- The leading zeros are not shown
                     z4_v := digit(bcd, 4);
                     z3_v := digit(bcd, 3);
                     if digit(bcd, 4) = 0 then
                        z4_v := C_CHAR_NONE;
                        if digit(bcd, 3) = 0 then
                           z3_v := C_CHAR_NONE;
                        end if;
                     end if;
                     text_r  <= text(99 downto 32) & C_CHAR_NONE & z4_v & z3_v &
                                digit(bcd, 2) & C_CHAR_DOT & digit(bcd, 1) &
                                digit(bcd, 0) & C_CHAR_X;
                     valid_r <= '1';
                     state   <= IDLE_ST;
               end case;
         end case;

         if rst_i = '1' then
            state   <= IDLE_ST;
            text_r  <= (others => '1');
            valid_r <= '0';
         end if;
      end if;
   end process p_text;

   text_o  <= text_r;
   valid_o <= valid_r;

end architecture rtl;
