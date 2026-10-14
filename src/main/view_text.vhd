-- This module converts the view (see viewport.vhd) to the text shown in the top
-- left corner of the VGA output (see overlay.vhd and text_pkg.vhd): the
-- centre of the picture as a complex number, and the zoom, in decimal, e.g.
--
--    -0.33337-0.00000i        1.00x
--
-- The view is in 2.33 fixed point format, as in the rest of the design.
-- * The centre is the point of the pixel in column G_NUM_COLS/2 and row
--   G_NUM_ROWS/2, i.e. the one that is kept fixed when zooming (see
--   viewport.vhd): startx + stepx*G_NUM_COLS/2, and the same for y. The rows
--   go down the screen, so the imaginary part increases downwards. The real
--   and the imaginary part are each shown with a sign ("+" or "-"), one digit
--   before the point, and five after it, rounded to the nearest. E.g. -2 is
--   "-2.00000", and 2-2^-33 (the largest value) is "+2.00000".
-- * The zoom is the initial size of a pixel (G_INIT_STEP, i.e. stepx after
--   reset, in LSBs of 2.33) divided by stepx, so it is 1 for the initial
--   view, more than 1 when zoomed in, and less than 1 when zoomed out. It is
--   shown with eight digits before the point and two after it, rounded to
--   the nearest, and the leading zeros of the integer part (except the last
--   one) are not shown, e.g. "       1.00x" or "17895697.00x" (zoomed in as
--   far as possible on the MEGA65, where the initial size is 17895697
--   LSBs). A zoom above 99999999.99 is shown as 99999999.99, but that needs
--   an initial size above 99999999 LSBs, i.e. a picture of fewer than 230
--   columns, e.g. the 16 columns of redraw_tb.vhd.
--
-- The text has C_VIEW_CHARS (30) characters:
--
--    Position :  0  1 2 3-7  8  9 10 11-15 16 17 18-25 26 27-28 29
--    Character: +- d . ddddd +- d  .  ddddd  i     dddddddd  .  dd    x
--
-- The conversion starts with a pulse on start_i, which takes the view, and
-- takes 194 clock cycles for 1280x1024 (it depends a little on the size of
-- the picture). At the end, text_o is changed, and
-- valid_o is high for one clock cycle. A pulse on start_i during a conversion
-- is ignored. text_o shows nothing (all the characters are 15) until the
-- first conversion is finished.
--
-- Each step is done one bit per clock cycle, with one addition or subtraction
-- of at most 47 bits per clock cycle, because a single-cycle multiplication
-- or division would be far too slow for the MAIN clock, and the DSPs are for
-- the iterators:
-- * The centre: The multiplication by the constant G_NUM_COLS/2 (G_NUM_ROWS/2)
--   is done with shifts and additions, one bit of the constant per clock
--   cycle.
-- * The five digits after the point: The magnitude of the centre (a 2.33
--   number) is multiplied by 100000 and divided by 2^33, i.e. multiplied by
--   3125 and divided by 2^28, with 2^27 added first for the rounding. This
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
use ieee.math_real.all;

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
      startx_i : in  std_logic_vector(34 downto 0);
      starty_i : in  std_logic_vector(34 downto 0);
      stepx_i  : in  std_logic_vector(34 downto 0);
      stepy_i  : in  std_logic_vector(34 downto 0);
      text_o   : out std_logic_vector(4*C_VIEW_CHARS-1 downto 0);
      valid_o  : out std_logic
   );
end entity view_text;

