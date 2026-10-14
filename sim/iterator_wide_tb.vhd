-- This is a self-checking testbench for the wide iterator (iterator_wide.vhd),
-- which calculates four points at a time: cx + i*(cy + k*stepy), for k = 0, 1,
-- 2, and 3. For each start, the count of each of the four points is compared
-- exactly with the bit-accurate model in iterator_model_pkg.vhd, and for the
-- points given as real numbers also with a count calculated using real
-- (floating point) numbers, within a small tolerance. This checks that the
-- model (i.e. the design) calculates the Mandelbrot iteration.
--
-- The points are mostly those of the testbench of the earlier 2.16 iterator
-- (see HISTORY.md), and the four points of a start are either the same point,
-- or a mixture of points that escape at different times, so that the slots of
-- the iterator finish in different orders. Some points include:
-- * Points in the set, which must be found by the periodicity detection, so
--   the number of clock cycles until done is checked too.
-- * Points where x+y or x-y is out of range (-2 to 2) during the iteration.
-- * Points that escape, but where x alone (-1+i) or y alone (all the points
--   on the real axis, e.g. 0.3) repeats an earlier saved value. The
--   periodicity detection must compare both x and y.
-- * Points right after points that leave saved values equal to their first
--   values.
-- * Four values of cy where the last ones wrap around (from 2 to -2), as
--   they do in the job modules.
-- Finally, a grid of 40 x 32 points over the initial view is compared exactly
-- with the model.
--
-- While the iterator is idle (from done until the next start), x_r and y_r
-- must not change, and the registers P of the DSPs must not change from four
-- clock cycles after done, so the iterator does not use power (p_idle). The
-- iterator is left idle for a while after a point in a cycle of period 2 and
-- after points that escape, where the values would otherwise go on changing.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.iterator_model_pkg.all;
use work.util_pkg.all;
use work.dispatcher_pkg.all;

entity iterator_wide_tb is
end entity iterator_wide_tb;

architecture simulation of iterator_wide_tb is

   constant C_MAX_COUNT : positive := 100;
   constant C_CNT_BITS  : natural  := log2(C_MAX_COUNT+1);

   -- The iterator uses fixed point numbers (with rounding errors), so the count
   -- may differ slightly from the one calculated using real numbers.
   constant C_TOLERANCE : integer := 1;

   signal clk   : std_logic;
   signal rst   : std_logic := '1';

   signal start : std_logic := '0';
   signal cx    : std_logic_vector(34 downto 0) := (others => '0');
   signal cy    : std_logic_vector(34 downto 0) := (others => '0');
   signal stepy : std_logic_vector(34 downto 0) := (others => '0');
   signal cnt   : std_logic_vector(4*C_CNT_BITS-1 downto 0);
   signal done  : std_logic;

   -- The number of clock cycles where p_idle has checked that the registers P
   -- do not change
   signal idle_cycles : natural := 0;

   -- Convert a value in 2.33 fixed point format to real
   function to_real (v : signed(34 downto 0)) return real is
   begin
      return (real(to_integer(v(34 downto 17))) * 2.0**17 +
              real(to_integer(unsigned(v(16 downto 0))))) / 2.0**33;
   end function to_real;

   -- Calculate the expected iteration count, using real numbers.
   function expected_count (cx_r : real; cy_r : real) return integer is
      variable x_v : real := 0.0;
      variable y_v : real := 0.0;
      variable t_v : real;
   begin
      for n in 1 to C_MAX_COUNT-1 loop
         t_v := x_v*x_v - y_v*y_v + cx_r;
         y_v := 2.0*x_v*y_v + cy_r;
         x_v := t_v;
         if x_v < -2.0 or x_v >= 2.0 or y_v < -2.0 or y_v >= 2.0 then
            return n;
         end if;
      end loop;
      return C_MAX_COUNT;
   end function expected_count;

