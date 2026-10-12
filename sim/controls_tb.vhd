-- This is a self-checking testbench for the controls of the MEGA65
-- (controls.vhd). A model of the keyboard driver cycles through the 80 keys,
-- one in each clock cycle, and shows whether each of them is pressed. The
-- testbench tries every combination of the six joystick lines (up, down,
-- left, right, and the fire buttons of both ports) and the six keys that are
-- used (the four cursor keys, "+", and "-"), each time also with a random set
-- of the other keys pressed. After a full cycle of the keyboard driver, it
-- checks the buttons and switches against the mapping in README.md
-- (Controls):
-- * Zoom (btn 4): either fire button, "+", or "-".
-- * Zoom out (switch 2): the fire button of port 2, or "-".
-- * Pan left, right, up, and down (btn 3 to 0): the directions of port 1,
--   or the cursor keys.
-- * The other switches are off.
-- It also checks that the keys are released again.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity controls_tb is
end entity controls_tb;

architecture simulation of controls_tb is

   -- The keys that are used, in the order of the bits of keys_v below: cursor
   -- up, down, left, and right, "+", and "-" (see matrix_to_keynum.vhd)
   type key_vector is array (natural range <>) of natural;
   constant C_KEYS : key_vector(0 to 5) := (73, 7, 74, 2, 40, 43);

   signal clk           : std_logic;
   signal key_num       : natural range 0 to 79 := 0;
   signal key_pressed_n : std_logic;

   -- The keys pressed, and the joystick lines (active low)
   signal pressed       : std_logic_vector(0 to 79) := (others => '0');
   signal fa_up_n       : std_logic := '1';
   signal fa_down_n     : std_logic := '1';
   signal fa_left_n     : std_logic := '1';
   signal fa_right_n    : std_logic := '1';
   signal fa_fire_n     : std_logic := '1';
   signal fb_fire_n     : std_logic := '1';

   signal btn           : std_logic_vector(4 downto 0);
   signal sw            : std_logic_vector(7 downto 0);

begin

   p_clk : process
   begin
      clk <= '0', '1' after 5 ns;
      wait for 10 ns;
   end process p_clk;

   -- The keyboard driver goes through all the keys, one in each clock cycle
   p_keyb : process (clk)
   begin
      if rising_edge(clk) then
         if key_num < 79 then
            key_num <= key_num + 1;
         else
            key_num <= 0;
         end if;
      end if;
   end process p_keyb;

   key_pressed_n <= not pressed(key_num);


   p_test : process
      variable seed1_v    : positive := 1;
      variable seed2_v    : positive := 2;
      variable r_v        : real;
      variable joy_v      : std_logic_vector(5 downto 0);  -- Up, down, left, right, fire A, fire B
      variable keys_v     : std_logic_vector(5 downto 0);  -- As in C_KEYS
      variable other_v    : std_logic_vector(0 to 79);
      variable exp_btn_v  : std_logic_vector(4 downto 0);
      variable exp_sw_v   : std_logic_vector(7 downto 0);
      variable errors_v   : natural := 0;
   begin
      for c in 0 to 2**12-1 loop
         joy_v  := std_logic_vector(to_unsigned(c mod 64, 6));
         keys_v := std_logic_vector(to_unsigned(c / 64, 6));

         -- Random other keys
         for k in 0 to 79 loop
            uniform(seed1_v, seed2_v, r_v);
            other_v(k) := '1' when r_v < 0.2 else '0';
         end loop;
         for i in C_KEYS'range loop
            other_v(C_KEYS(i)) := keys_v(i);
         end loop;

         pressed    <= other_v;
         fa_up_n    <= not joy_v(0);
         fa_down_n  <= not joy_v(1);
         fa_left_n  <= not joy_v(2);
         fa_right_n <= not joy_v(3);
         fa_fire_n  <= not joy_v(4);
         fb_fire_n  <= not joy_v(5);

         -- A full cycle of the keyboard driver
         for t in 1 to 81 loop
            wait until rising_edge(clk);
         end loop;
         wait for 1 ns;

         exp_btn_v(4) := joy_v(4) or joy_v(5) or keys_v(4) or keys_v(5);
         exp_btn_v(3) := joy_v(2) or keys_v(2);
         exp_btn_v(2) := joy_v(3) or keys_v(3);
         exp_btn_v(1) := joy_v(0) or keys_v(0);
         exp_btn_v(0) := joy_v(1) or keys_v(1);
         exp_sw_v     := (others => '0');
         exp_sw_v(2)  := joy_v(5) or keys_v(5);
         if btn /= exp_btn_v or sw /= exp_sw_v then
            if errors_v < 10 then
               report "Joysticks " & to_string(joy_v) & ", keys " & to_string(keys_v) &
                      ": buttons " & to_string(btn) & ", switches " & to_string(sw) &
                      ", expected " & to_string(exp_btn_v) & " and " & to_string(exp_sw_v)
                  severity error;
            end if;
            errors_v := errors_v + 1;
         end if;
      end loop;

      -- Release everything
      pressed    <= (others => '0');
      fa_up_n    <= '1';
      fa_down_n  <= '1';
      fa_left_n  <= '1';
      fa_right_n <= '1';
      fa_fire_n  <= '1';
      fb_fire_n  <= '1';
      for t in 1 to 81 loop
         wait until rising_edge(clk);
      end loop;
      wait for 1 ns;
      assert btn = "00000" and sw = X"00"
         report "The buttons or switches are still on after everything is released"
         severity error;

      assert errors_v = 0
         report integer'image(errors_v) & " wrong combinations"
         severity error;

      report "controls_tb: finished";
      std.env.finish;
   end process p_test;


   -------------------
   -- Instantiate DUT
   -------------------

   i_controls : entity work.controls
      port map (
         clk_i           => clk,
         key_num_i       => key_num,
         key_pressed_n_i => key_pressed_n,
         fa_up_n_i       => fa_up_n,
         fa_down_n_i     => fa_down_n,
         fa_left_n_i     => fa_left_n,
         fa_right_n_i    => fa_right_n,
         fa_fire_n_i     => fa_fire_n,
         fb_fire_n_i     => fb_fire_n,
         btn_o           => btn,
         sw_o            => sw
      ); -- i_controls

end architecture simulation;
