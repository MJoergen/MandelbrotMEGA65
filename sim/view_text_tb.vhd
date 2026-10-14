-- This is a self-checking testbench for the conversion of the view to text
-- (view_text.vhd). It has three instances, one with the size of the picture
-- and the initial size of a pixel of the MEGA65 (1280x1024, 17895697 LSBs of
-- 2.33), one with those of the Nexys 4 DDR (640x480, 35791394 LSBs), and one
-- with those of redraw_tb.vhd (16x12, 1431655765 LSBs), where the zoom is
-- often above 99999999.99, and is then shown as 99999999.99. They get the
-- same views:
-- * The initial views of both boards.
-- * The views at the edges of the range: the centre as far left (up) and
--   right (down) as possible, with the smallest and the largest size of a
--   pixel, the centre at 0, at one LSB below and above 0, with the largest
--   fraction, and just below and above half of the last digit, and the zoom
--   with a pixel of 2 and 3 LSBs.
-- * Random views, which are inside the range for all the instances, as from
--   viewport.vhd. Half of them have a pixel of at most 1000 LSBs, i.e. they
--   are zoomed in far.
-- For each view, the text of each instance is compared with a model, which
-- calculates the centre and the zoom exactly, and rounds them to the nearest.
-- The values have 35 bits, which do not fit in an integer, so the model uses
-- real numbers, which are exact for integers up to 2^53. The text is printed
-- for the first views, for a visual check.
--
-- It also checks that the text shows nothing before the first conversion,
-- that valid_o is high for one clock cycle at the end of each conversion,
-- that text_o only changes then, that a pulse on start_i during a conversion
-- is ignored, and how long a conversion takes.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.text_pkg.all;

entity view_text_tb is
end entity view_text_tb;

