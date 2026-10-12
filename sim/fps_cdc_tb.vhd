-- This is a self-checking testbench for the clock domain crossing of the
-- frame rate (fps_cdc.vhd). In the MAIN clock domain it gives the module a
-- new frame rate (random digits and blanking) after a random time, as
-- main.vhd does after each picture, with a pulse on main_valid_i. In the VGA
-- clock domain it checks at every rising edge:
-- * Until the first frame rate, all the digits are blanked.
-- * The frame rate is always either the latest one sent or the one before
--   it, i.e. it is never a mix of the two, and it never changes back.
-- * The latest frame rate arrives at most one MAIN clock cycle and four VGA
--   clock cycles after the pulse.
-- This is done for the clocks of both boards, each with its own instance:
-- the MEGA65 (141.64 MHz and 108 MHz) and the Nexys 4 DDR (120 MHz and
-- 25 MHz). The time between two frame rates is at least ten VGA clock cycles,
-- which is far less than on the boards (a picture takes at least 0.7 ms).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity fps_cdc_tb is
end entity fps_cdc_tb;

architecture simulation of fps_cdc_tb is

   type config_t is record
      main_period : time;
      vga_period  : time;
   end record config_t;
   type config_vector is array (natural range <>) of config_t;

   constant C_CONFIGS : config_vector := (
      (main_period => 7.060 ns, vga_period =>  9.259 ns),   -- MEGA65
      (main_period => 8.333 ns, vga_period => 40.000 ns));  -- Nexys 4 DDR

   -- The number of frame rates sent to each instance
   constant C_NUM_VALUES : positive := 200;

   signal finished : std_logic_vector(C_CONFIGS'range) := (others => '0');

begin

   p_finish : process
   begin
      wait until finished = (finished'range => '1');
      report "fps_cdc_tb: finished";
      std.env.finish;
   end process p_finish;


   gen_dut : for n in C_CONFIGS'range generate
      constant C_MAIN_PERIOD : time := C_CONFIGS(n).main_period;
      constant C_VGA_PERIOD  : time := C_CONFIGS(n).vga_period;

      -- The longest time from the pulse until the frame rate arrives
      constant C_MAX_LAT     : time := C_MAIN_PERIOD + 4 * C_VGA_PERIOD;

      signal main_clk    : std_logic := '0';
      signal vga_clk     : std_logic := '0';
      signal main_digits : std_logic_vector(31 downto 0) := (others => '0');
      signal main_blank  : std_logic_vector( 7 downto 0) := (others => '1');
      signal main_valid  : std_logic := '0';
      signal vga_digits  : std_logic_vector(31 downto 0);
      signal vga_blank   : std_logic_vector( 7 downto 0);

      -- The frame rates sent so far, the latest and the one before it (as
      -- digits followed by the blanking), and the time of the latest pulse
      signal sent        : natural := 0;
      signal latest      : std_logic_vector(39 downto 0) := (others => '0');
      signal previous    : std_logic_vector(39 downto 0) := (others => '0');
      signal sent_time   : time := 0 ns;

   begin

      main_clk <= not main_clk after C_MAIN_PERIOD / 2;
      vga_clk  <= not vga_clk after C_VGA_PERIOD / 2;


      ------------------------------------------
      -- Send the frame rates (MAIN clock domain)
      ------------------------------------------

      p_main : process
         variable seed1_v : positive := 1 + n;
         variable seed2_v : positive := 7 + n;
         variable r_v     : real;
         variable byte_v  : std_logic_vector( 7 downto 0);
         variable value_v : std_logic_vector(39 downto 0);
         variable wait_v  : natural;
      begin
         for i in 1 to C_NUM_VALUES loop
            -- Wait between 10 and 40 VGA clock cycles
            uniform(seed1_v, seed2_v, r_v);
            wait_v := integer(ceil((10.0 + 30.0 * r_v) * real(C_VGA_PERIOD / 1 ps) /
                                   real(C_MAIN_PERIOD / 1 ps)));
            for t in 1 to wait_v loop
               wait until rising_edge(main_clk);
            end loop;

            -- A new frame rate, different from the latest one in every byte
            -- (byte_v is at most 254, so it is never X"FF")
            for b in 0 to 4 loop
               uniform(seed1_v, seed2_v, r_v);
               byte_v := std_logic_vector(to_unsigned(integer(trunc(r_v * 255.0)), 8));
               value_v(8*b+7 downto 8*b) := byte_v xor latest(8*b+7 downto 8*b) xor X"FF";
            end loop;

            main_digits <= value_v(39 downto 8);
            main_blank  <= value_v( 7 downto 0);
            main_valid  <= '1';
            previous    <= latest;
            latest      <= value_v;
            sent        <= i;
            sent_time   <= now;
            wait until rising_edge(main_clk);
            main_valid  <= '0';
         end loop;

         -- Let the last one arrive
         wait for 2 * C_MAX_LAT;
         finished(n) <= '1';
         wait;
      end process p_main;


      ----------------------------------------
      -- Check the frame rate (VGA clock domain)
      ----------------------------------------

      p_check : process (vga_clk)
         variable out_v  : std_logic_vector(39 downto 0);
         variable seen_v : natural := 0;    -- The latest frame rate seen
      begin
         if rising_edge(vga_clk) then
            out_v := vga_digits & vga_blank;
            if sent = 0 then
               assert vga_blank = X"FF"
                  report "A frame rate is shown before the first one was sent"
                  severity error;
            elsif out_v = latest then
               seen_v := sent;
            elsif out_v = previous and sent > 1 then
               assert seen_v < sent
                  report "Frame rate " & integer'image(sent) & " changed back to the one before it"
                  severity error;
               assert now - sent_time <= C_MAX_LAT
                  report "Frame rate " & integer'image(sent) & " has not arrived after " &
                         time'image(now - sent_time)
                  severity error;
            elsif sent = 1 and vga_blank = X"FF" and vga_digits = X"00000000" then
               assert now - sent_time <= C_MAX_LAT
                  report "The first frame rate has not arrived after " &
                         time'image(now - sent_time)
                  severity error;
            else
               report "The frame rate is neither the latest one nor the one before it, " &
                      "after frame rate " & integer'image(sent)
                  severity error;
            end if;
         end if;
      end process p_check;


      -------------------
      -- Instantiate DUT
      -------------------

      i_fps_cdc : entity work.fps_cdc
         port map (
            main_clk_i    => main_clk,
            main_digits_i => main_digits,
            main_blank_i  => main_blank,
            main_valid_i  => main_valid,
            vga_clk_i     => vga_clk,
            vga_digits_o  => vga_digits,
            vga_blank_o   => vga_blank
         ); -- i_fps_cdc

   end generate gen_dut;

end architecture simulation;