begin

   ----------------------------
   -- Generate clock and reset
   ----------------------------

   p_clk : process
   begin
      clk <= '0', '1' after 5 ns;
      wait for 10 ns;
   end process p_clk;

   p_rst : process
   begin
      rst <= '1';
      wait for 100 ns;
      wait until clk = '1';
      rst <= '0';
      wait;
   end process p_rst;


   ----------------------------
   -- Stimulus and checking
   ----------------------------

   p_test : process

      -- Run the iterator for the four points cx + i*(cy + k*stepy), and
      -- compare the counts with the model, and, if real_check is true, with
      -- the count calculated using real numbers.
      procedure run (
         cx_v       : signed(34 downto 0);
         cy_v       : signed(34 downto 0);
         stepy_v    : signed(34 downto 0);
         real_check : boolean;
         max_cycles : integer      -- Maximum clock cycles until done
      ) is
         variable cyk_v     : signed(34 downto 0);
         variable exp_v     : integer;
         variable ref_v     : integer;
         variable act_v     : integer;
         variable t_start_v : time;
         variable cycles_v  : integer;
      begin
         wait until rising_edge(clk);
         cx    <= std_logic_vector(cx_v);
         cy    <= std_logic_vector(cy_v);
         stepy <= std_logic_vector(stepy_v);

         -- stepy is registered in the iterator, so it is set one clock cycle
         -- before the start
         wait until rising_edge(clk);
         start <= '1';
         t_start_v := now;
         wait until rising_edge(clk);
         start <= '0';

         -- Wait for the iterator to finish, but not forever
         wait until done = '1' for (4*C_MAX_COUNT + 20) * 10 ns;
         cycles_v := (now - t_start_v) / (10 ns);
         wait for 1 ns;

         for k in 0 to 3 loop
            -- The values of cy wrap around, like in the iterator
            cyk_v := cy_v + resize(to_signed(k, 3) * stepy_v, 35);
            act_v   := to_integer(unsigned(cnt(C_CNT_BITS*k+C_CNT_BITS-1 downto C_CNT_BITS*k)));
            exp_v   := iterator_count(cx_v, cyk_v, C_MAX_COUNT);

            assert done = '1' and act_v = exp_v
               report "Count differs from the model for c = (" & real'image(to_real(cx_v)) &
                      ", " & real'image(to_real(cyk_v)) & "): got " & integer'image(act_v) &
                      ", expected " & integer'image(exp_v)
               severity error;

            if real_check then
               ref_v := expected_count(to_real(cx_v), to_real(cyk_v));
               report "c = (" & real'image(to_real(cx_v)) & ", " & real'image(to_real(cyk_v)) &
                      "): count = " & integer'image(act_v) &
                      ", real numbers = " & integer'image(ref_v);
               assert abs(act_v - ref_v) <= C_TOLERANCE
                  report "Count differs from real numbers for c = (" & real'image(to_real(cx_v)) &
                         ", " & real'image(to_real(cyk_v)) & "): got " & integer'image(act_v) &
                         ", expected " & integer'image(ref_v)
                  severity error;
            end if;
         end loop;

         assert cycles_v <= max_cycles
            report "Too slow for c = (" & real'image(to_real(cx_v)) & ", " &
                   real'image(to_real(cy_v)) & "): " & integer'image(cycles_v) &
                   " clock cycles, expected at most " & integer'image(max_cycles)
            severity error;
      end procedure run;

      -- Run the iterator for the four points cx_r + i*(cy_r + k*stepy_r), given
      -- as real numbers, and compare with the model and with real numbers.
      procedure check (
         cx_r       : real;
         cy_r       : real;
         stepy_r    : real;
         max_cycles : integer := integer'high
      ) is
      begin
         run(to_fixed_wide(cx_r), to_fixed_wide(cy_r), to_fixed_wide(stepy_r), true, max_cycles);
      end procedure check;

      -- Leave the iterator idle for a number of clock cycles
      procedure idle (cycles : positive) is
      begin
         for i in 1 to cycles loop
            wait until rising_edge(clk);
         end loop;
      end procedure idle;

   begin
      wait until rst = '0';

      for t in 1 to 5 loop
         wait until rising_edge(clk);
         assert done = '0'
            report "Done after reset"
            severity error;
      end loop;

      -- In the set, so maximum count. These are found by the periodicity
      -- detection, so they must finish well before the maximum count. A
      -- point that stops after n iterations takes about 4n+6 clock cycles.
      check( 0.0,   0.0,  0.0,  20);    -- Period 1 (z = 0 for ever)
      check( 0.5,   0.0,  0.0);         -- Escapes, and y alone repeats
      idle(20);
      check(-1.0,   0.0,  0.0,  30);    -- Period 2 (z = 0, -1, 0, -1, ...)
      idle(20);
      check( 0.0,   1.0,  0.0,  30);    -- Period 2 from z2 (z = 0, i, -1+i, -i, -1+i, ...)
      check(-1.0,   1.0,  0.0);         -- Escapes, and x alone repeats
      check( 0.1,   0.1,  0.0, 150);    -- Inside the main cardioid, converges to a fixed point
      check(-0.12,  0.75, 0.0, 160);    -- Inside the period 3 bulb

      -- Four different points: -1+i (escapes after 3 iterations), -1+0.5i
      -- (escapes after 5), -1 (in the set), and -1-0.5i (escapes after 5)
      check(-1.0,   1.0, -0.5,  40);

      -- In the set: 0.1 + 0.1i to 0.1 + 0.13i
      check( 0.1,   0.1,  0.01, 200);

      check( 1.0,   1.0, -1.0);     -- Escape immediately (the last one is cy = -2)
      check(-2.0,   0.0,  0.0);     -- In the set, but z = 2 is out of range (see ALGORITHM.md)
      check( 0.5,   0.0,  0.25);    -- Escape quickly
      check(-1.0,   0.5,  0.0);     -- Escapes quickly (example from iterator.vhd)
      check( 0.3,   0.0,  0.0);     -- Escapes slowly, near the edge of the set, and y alone repeats
      check(-0.75,  0.1,  0.0);     -- Escapes slowly, near the edge of the set
      check(-0.1,   0.65, 0.0);     -- Escapes slowly, near the edge of the set
      check(-0.17,  1.09, 0.0);     -- x+y is out of range (-2 to 2) during the iteration
      check( 0.02, -1.01, 0.0);     -- x-y is out of range (-2 to 2) during the iteration
      check(-0.75,  0.1,  0.0001);  -- Four points that escape slowly, at different times

      -- The saved values of the periodicity detection are not cleared at the
      -- start: c = 0 leaves 0, which is z0 of the next point, and c = i
      -- leaves -1+i, which is z1 for c = -1+i.
      check( 0.0,   0.0,  0.0,  20);
      check( 0.5,   0.0,  0.0);
      check( 0.0,   1.0,  0.0,  30);
      check(-1.0,   1.0,  0.0);

      -- The values of cy wrap around: cy = 1.99995 + k*0.00004, so the last
      -- two are -1.99997 and -1.99993 (after wrapping around)
      run(to_fixed_wide(-0.5), to_fixed_wide(1.99995), to_fixed_wide(0.00004), false, integer'high);

      -- A grid of 40 x 32 points over the initial view (-1.6667 to 1 and -1 to
      -- 1). The steps are not round numbers, so many different values occur.
      for row in 0 to 7 loop
         for col in 0 to 39 loop
            run(to_fixed_wide(-1.6667 + real(col) * 0.0667123),
                to_fixed_wide(-1.0 + real(4*row) * 0.0625123),
                to_fixed_wide(0.0625123), false, integer'high);
         end loop;
      end loop;

      assert idle_cycles >= 30
         report "Only " & integer'image(idle_cycles) & " idle clock cycles were checked"
         severity error;

      report "iterator_wide_tb: finished";
      std.env.finish;
   end process p_test;


   -------------------
   -- Instantiate DUT
   -------------------

   i_iterator_wide : entity work.iterator_wide
      generic map (
         G_MAX_COUNT => C_MAX_COUNT
      )
      port map (
         clk_i   => clk,
         rst_i   => rst,
         start_i => start,
         cx_i    => cx,
         cy_i    => cy,
         stepy_i => stepy,
         cnt_o   => cnt,
         done_o  => done
      ); -- i_iterator_wide


   ----------------------------------------------
   -- The registers do not change while idle
   ----------------------------------------------

   -- At each rising edge x_r and y_r keep their value if done was high and
   -- start was low before the edge. The inputs of the DSPs come from x_r and
   -- y_r, so the registers P of the DSPs keep their value from the fourth
   -- such edge (the last DSP is three stages after x_r and y_r). The registers
   -- are inside the iterator, so they are read with external names, which
   -- must come after the instantiation of the iterator.
   p_idle : process (clk)
      subtype value_t is std_logic_vector(34 downto 0);
      alias x_r  is << signal .iterator_wide_tb.i_iterator_wide.x_r : value_t >>;
      alias y_r  is << signal .iterator_wide_tb.i_iterator_wide.y_r : value_t >>;
      alias p2_r is << signal .iterator_wide_tb.i_iterator_wide.p2_r : signed(37 downto 0) >>;
      alias p3_r is << signal .iterator_wide_tb.i_iterator_wide.p3_r : signed(37 downto 0) >>;
      alias p5_r is << signal .iterator_wide_tb.i_iterator_wide.p5_r : signed(37 downto 0) >>;
      alias p6_r is << signal .iterator_wide_tb.i_iterator_wide.p6_r : signed(37 downto 0) >>;
      -- The number of rising edges since done went high (while start is low)
      variable idle_v : natural := 0;
      variable x_v    : value_t;
      variable y_v    : value_t;
      variable p_v    : signed(4*38-1 downto 0);
   begin
      if rising_edge(clk) then
         if idle_v >= 1 then
            assert x_r = x_v and y_r = y_v
               report "x_r or y_r changed while the iterator was idle"
               severity error;
         end if;
         if idle_v >= 4 then
            assert (p2_r & p3_r & p5_r & p6_r) = p_v
               report "The registers P changed while the iterator was idle"
               severity error;
            idle_cycles <= idle_cycles + 1;
         end if;
         if done = '1' and start = '0' and rst = '0' then
            idle_v := idle_v + 1;
         else
            idle_v := 0;
         end if;
         x_v := x_r;
         y_v := y_r;
         p_v := p2_r & p3_r & p5_r & p6_r;
      end if;
   end process p_idle;

end architecture simulation;