architecture simulation of view_text_tb is

   type int_vector is array (natural range <>) of integer;

   -- The instances: the number of columns and rows, and the initial size of
   -- a pixel
   constant C_NUM       : natural := 3;
   constant C_COLS      : int_vector(0 to C_NUM-1) := (    1280,      640,         16);
   constant C_ROWS      : int_vector(0 to C_NUM-1) := (    1024,      480,         12);
   constant C_INIT_STEP : int_vector(0 to C_NUM-1) := (17895697, 35791394, 1431655765);

   -- The largest integer that is at most x. floor of math_real is not used,
   -- because GHDL returns x unchanged when it is 2^31 or more. x is split
   -- into a multiple of 2^26 and the rest, so it may be up to 2^56.
   function floor_int (x : real) return real is
      variable hi_v : real := floor(x / 2.0**26);
   begin
      return hi_v * 2.0**26 + floor(x - hi_v * 2.0**26);
   end function floor_int;

   -- The smallest and the largest position, and the largest size of a pixel
   -- for all the instances (see viewport.vhd). The values are integers, as
   -- real numbers.
   constant C_MIN_POS   : real := -2.0**34;
   constant C_MAX_POS   : real :=  2.0**34 - 1.0;
   constant C_MAX_STEP  : real := floor_int((2.0**35 - 1.0) / real(1280-1));

   -- Longer than a conversion
   constant C_TIMEOUT   : natural := 1000;

   constant C_RANDOM    : natural := 2000;

   subtype text_t is std_logic_vector(4*C_VIEW_CHARS-1 downto 0);
   type text_vector is array (0 to C_NUM-1) of text_t;

   signal clk     : std_logic;
   signal rst     : std_logic := '1';
   signal start   : std_logic := '0';
   signal startx  : std_logic_vector(34 downto 0) := (others => '0');
   signal starty  : std_logic_vector(34 downto 0) := (others => '0');
   signal stepx   : std_logic_vector(34 downto 0) := (others => '0');
   signal stepy   : std_logic_vector(34 downto 0) := (others => '0');
   signal text    : text_vector;
   signal valid   : std_logic_vector(0 to C_NUM-1);

   -- The initial view of a board (see main.vhd and viewport_axis.vhd): the
   -- position rounded to the nearest, and the size of a pixel rounded down
   function init_pos (pos : real) return real is
   begin
      return floor_int((pos + 2.0) * 2.0**33 + 0.5) - 2.0**34;
   end function init_pos;

   function init_step (size : real; num : natural) return real is
   begin
      return floor_int(floor_int(size * 2.0**33 + 0.5) / real(num));
   end function init_step;

   -- The value r (an integer from -2^34 to 2^34-1, as a real number) as a
   -- vector of 35 bits
   function to_slv (r : real) return std_logic_vector is
      variable hi_v : real := floor_int(r / 2.0**16);
   begin
      return std_logic_vector(to_signed(integer(hi_v), 19)) &
             std_logic_vector(to_unsigned(integer(r - hi_v * 2.0**16), 16));
   end function to_slv;

   -- The text as a string, with the characters that are not shown as spaces
   function to_string (t : text_t) return string is
      constant C_CHARS : string(1 to 16) := "0123456789.-+ix ";
      variable r_v     : string(1 to C_VIEW_CHARS);
   begin
      for i in 0 to C_VIEW_CHARS-1 loop
         r_v(i+1) := C_CHARS(to_integer(unsigned(t(4*(C_VIEW_CHARS-1-i)+3 downto
                                                    4*(C_VIEW_CHARS-1-i)))) + 1);
      end loop;
      return r_v;
   end function to_string;

   -- The last w decimal digits of n (an integer as a real number)
   function decimal (n : real; w : natural) return string is
      variable r_v : string(1 to w);
      variable n_v : real := n;
   begin
      for i in w downto 1 loop
         r_v(i) := character'val(character'pos('0') + integer(n_v - 10.0*floor_int(n_v / 10.0)));
         n_v    := floor_int(n_v / 10.0);
      end loop;
      return r_v;
   end function decimal;

   -- The centre (a 2.33 value, as an integer) as text, rounded to five
   -- digits after the point
   function centre_text (c : real) return string is
      variable m_v : real;
   begin
      -- abs(c)*100000/2^33, rounded
      m_v := floor_int((abs(c)*3125.0 + 2.0**27) / 2.0**28);
      if c < 0.0 then
         return "-" & decimal(floor_int(m_v / 1.0E5), 1) & "." & decimal(m_v, 5);
      else
         return "+" & decimal(floor_int(m_v / 1.0E5), 1) & "." & decimal(m_v, 5);
      end if;
   end function centre_text;

   -- The quotient a/b of two integers, rounded down. The division of the
   -- real numbers may round the quotient up to the next integer, so it is
   -- corrected.
   function div (a : real; b : real) return real is
      variable q_v : real := floor_int(a / b);
   begin
      if q_v * b > a then
         q_v := q_v - 1.0;
      elsif (q_v + 1.0) * b <= a then
         q_v := q_v + 1.0;
      end if;
      return q_v;
   end function div;

   -- The expected text of the instance n for the view
   function expected (n : natural; sx : real; sy : real; dx : real;
                      dy : real) return string is
      variable z_v : real;
      variable s_v : string(1 to 11);
   begin
      z_v := realmin(div(100.0*real(C_INIT_STEP(n)) + floor_int(dx/2.0), dx), 1.0E10 - 1.0);
      s_v := decimal(floor_int(z_v / 100.0), 8) & "." & decimal(z_v, 2);
      -- The leading zeros are not shown
      for i in 1 to 7 loop
         exit when s_v(i) /= '0';
         s_v(i) := ' ';
      end loop;
      return centre_text(sx + dx*real(C_COLS(n)/2)) &
             centre_text(sy + dy*real(C_ROWS(n)/2)) & "i " & s_v & "x";
   end function expected;

   signal finished : boolean := false;

