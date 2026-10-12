-- This is a self-checking testbench for the conversion of the view to text
-- (view_text.vhd). It has three instances, one with the size of the picture
-- and the initial size of a pixel of the MEGA65 (1280x1024, 136 LSBs), one
-- with those of the Nexys 4 DDR (640x480, 273 LSBs), and one with those of
-- redraw_tb.vhd (16x12, 10922 LSBs), where the zoom is always above 999.99,
-- and is shown as 999.99. They get the same views:
-- * The initial views of both boards.
-- * The views at the edges of the range: the centre as far left (up) and
--   right (down) as possible, with the smallest and the largest size of a
--   pixel, and the centre at 0, at one LSB below and above 0, and with the
--   largest fraction.
-- * Random views, which are inside the range for all the instances, as from
--   viewport.vhd.
-- For each view, the text of each instance is compared with a model, which
-- calculates the centre and the zoom with integers, and rounds them to the
-- nearest. The text is printed for the first views, for a visual check.
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
   constant C_COLS      : int_vector(0 to C_NUM-1) := (1280, 640,    16);
   constant C_ROWS      : int_vector(0 to C_NUM-1) := (1024, 480,    12);
   constant C_INIT_STEP : int_vector(0 to C_NUM-1) := ( 136, 273, 10922);

   -- The largest position, and the largest size of a pixel for both
   -- instances (see viewport.vhd)
   constant C_MAX_POS   : integer := 2**17-1;
   constant C_MAX_STEP  : integer := (2**18-1) / (1280-1);

   -- Longer than a conversion
   constant C_TIMEOUT   : natural := 1000;

   constant C_RANDOM    : natural := 2000;

   subtype text_t is std_logic_vector(4*C_VIEW_CHARS-1 downto 0);
   type text_vector is array (0 to C_NUM-1) of text_t;

   signal clk     : std_logic;
   signal rst     : std_logic := '1';
   signal start   : std_logic := '0';
   signal startx  : std_logic_vector(17 downto 0) := (others => '0');
   signal starty  : std_logic_vector(17 downto 0) := (others => '0');
   signal stepx   : std_logic_vector(17 downto 0) := (others => '0');
   signal stepy   : std_logic_vector(17 downto 0) := (others => '0');
   signal text    : text_vector;
   signal valid   : std_logic_vector(0 to C_NUM-1);

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

   -- The decimal digits of n, with w digits
   function decimal (n : natural; w : natural) return string is
      variable r_v : string(1 to w);
      variable n_v : natural := n;
   begin
      for i in w downto 1 loop
         r_v(i) := character'val(character'pos('0') + n_v mod 10);
         n_v    := n_v / 10;
      end loop;
      return r_v;
   end function decimal;

   -- The centre (a 2.16 value, as an integer) as text, rounded to five
   -- digits after the point
   function centre_text (c : integer) return string is
      variable m_v : natural;
   begin
      -- abs(c)*100000/2^16, rounded
      m_v := (abs(c)*3125 + 1024) / 2048;
      if c < 0 then
         return "-" & decimal(m_v / 100000, 1) & "." & decimal(m_v mod 100000, 5);
      else
         return "+" & decimal(m_v / 100000, 1) & "." & decimal(m_v mod 100000, 5);
      end if;
   end function centre_text;

   -- The expected text of the instance n for the view
   function expected (n : natural; sx : integer; sy : integer; dx : natural;
                      dy : natural) return string is
      variable z_v : natural;
      variable s_v : string(1 to 6);
   begin
      z_v := minimum((100*C_INIT_STEP(n) + dx/2) / dx, 99999);
      s_v := decimal(z_v / 100, 3) & "." & decimal(z_v mod 100, 2);
      -- The leading zeros are not shown
      if s_v(1) = '0' then
         s_v(1) := ' ';
         if s_v(2) = '0' then
            s_v(2) := ' ';
         end if;
      end if;
      return centre_text(sx + dx*(C_COLS(n)/2)) &
             centre_text(sy + dy*(C_ROWS(n)/2)) & "i " & s_v & "x";
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

      impure function rand_int (lo : integer; hi : integer) return integer is
         variable r_v : real;
      begin
         uniform(seed1_v, seed2_v, r_v);
         return lo + integer(floor(r_v * real(hi - lo + 1)));
      end function rand_int;

      -- Starts a conversion of the view, waits for its end, and checks the
      -- text of both instances. If extra is set, a second view is given
      -- during the conversion, which must be ignored.
      procedure convert (sx : integer; sy : integer; dx : natural; dy : natural;
                         extra : boolean := false) is
         variable exp_v : string(1 to C_VIEW_CHARS);
      begin
         startx <= std_logic_vector(to_signed(sx, 18));
         starty <= std_logic_vector(to_signed(sy, 18));
         stepx  <= std_logic_vector(to_unsigned(dx, 18));
         stepy  <= std_logic_vector(to_unsigned(dy, 18));
         start  <= '1';
         wait until rising_edge(clk);
         start  <= '0';
         if extra then
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            startx <= std_logic_vector(to_signed(0, 18));
            starty <= std_logic_vector(to_signed(0, 18));
            stepx  <= std_logic_vector(to_unsigned(1, 18));
            stepy  <= std_logic_vector(to_unsigned(1, 18));
            start  <= '1';
            wait until rising_edge(clk);
            start  <= '0';
         end if;

         -- Wait for the end of both conversions. The MEGA65 is the last,
         -- because the column and the row of its centre (640 and 512) have
         -- more bits.
         cycles_v := 0;
         while valid(0) /= '1' loop
            wait until rising_edge(clk);
            cycles_v := cycles_v + 1;
            assert cycles_v < C_TIMEOUT
               report "No end of the conversion"
               severity failure;
         end loop;

         for n in 0 to C_NUM-1 loop
            exp_v := expected(n, sx, sy, dx, dy);
            if to_string(text(n)) /= exp_v then
               if errors_v < 20 then
                  report "Instance " & integer'image(n) & ", view (" &
                         integer'image(sx) & ", " & integer'image(sy) & ", " &
                         integer'image(dx) & ", " & integer'image(dy) &
                         "): got """ & to_string(text(n)) & """, expected """ &
                         exp_v & """"
                     severity error;
               end if;
               errors_v := errors_v + 1;
            end if;
         end loop;

         if count_v < 12 then
            report """" & to_string(text(0)) & """  """ & to_string(text(1)) &
                   """  """ & to_string(text(2)) & """";
         end if;
         count_v := count_v + 1;

         wait until rising_edge(clk);
         assert valid(0) = '0'
            report "valid_o is high for more than one clock cycle"
            severity error;
      end procedure convert;

      variable dx_v : natural;
      variable dy_v : natural;
      variable sx_v : integer;
      variable sy_v : integer;
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
      convert(-109227, -69905, 136, 136);
      convert(-109227, -65536, 273, 273);

      -- The edges of the range, with the smallest and the largest pixel. The
      -- largest pixel only fits at the left (top) edge.
      convert(-2**17, -2**17, 1, 1);
      convert(C_MAX_POS - 1279, C_MAX_POS - 1023, 1, 1);
      convert(-2**17, -2**17, C_MAX_STEP, C_MAX_STEP);
      convert(C_MAX_POS - 1279*C_MAX_STEP, C_MAX_POS - 1023*C_MAX_STEP, C_MAX_STEP, C_MAX_STEP);

      -- The centre at 0, and one LSB below and above it (for the MEGA65)
      convert(-640, -512, 1, 1);
      convert(-641, -511, 1, 1);
      -- The largest fraction, 0.99998474, and its negative
      convert(65535 - 640, -65535 - 512, 1, 1);
      convert(65535 - 640*2, -65535 - 512*2, 2, 2);

      -- A second start during the conversion is ignored
      convert(1000, -2000, 50, 50, true);

      -- Random views
      for i in 1 to C_RANDOM loop
         dx_v := rand_int(1, C_MAX_STEP);
         dy_v := dx_v;
         if i mod 4 = 0 then
            dy_v := rand_int(1, C_MAX_STEP);
         end if;
         sx_v := rand_int(-2**17, C_MAX_POS - 1279*dx_v);
         sy_v := rand_int(-2**17, C_MAX_POS - 1023*dy_v);
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
