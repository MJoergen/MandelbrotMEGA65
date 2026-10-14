-- This package contains a bit-accurate model of the iteration count calculated
-- by src/main/iterator_wide.vhd (2.33 fixed point). It is used by the
-- testbenches, which compare the counts from the design with this model. It is
-- the same model as in model.py.
--
-- The model calculates exactly what the iterator calculates, but in a simpler
-- way: x+y and x-y are calculated with enough bits, so the selection of the
-- multiplier inputs in the iterator is not needed here, and the products are
-- calculated in one step, with the formula given in iterator_wide.vhd.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package iterator_model_pkg is

   -- The iteration count of iterator_wide.vhd for the point c = cx + i*cy,
   -- where cx and cy are 2.33 fixed point numbers (35 bits). The count is the
   -- number of the first iteration where x or y is outside the range -2 to 2
   -- (not including 2), or max_count if this does not happen.
   function iterator_count (cx : signed(34 downto 0); cy : signed(34 downto 0);
                            max_count : integer) return integer;

   -- Convert a real value to 2.33 fixed point (rounded to the nearest value)
   function to_fixed_wide (r : real) return signed;

   -- The value of a pixel in the display memory, for the count cnt, in
   -- job_wide.vhd: 511 for the points in the set (cnt = max_count), and
   -- otherwise the count modulo 511, see palette_pkg.vhd.
   function to_pixel (cnt : integer; max_count : integer) return integer;

end package iterator_model_pkg;

package body iterator_model_pkg is

   -- True if the top bits of v, from bit 'left' down to bit 'low', are all
   -- equal, i.e. if v is in range when the bits above 'low' are removed.
   function top_bits_equal (v : signed; low : natural) return boolean is
   begin
      return v(v'left downto low) = (v'left downto low => '0') or
             v(v'left downto low) = (v'left downto low => '1');
   end function top_bits_equal;

   function iterator_count (cx : signed(34 downto 0); cy : signed(34 downto 0);
                            max_count : integer) return integer is
      constant C_HALF_X : signed(71 downto 0) := shift_left(to_signed(1, 72), 32);
      constant C_HALF_Y : signed(69 downto 0) := shift_left(to_signed(1, 70), 31);
      variable x_v      : signed(34 downto 0);  -- 2.33
      variable y_v      : signed(34 downto 0);  -- 2.33
      variable a_v      : signed(35 downto 0);  -- x+y, 3.33
      variable b_v      : signed(35 downto 0);  -- x-y, 3.33
      variable lo_v     : signed(34 downto 0);  -- Product of the low 17 bits
      variable prod_x_v : signed(71 downto 0);
      variable prod_y_v : signed(69 downto 0);
      variable new_x_v  : signed(37 downto 0);  -- 5.33
      variable new_y_v  : signed(37 downto 0);  -- 5.33
   begin
      x_v := (others => '0');
      y_v := (others => '0');

      for n in 1 to max_count-1 loop
         -- new_x = floor(((x+y)*(x-y) - al*bl + 2^32) / 2^33) + cx, where al and
         -- bl are the lowest 17 bits of x+y and x-y
         a_v      := resize(x_v, 36) + resize(y_v, 36);
         b_v      := resize(x_v, 36) - resize(y_v, 36);
         lo_v     := signed('0' & unsigned(a_v(16 downto 0)) * unsigned(b_v(16 downto 0)));
         prod_x_v := a_v * b_v - resize(lo_v, 72) + C_HALF_X;
         new_x_v  := resize(shift_right(prod_x_v, 33), 38) + resize(cx, 38);

         -- new_y = floor((x*y - xl*yl + 2^31) / 2^32) + cy, where xl and yl are
         -- the lowest 17 bits of x and y
         lo_v     := signed('0' & unsigned(x_v(16 downto 0)) * unsigned(y_v(16 downto 0)));
         prod_y_v := x_v * y_v - resize(lo_v, 70) + C_HALF_Y;
         new_y_v  := resize(shift_right(prod_y_v, 32), 38) + resize(cy, 38);

         -- The new values are in range (-2 <= x < 2) if they fit in 35 bits
         if not top_bits_equal(new_x_v, 34) or not top_bits_equal(new_y_v, 34) then
            return n;
         end if;

         x_v := new_x_v(34 downto 0);
         y_v := new_y_v(34 downto 0);
      end loop;

      return max_count;
   end function iterator_count;

   function to_fixed_wide (r : real) return signed is
      -- The function round() of math_real is not used, because in GHDL it
      -- gives wrong results for values outside the range of integer.
      variable int_v : real := floor(r * 2.0**33 + 0.5);
      variable hi_v  : real := floor(int_v / 2.0**17);
   begin
      return to_signed(integer(hi_v), 18) &
             signed(to_unsigned(integer(int_v - hi_v * 2.0**17), 17));
   end function to_fixed_wide;

   function to_pixel (cnt : integer; max_count : integer) return integer is
   begin
      if cnt = max_count then
         return 511;
      end if;
      return cnt mod 511;
   end function to_pixel;

end package body iterator_model_pkg;
