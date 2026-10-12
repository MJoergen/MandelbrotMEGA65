-- This is a self-checking testbench for the clock domain crossing of a value
-- (cdc_data.vhd). In the source clock domain it gives the module a new value
-- (40 random bits) after a random time, with a pulse on s_valid_i, as
-- main.vhd does with the frame rate after each picture. In the destination
-- clock domain it checks at every rising edge:
-- * Until the first value, the output is G_INIT.
-- * The output is always either the latest value sent or the one before it,
--   i.e. it is never a mix of the two, and it never changes back.
-- * The latest value arrives at most one source clock cycle and four
--   destination clock cycles after the pulse.
-- This is done for the clocks of both boards (from the MAIN clock to the VGA
-- clock), each with its own instance: the MEGA65 (141.64 MHz and 108 MHz)
-- and the Nexys 4 DDR (120 MHz and 25 MHz). The time between two values is
-- at least ten destination clock cycles.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity cdc_data_tb is
end entity cdc_data_tb;

architecture simulation of cdc_data_tb is

   type config_t is record
      s_period : time;   -- The source clock
      m_period : time;   -- The destination clock
   end record config_t;
   type config_vector is array (natural range <>) of config_t;

   constant C_CONFIGS : config_vector := (
      (s_period => 7.060 ns, m_period =>  9.259 ns),   -- MEGA65
      (s_period => 8.333 ns, m_period => 40.000 ns));  -- Nexys 4 DDR

   -- The values have 40 bits, as the frame rate (32 bits of digits and 8
   -- bits of blanking), and the initial value is the one of the overlay
   -- (all digits blanked)
   constant C_DATA_SIZE  : positive := 40;
   constant C_INIT       : std_logic_vector(C_DATA_SIZE-1 downto 0) := X"00000000FF";

   -- The number of values sent to each instance
   constant C_NUM_VALUES : positive := 200;

   signal finished : std_logic_vector(C_CONFIGS'range) := (others => '0');

begin

   p_finish : process
   begin
      wait until finished = (finished'range => '1');
      report "cdc_data_tb: finished";
      std.env.finish;
   end process p_finish;


   gen_dut : for n in C_CONFIGS'range generate
      constant C_S_PERIOD : time := C_CONFIGS(n).s_period;
      constant C_M_PERIOD : time := C_CONFIGS(n).m_period;

      -- The longest time from the pulse until the value arrives
      constant C_MAX_LAT  : time := C_S_PERIOD + 4 * C_M_PERIOD;

      signal s_clk     : std_logic := '0';
      signal m_clk     : std_logic := '0';
      signal s_data    : std_logic_vector(C_DATA_SIZE-1 downto 0) := C_INIT;
      signal s_valid   : std_logic := '0';
      signal m_data    : std_logic_vector(C_DATA_SIZE-1 downto 0);

      -- The number of values sent so far, the latest and the one before it,
      -- and the time of the latest pulse
      signal sent      : natural := 0;
      signal latest    : std_logic_vector(C_DATA_SIZE-1 downto 0) := C_INIT;
      signal previous  : std_logic_vector(C_DATA_SIZE-1 downto 0) := C_INIT;
      signal sent_time : time := 0 ns;

   begin

      s_clk <= not s_clk after C_S_PERIOD / 2;
      m_clk <= not m_clk after C_M_PERIOD / 2;


      -------------------------------------------
      -- Send the values (source clock domain)
      -------------------------------------------

      p_send : process
         variable seed1_v : positive := 1 + n;
         variable seed2_v : positive := 7 + n;
         variable r_v     : real;
         variable byte_v  : std_logic_vector( 7 downto 0);
         variable value_v : std_logic_vector(C_DATA_SIZE-1 downto 0);
         variable wait_v  : natural;
      begin
         for i in 1 to C_NUM_VALUES loop
            -- Wait between 10 and 40 destination clock cycles
            uniform(seed1_v, seed2_v, r_v);
            wait_v := integer(ceil((10.0 + 30.0 * r_v) * real(C_M_PERIOD / 1 ps) /
                                   real(C_S_PERIOD / 1 ps)));
            for t in 1 to wait_v loop
               wait until rising_edge(s_clk);
            end loop;

            -- A new value, different from the latest one in every byte
            -- (byte_v is at most 254, so it is never X"FF")
            for b in 0 to C_DATA_SIZE/8-1 loop
               uniform(seed1_v, seed2_v, r_v);
               byte_v := std_logic_vector(to_unsigned(integer(trunc(r_v * 255.0)), 8));
               value_v(8*b+7 downto 8*b) := byte_v xor latest(8*b+7 downto 8*b) xor X"FF";
            end loop;

            s_data    <= value_v;
            s_valid   <= '1';
            previous  <= latest;
            latest    <= value_v;
            sent      <= i;
            sent_time <= now;
            wait until rising_edge(s_clk);
            s_valid   <= '0';
         end loop;

         -- Let the last one arrive
         wait for 2 * C_MAX_LAT;
         finished(n) <= '1';
         wait;
      end process p_send;


      ---------------------------------------------
      -- Check the value (destination clock domain)
      ---------------------------------------------

      p_check : process (m_clk)
         variable seen_v : natural := 0;    -- The latest value seen
      begin
         if rising_edge(m_clk) then
            if m_data = latest then
               -- Before the first value, latest is C_INIT
               seen_v := sent;
            elsif m_data = previous and sent > 0 then
               assert seen_v < sent
                  report "Value " & integer'image(sent) & " changed back to the one before it"
                  severity error;
               assert now - sent_time <= C_MAX_LAT
                  report "Value " & integer'image(sent) & " has not arrived after " &
                         time'image(now - sent_time)
                  severity error;
            else
               report "The output is neither the latest value nor the one before it, " &
                      "after value " & integer'image(sent)
                  severity error;
            end if;
         end if;
      end process p_check;


      -------------------
      -- Instantiate DUT
      -------------------

      i_cdc_data : entity work.cdc_data
         generic map (
            G_DATA_SIZE => C_DATA_SIZE,
            G_INIT      => C_INIT
         )
         port map (
            s_clk_i   => s_clk,
            s_data_i  => s_data,
            s_valid_i => s_valid,
            m_clk_i   => m_clk,
            m_data_o  => m_data
         ); -- i_cdc_data

   end generate gen_dut;

end architecture simulation;