architecture rtl of view_text is

   -- The column and row of the centre, see viewport.vhd
   constant C_CENTRE_X : natural := G_NUM_COLS/2;
   constant C_CENTRE_Y : natural := G_NUM_ROWS/2;

   -- The fraction is multiplied by 100000/2^33 = 3125/2^28, and 2^27 is
   -- added, for the rounding.
   constant C_SCALE    : natural := 3125;
   constant C_SHIFT    : natural := 28;

   -- The number of bits needed for the value r, an integer as a real number
   -- (some of the values do not fit in an integer)
   function num_bits (r : real) return natural is
      variable val_v : real    := r;
      variable r_v   : natural := 0;
   begin
      while val_v >= 1.0 loop
         val_v := floor(val_v / 2.0);
         r_v   := r_v + 1;
      end loop;
      return r_v;
   end function num_bits;

   -- The width of the dividend of the zoom, i.e. 100*G_INIT_STEP plus half of
   -- stepx (less than 2^34), which is also the width of the quotient, and of
   -- the binary value converted to decimal: 35 bits for 1280 columns. The
   -- values converted are at most 200000 (the centre times 100000, 18 bits;
   -- the top bits of the multiplications give 19 bits) and C_MAX_ZOOM (34
   -- bits).
   constant C_BITS     : natural :=
      maximum(34, num_bits(100.0*real(G_INIT_STEP) + 2.0**34 - 1.0));

   -- The value n times 100, with bits bits
   function times_100 (n : natural; bits : natural) return std_logic_vector is
      variable r_v : std_logic_vector(bits+6 downto 0);
   begin
      r_v := to_slv(n, bits) * to_slv(100, 7);
      return r_v(bits-1 downto 0);
   end function times_100;

   -- The zoom, times 100, is C_ZOOM / stepx
   constant C_ZOOM     : std_logic_vector(C_BITS-1 downto 0) := times_100(G_INIT_STEP, C_BITS);

   -- The largest zoom shown, times 100, i.e. 99999999.99
   constant C_MAX_ZOOM : std_logic_vector(33 downto 0) :=
      to_slv(99999999, 27) * to_slv(100, 7) + 99;

   constant C_DIGITS   : natural := 10;

   type state_t is (IDLE_ST, LOAD_ST, CENTRE_ST, ABS_ST, SCALE_ST, DIV_ST,
                    BIN_ST, BCD_ST, TEXT_ST);
   signal state : state_t := IDLE_ST;

   -- The value converted: 0 is the real part, 1 the imaginary part, and 2
   -- the zoom
   signal part  : natural range 0 to 2;

   -- The view, taken at the start
   signal startx : std_logic_vector(34 downto 0);
   signal starty : std_logic_vector(34 downto 0);
   signal stepx  : std_logic_vector(34 downto 0);
   signal stepy  : std_logic_vector(34 downto 0);

   -- The serial multiplications: acc is the sum, mult the multiplicand,
   -- shifted left by one bit in each clock cycle, and k the remaining bits of
   -- the constant. Both products are less than 2^46.
   signal acc   : std_logic_vector(46 downto 0);
   signal mult  : std_logic_vector(46 downto 0);
   signal k     : std_logic_vector(11 downto 0);
   signal neg   : std_logic;

   -- The division: During the division, quot holds the remaining bits of the
   -- dividend, followed by the bits of the quotient found so far, as in
   -- fps.vhd. At the end it holds the quotient.
   signal quot      : std_logic_vector(C_BITS-1 downto 0);
   signal remainder : std_logic_vector(34 downto 0);

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

   assert C_VIEW_CHARS = 30
      report "The text has the wrong length"
      severity failure;

   p_text : process (clk_i)
      variable rem_v  : std_logic_vector(35 downto 0);
      variable diff_v : std_logic_vector(36 downto 0);
      variable bcd_v  : std_logic_vector(4*C_DIGITS-1 downto 0);
      variable sign_v : std_logic_vector( 3 downto 0);
      variable zoom_v : std_logic_vector(31 downto 0);
      variable lead_v : boolean;
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
                     acc   <= (46 downto 35 => startx(34)) & startx;
                     mult  <= (46 downto 35 => '0') & stepx;
                     k     <= to_slv(C_CENTRE_X, k'length);
                     state <= CENTRE_ST;

                  when 1 =>
                     acc   <= (46 downto 35 => starty(34)) & starty;
                     mult  <= (46 downto 35 => '0') & stepy;
                     k     <= to_slv(C_CENTRE_Y, k'length);
                     state <= CENTRE_ST;

                  when 2 =>
                     quot      <= C_ZOOM + stepx(34 downto 1);
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
               mult <= mult(45 downto 0) & "0";
               k    <= "0" & k(k'high downto 1);
               if k(k'high downto 1) = 0 then
                  state <= ABS_ST;
               end if;

            when ABS_ST =>
               -- The magnitude of the centre (at most 2^34), times 3125, plus
               -- 2^27 for the rounding. The centre is from -2 to 2 (not
               -- including 2), i.e. from -2^34 to 2^34-1, so its sign is bit
               -- 34, and the negation of -2^34 is 2^34 (as an unsigned value).
               neg <= acc(34);
               if acc(34) = '1' then
                  mult <= (46 downto 35 => '0') & (0 - acc(34 downto 0));
               else
                  mult <= (46 downto 35 => '0') & acc(34 downto 0);
               end if;
               acc   <= to_slv(2**(C_SHIFT-1), 47);
               k     <= to_slv(C_SCALE, k'length);
               state <= SCALE_ST;

            when SCALE_ST =>
               if k(0) = '1' then
                  acc <= acc + mult;
               end if;
               mult <= mult(45 downto 0) & "0";
               k    <= "0" & k(k'high downto 1);
               if k(k'high downto 1) = 0 then
                  state <= BIN_ST;
               end if;

            when DIV_ST =>
               -- Shift the next bit of the dividend into the remainder, and
               -- subtract the divisor, if the remainder is large enough.
               rem_v  := remainder & quot(C_BITS-1);
               diff_v := ("0" & rem_v) - ("00" & stepx);
               if diff_v(36) = '0' then
                  remainder <= diff_v(34 downto 0);
                  quot      <= quot(C_BITS-2 downto 0) & "1";
               else
                  remainder <= rem_v(34 downto 0);
                  quot      <= quot(C_BITS-2 downto 0) & "0";
               end if;

               if bit_cnt = 0 then
                  state <= BIN_ST;
               else
                  bit_cnt <= bit_cnt - 1;
               end if;

            when BIN_ST =>
               -- The value converted to decimal: The centre times 100000 (at
               -- most 200000), i.e. acc / 2^28, or the zoom times 100, which
               -- is limited to 99999999.99.
               if part = 2 then
                  bin <= quot;
                  if quot > C_MAX_ZOOM then
                     bin <= (C_BITS-1 downto 34 => '0') & C_MAX_ZOOM;
                  end if;
               else
                  bin <= (C_BITS-1 downto 19 => '0') & acc(46 downto C_SHIFT);
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
               -- imaginary part (8 to 16), and the zoom (17 to 29).
               sign_v := C_CHAR_PLUS;
               if neg = '1' then
                  sign_v := C_CHAR_MINUS;
               end if;
               case part is
                  when 0 =>
                     text(119 downto 88) <= sign_v & digit(bcd, 5) & C_CHAR_DOT &
                                            bcd(19 downto 0);
                     part  <= 1;
                     state <= LOAD_ST;

                  when 1 =>
                     text(87 downto 52) <= sign_v & digit(bcd, 5) & C_CHAR_DOT &
                                           bcd(19 downto 0) & C_CHAR_I;
                     part  <= 2;
                     state <= LOAD_ST;

                  when 2 =>
                     -- The integer part (digits 9 to 2), without the leading
                     -- zeros
                     zoom_v := bcd(39 downto 8);
                     lead_v := true;
                     for i in 9 downto 3 loop
                        if lead_v and digit(bcd, i) = 0 then
                           zoom_v(4*i-5 downto 4*i-8) := C_CHAR_NONE;
                        else
                           lead_v := false;
                        end if;
                     end loop;
                     text_r  <= text(119 downto 52) & C_CHAR_NONE & zoom_v & C_CHAR_DOT &
                                digit(bcd, 1) & digit(bcd, 0) & C_CHAR_X;
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