begin

   ----------------------------
   -- Generate clock and reset
   ----------------------------

   p_clk : process
   begin
      clk <= '0', '1' after 5 ns;
      wait for 10 ns;
      if finished then
         wait;
      end if;
   end process p_clk;


   ----------------------------
   -- Stimulus and checking
   ----------------------------

   p_test : process
      variable seed1_v  : positive := 42;
      variable seed2_v  : positive := 4711;
      variable count_v  : natural  := 0;
      variable errors_v : natural  := 0;
      variable cycles_v : natural;

      -- A random integer from lo to hi, as a real number
      impure function rand_int (lo : real; hi : real) return real is
         variable r_v : real;
      begin
         uniform(seed1_v, seed2_v, r_v);
         return lo + floor_int(r_v * (hi - lo + 1.0));
      end function rand_int;

      -- Starts a conversion of the view, waits for its end, and checks the
      -- text of all the instances. If extra is set, a second view is given
      -- during the conversion, which must be ignored.
      procedure convert (sx : real; sy : real; dx : real; dy : real;
                         extra : boolean := false) is
         variable exp_v  : string(1 to C_VIEW_CHARS);
         variable done_v : std_logic_vector(0 to C_NUM-1);
      begin
         startx <= to_slv(sx);
         starty <= to_slv(sy);
         stepx  <= to_slv(dx);
         stepy  <= to_slv(dy);
         start  <= '1';
         wait until rising_edge(clk);
         start  <= '0';
         if extra then
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            startx <= to_slv(0.0);
            starty <= to_slv(0.0);
            stepx  <= to_slv(1.0);
            stepy  <= to_slv(1.0);
            start  <= '1';
            wait until rising_edge(clk);
            start  <= '0';
         end if;

         -- Wait for the end of all the conversions. They take different
         -- times, because the widths of the division and the multiplications
         -- depend on the size of the picture. cycles_v is the time of the
         -- MEGA65.
         cycles_v := 0;
         done_v   := (others => '0');
         while done_v /= (0 to C_NUM-1 => '1') loop
            wait until rising_edge(clk);
            if done_v(0) = '0' then
               cycles_v := cycles_v + 1;
            end if;
            for n in 0 to C_NUM-1 loop
               if valid(n) = '1' then
                  assert done_v(n) = '0'
                     report "valid_o is high for more than one clock cycle"
                     severity error;
                  done_v(n) := '1';
               end if;
            end loop;
            assert cycles_v < C_TIMEOUT
               report "No end of the conversion"
               severity failure;
         end loop;

         for n in 0 to C_NUM-1 loop
            exp_v := expected(n, sx, sy, dx, dy);
            if to_string(text(n)) /= exp_v then
               if errors_v < 20 then
                  report "Instance " & integer'image(n) & ", view (" &
                         real'image(sx) & ", " & real'image(sy) & ", " &
                         real'image(dx) & ", " & real'image(dy) &
                         "): got """ & to_string(text(n)) & """, expected """ &
                         exp_v & """"
                     severity error;
               end if;
               errors_v := errors_v + 1;
            end if;
         end loop;

         if count_v < 15 then
            report """" & to_string(text(0)) & """  """ & to_string(text(1)) &
                   """  """ & to_string(text(2)) & """";
         end if;
         count_v := count_v + 1;

         wait until rising_edge(clk);
         assert valid = (0 to C_NUM-1 => '0')
            report "valid_o is high for more than one clock cycle"
            severity error;
      end procedure convert;

      variable dx_v : real;
      variable dy_v : real;
      variable sx_v : real;
      variable sy_v : real;
   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk);

      for n in 0 to C_NUM-1 loop
         assert to_string(text(n)) = (1 to C_VIEW_CHARS => ' ')
            report "The text is shown before the first conversion"
            severity error;
      end loop;

      -- The initial views of both boards (see main.vhd and viewport.vhd)
      convert(init_pos(-1.6667), init_pos(-8.0/3.0*1024.0/1280.0/2.0),
              init_step(8.0/3.0, 1280), init_step(8.0/3.0*1024.0/1280.0, 1024));
      convert(init_pos(-1.6667), init_pos(-1.0),
              init_step(8.0/3.0, 640), init_step(2.0, 480));

      -- The edges of the range, with the smallest and the largest pixel. The
      -- largest pixel only fits at the left (top) edge.
      convert(C_MIN_POS, C_MIN_POS, 1.0, 1.0);
      convert(C_MAX_POS - 1279.0, C_MAX_POS - 1023.0, 1.0, 1.0);
      convert(C_MIN_POS, C_MIN_POS, C_MAX_STEP, C_MAX_STEP);
      convert(C_MAX_POS - 1279.0*C_MAX_STEP, C_MAX_POS - 1023.0*C_MAX_STEP,
              C_MAX_STEP, C_MAX_STEP);

      -- The centre at 0, and one LSB below and above it (for the MEGA65)
      convert(-640.0, -512.0, 1.0, 1.0);
      convert(-641.0, -511.0, 1.0, 1.0);
      -- The largest fraction, 1-2^-33 (shown as 1.00000), and its negative
      convert(2.0**33 - 1.0 - 640.0, -2.0**33 + 1.0 - 512.0, 1.0, 1.0);
      convert(2.0**33 - 1.0 - 640.0*2.0, -2.0**33 + 1.0 - 512.0*2.0, 2.0, 2.0);
      -- Just below and above half of the last digit (0.000005 is 42949.67
      -- LSBs)
      convert(42949.0 - 640.0, -42950.0 - 512.0, 1.0, 1.0);
      -- A pixel of 2 and 3 LSBs, i.e. a zoom with .50, and with .33 or .67
      convert(0.0, 0.0, 2.0, 3.0);
      convert(0.0, 0.0, 3.0, 2.0);

      -- A second start during the conversion is ignored
      convert(1000.0, -2000.0, 50.0, 50.0, true);

      -- Random views, half of them zoomed in far
      for i in 1 to C_RANDOM loop
         if i mod 2 = 0 then
            dx_v := rand_int(1.0, 1000.0);
         else
            dx_v := rand_int(1.0, C_MAX_STEP);
         end if;
         dy_v := dx_v;
         if i mod 4 = 0 then
            dy_v := rand_int(1.0, C_MAX_STEP);
         end if;
         sx_v := rand_int(C_MIN_POS, C_MAX_POS - 1279.0*dx_v);
         sy_v := rand_int(C_MIN_POS, C_MAX_POS - 1023.0*dy_v);
         convert(sx_v, sy_v, dx_v, dy_v, i mod 10 = 0);
      end loop;

      report "A conversion takes " & integer'image(cycles_v + 1) & " clock cycles";

      assert errors_v = 0
         report integer'image(errors_v) & " wrong texts"
         severity error;

      report "view_text_tb: finished";
      finished <= true;
      std.env.finish;
   end process p_test;


   -- The text only changes together with valid_o
   p_stable : process (clk)
      variable text_d_v : text_vector;
   begin
      if rising_edge(clk) then
         for n in 0 to C_NUM-1 loop
            if rst = '0' and valid(n) = '0' then
               assert text(n) = text_d_v(n)
                  report "text_o changed without valid_o"
                  severity error;
            end if;
            text_d_v(n) := text(n);
         end loop;
      end if;
   end process p_stable;


   -------------------
   -- Instantiate DUT
   -------------------

   gen_dut : for n in 0 to C_NUM-1 generate
      i_view_text : entity work.view_text
         generic map (
            G_NUM_COLS  => C_COLS(n),
            G_NUM_ROWS  => C_ROWS(n),
            G_INIT_STEP => C_INIT_STEP(n)
         )
         port map (
            clk_i    => clk,
            rst_i    => rst,
            start_i  => start,
            startx_i => startx,
            starty_i => starty,
            stepx_i  => stepx,
            stepy_i  => stepy,
            text_o   => text(n),
            valid_o  => valid(n)
         ); -- i_view_text
   end generate gen_dut;

end architecture simulation;
