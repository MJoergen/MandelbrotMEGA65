-- This is a self-checking testbench for the frame rate (fps.vhd) and the
-- 7-segment display (seg.vhd). It has two instances of fps, each driving a
-- display. They have the clock frequencies of the boards, the MEGA65
-- (180,000,000 Hz, a quotient of 28 bits) and the Nexys 4 DDR (120,000,000 Hz,
-- a quotient of 27 bits). The testbench gives each of them a number of picture
-- times, and for each one it checks:
-- * The digits and the blanking from fps are the expected frame rate, i.e.
--   the clock frequency divided by the time, rounded down, with leading zeros
--   blanked. Values that do not fit in 8 digits show 99999999.
-- * The display shows the same number: During a full refresh cycle each
--   digit that is not blanked is switched on with the right segments, the
--   blanked digits are never switched on, and at most one digit is on at a
--   time.
-- The times include the extremes (0, 1, and the largest time), the values
-- around a change of the frame rate, and random values over the whole range.
-- It also checks that a pulse on valid_i during a calculation does not start
-- a new calculation.
--
-- The refresh of the display is made much faster than on the board, so a
-- full refresh cycle is 64 clock cycles.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity fps_tb is
end entity fps_tb;

architecture simulation of fps_tb is

   -- The frequencies of the MAIN clock of the MEGA65 and of the Nexys 4 DDR
   -- (G_CLK_FREQ of main.vhd)
   type freq_vector is array (natural range <>) of natural;
   constant C_CLK_FREQS    : freq_vector := (180_000_000, 120_000_000);

   constant C_TIME_BITS    : natural := 27;
   constant C_REFRESH_BITS : natural := 6;
   constant C_MAX          : natural := 99_999_999;

   -- Longer than a calculation (58 clock cycles)
   constant C_CALC_CYCLES  : natural := 70;

   type seg_table_t is array (0 to 9) of std_logic_vector(6 downto 0);
   constant C_SEG_TABLE : seg_table_t := (
      "0111111", "0000110", "1011011", "1001111", "1100110",
      "1101101", "1111101", "0000111", "1111111", "1101111");

   signal clk       : std_logic;
   signal rst       : std_logic := '1';
   signal test_done : std_logic_vector(C_CLK_FREQS'range) := (others => '0');

   -- The frame rate for the clock frequency f and the time t
   function expected_fps(f : natural; t : natural) return natural is
   begin
      if t = 0 or f / t > C_MAX then
         return C_MAX;
      end if;
      return f / t;
   end function expected_fps;

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
      wait until rising_edge(clk);
      rst <= '0';
      wait;
   end process p_rst;


   -------------------------------------------------
   -- At the clocks of the boards
   -------------------------------------------------

   gen_clk : for n in C_CLK_FREQS'range generate
      constant C_FREQ : natural := C_CLK_FREQS(n);

      signal time_s : std_logic_vector(C_TIME_BITS-1 downto 0) := (others => '0');
      signal valid  : std_logic := '0';
      signal digits : std_logic_vector(31 downto 0);
      signal blank  : std_logic_vector( 7 downto 0);
      signal seg_s  : std_logic_vector( 6 downto 0);
      signal seg_an : std_logic_vector( 7 downto 0);

   begin

      i_fps : entity work.fps
         generic map (
            G_CLK_FREQ  => C_FREQ,
            G_TIME_BITS => C_TIME_BITS,
            G_DIGITS    => 8
         )
         port map (
            clk_i    => clk,
            rst_i    => rst,
            time_i   => time_s,
            valid_i  => valid,
            digits_o => digits,
            blank_o  => blank
         ); -- i_fps

      i_seg : entity work.seg
         generic map (
            G_REFRESH_BITS => C_REFRESH_BITS
         )
         port map (
            clk_i    => clk,
            digits_i => digits,
            blank_i  => blank,
            seg_o    => seg_s,
            seg_an_o => seg_an
         ); -- i_seg


      ----------------------------
      -- Stimulus and checking
      ----------------------------

      p_test : process
         variable seed1_v    : positive := 1 + n;
         variable seed2_v    : positive := 2 + n;
         variable r_v        : real;
         variable num_test_v : natural := 0;

         procedure start(t : natural) is
         begin
            time_s <= std_logic_vector(to_unsigned(t, C_TIME_BITS));
            valid  <= '1';
            wait until rising_edge(clk);
            valid  <= '0';
            time_s <= (others => 'X');
         end procedure start;

         -- Check that the outputs of fps and the display show the value v
         procedure check(v : natural; t : natural) is
            variable d_v         : natural;
            variable lead_v      : boolean;
            variable exp_blank_v : std_logic_vector(7 downto 0);
            variable seen_v      : std_logic_vector(7 downto 0);
            variable digit_v     : natural;
            variable ones_v      : natural;
         begin
            -- Expected digits and blanking
            lead_v := true;
            for i in 7 downto 0 loop
               d_v            := (v / 10**i) mod 10;
               lead_v         := lead_v and d_v = 0 and i > 0;
               exp_blank_v(i) := '1' when lead_v else '0';
               assert digits(4*i+3 downto 4*i) = std_logic_vector(to_unsigned(d_v, 4))
                  report "Wrong digit " & integer'image(i) & " for time " &
                         integer'image(t) & ", expected " & integer'image(v)
                  severity error;
            end loop;
            assert blank = exp_blank_v
               report "Wrong blanking for time " & integer'image(t) &
                      ", expected " & integer'image(v)
               severity error;

            -- Watch the display for a full refresh cycle (plus a little)
            seen_v := (others => '0');
            for c in 0 to 2**C_REFRESH_BITS + 4 loop
               wait until rising_edge(clk);
               ones_v := 0;
               for i in 0 to 7 loop
                  if seg_an(i) = '0' then
                     ones_v    := ones_v + 1;
                     seen_v(i) := '1';
                     assert exp_blank_v(i) = '0'
                        report "Blanked digit " & integer'image(i) &
                               " switched on for value " & integer'image(v)
                        severity error;
                     digit_v := (v / 10**i) mod 10;
                     assert seg_s = not C_SEG_TABLE(digit_v)
                        report "Wrong segments on digit " & integer'image(i) &
                               " for value " & integer'image(v)
                        severity error;
                  end if;
               end loop;
               assert ones_v <= 1
                  report "More than one digit switched on"
                  severity error;
            end loop;
            assert seen_v = not exp_blank_v
               report "Not all digits shown for value " & integer'image(v)
               severity error;
            num_test_v := num_test_v + 1;
         end procedure check;

         procedure test(t : natural) is
         begin
            start(t);
            for i in 1 to C_CALC_CYCLES loop
               wait until rising_edge(clk);
            end loop;
            check(expected_fps(C_FREQ, t), t);
         end procedure test;

         -- The frame rate is given for 180,000,000 Hz, and in brackets for
         -- 120,000,000 Hz when it differs.
         type time_list_t is array (natural range <>) of natural;
         constant C_TIMES : time_list_t := (
            C_FREQ / 200 + 1,   -- 199
            C_FREQ / 200,       -- 200
            C_FREQ / 100,       -- 100
            C_FREQ / 100 + 1,   -- 99
            1_000,              -- 180000 (120000)
            C_FREQ / 1000,      -- 1000
            2**C_TIME_BITS - 1, -- 1 (0)
            1, 2, 3,            -- Saturated, 90000000, 60000000 (60000000, 40000000)
            0,                  -- Saturated
            C_FREQ / C_MAX,     -- 1 (saturated)
            C_FREQ / C_MAX + 1,
            10, 100, 10_000, 100_000, 1_000_000);

      begin
         wait until rst = '0';
         wait until rising_edge(clk);

         -- After reset the display shows 0
         check(0, 0);

         for i in C_TIMES'range loop
            test(C_TIMES(i));
         end loop;

         -- A pulse on valid during a calculation does not start a calculation
         start(C_FREQ / 200);
         for i in 1 to 10 loop
            wait until rising_edge(clk);
         end loop;
         start(C_FREQ / 96);
         for i in 1 to C_CALC_CYCLES loop
            wait until rising_edge(clk);
         end loop;
         check(expected_fps(C_FREQ, C_FREQ / 200), C_FREQ / 200);

         -- Random times, spread evenly over the number of bits
         for i in 1 to 300 loop
            uniform(seed1_v, seed2_v, r_v);
            test(integer(trunc(2.0 ** (r_v * real(C_TIME_BITS)))) mod 2**C_TIME_BITS);
         end loop;

         report integer'image(C_FREQ) & " Hz: " & integer'image(num_test_v) &
                " values checked";
         test_done(n) <= '1';
         wait;
      end process p_test;

   end generate gen_clk;


   p_finish : process
   begin
      wait until test_done = (test_done'range => '1');
      report "fps_tb: finished";
      std.env.finish;
   end process p_finish;

end architecture simulation;
