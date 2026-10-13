-- This is a self-checking testbench for the mapping of the joysticks and the
-- keyboard of the MEGA65 to the buttons and switches (controls.vhd). It
-- behaves like the keyboard driver (m2m_keyb.vhd): it cycles through all the
-- keys, each for C_HOLD clock cycles, and shows whether each one is pressed.
-- It checks:
-- * Nothing is pressed after power-on, and palette 3 (fire) is selected.
-- * Each of the keys used, on its own, gives the expected button or switch,
--   and each key "1" to "4" selects its palette, which stays selected when
--   the key is released.
-- * The space bar toggles the movement of the palette (switch 3), once for
--   each press.
-- * When several of the keys "1" to "4" are pressed, the lowest one wins, and
--   the palette does not change during the scan.
-- * All 64 combinations of the joystick inputs, with no key pressed.
-- * Random combinations of pressed keys (also the keys that are not used) and
--   joystick inputs.
-- The inputs are changed at the start of a cycle through the keys (key 0), as
-- the palette is only changed at the end of a cycle. After each change it
-- waits for that cycle, and then checks the outputs in every clock cycle of
-- the next cycle through the keys, so they must not change while the inputs
-- stay the same.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity controls_tb is
end entity controls_tb;

architecture simulation of controls_tb is

   constant C_NUM_KEYS  : natural := 80;
   constant C_HOLD      : natural := 3;  -- Clock cycles for each key
   constant C_SCAN      : natural := C_NUM_KEYS * C_HOLD;
   constant C_KEY_UP    : natural := 73;
   constant C_KEY_DOWN  : natural := 7;
   constant C_KEY_LEFT  : natural := 74;
   constant C_KEY_RIGHT : natural := 2;
   constant C_KEY_PLUS  : natural := 40;
   constant C_KEY_MINUS : natural := 43;
   constant C_KEY_1     : natural := 56;
   constant C_KEY_2     : natural := 59;
   constant C_KEY_3     : natural := 8;
   constant C_KEY_4     : natural := 11;
   constant C_KEY_SPACE : natural := 60;

   -- The keys "1" to "4", for the palettes 1 to 4
   type nat_vector is array (natural range <>) of natural;
   constant C_PALETTE_KEYS : nat_vector(0 to 3) := (C_KEY_1, C_KEY_2, C_KEY_3, C_KEY_4);

   -- The joystick inputs, active low: fire of port 2, then fire, left, right,
   -- up, and down of port 1
   constant C_JOY_NONE : std_logic_vector(5 downto 0) := "111111";

   signal clk           : std_logic;
   signal pressed       : std_logic_vector(C_NUM_KEYS-1 downto 0) := (others => '0');
   signal joy_n         : std_logic_vector(5 downto 0)            := C_JOY_NONE;
   signal key_num       : natural range 0 to C_NUM_KEYS-1         := 0;
   signal hold_cnt      : natural range 0 to C_HOLD-1             := 0;
   signal key_pressed_n : std_logic;
   signal btn           : std_logic_vector(4 downto 0);
   signal sw            : std_logic_vector(7 downto 0);

begin

   ----------------------------
   -- Generate clock
   ----------------------------

   p_clk : process
   begin
      clk <= '0', '1' after 5 ns;
      wait for 10 ns;
   end process p_clk;


   ----------------------------
   -- Keyboard driver
   ----------------------------

   p_key_num : process (clk)
   begin
      if rising_edge(clk) then
         if hold_cnt = C_HOLD-1 then
            hold_cnt <= 0;
            key_num  <= (key_num + 1) mod C_NUM_KEYS;
         else
            hold_cnt <= hold_cnt + 1;
         end if;
      end if;
   end process p_key_num;

   key_pressed_n <= not pressed(key_num);


   ----------------------------
   -- Instantiate DUT
   ----------------------------

   i_controls : entity work.controls
      port map (
         clk_i           => clk,
         key_num_i       => key_num,
         key_pressed_n_i => key_pressed_n,
         fa_up_n_i       => joy_n(1),
         fa_down_n_i     => joy_n(0),
         fa_left_n_i     => joy_n(3),
         fa_right_n_i    => joy_n(2),
         fa_fire_n_i     => joy_n(4),
         fb_fire_n_i     => joy_n(5),
         btn_o           => btn,
         sw_o            => sw
      ); -- i_controls


   ----------------------------
   -- Test
   ----------------------------

   p_test : process
      variable palette_v : natural range 0 to 3 := 2;
      variable move_v    : std_logic := '0';
      variable space_v   : std_logic := '0';
      variable seed1_v   : positive := 1;
      variable seed2_v   : positive := 1;
      variable rand_v    : real;
      variable keys_v    : std_logic_vector(C_NUM_KEYS-1 downto 0);
      variable joy_v     : std_logic_vector(5 downto 0);

      -- Set the inputs, wait for one cycle through the keys, and check the
      -- outputs during the next one. palette_v is the palette that was
      -- selected before, move_v is the movement, and space_v is whether the
      -- space bar was pressed before. They are updated here.
      procedure check (keys : std_logic_vector(C_NUM_KEYS-1 downto 0);
                       joy  : std_logic_vector(5 downto 0);
                       msg  : string) is
         variable btn_v : std_logic_vector(4 downto 0);
         variable sw_v  : std_logic_vector(7 downto 0);
      begin
         -- Start of a cycle through the keys
         wait until rising_edge(clk) and key_num = C_NUM_KEYS-1 and hold_cnt = C_HOLD-1;
         pressed <= keys;
         joy_n   <= joy;

         -- The lowest key "1" to "4" wins
         for i in 3 downto 0 loop
            if keys(C_PALETTE_KEYS(i)) = '1' then
               palette_v := i;
            end if;
         end loop;

         btn_v(4) := not (joy(4) and joy(5)) or keys(C_KEY_PLUS) or keys(C_KEY_MINUS);
         btn_v(3) := not joy(3) or keys(C_KEY_LEFT);
         btn_v(2) := not joy(2) or keys(C_KEY_RIGHT);
         btn_v(1) := not joy(1) or keys(C_KEY_UP);
         btn_v(0) := not joy(0) or keys(C_KEY_DOWN);
         if keys(C_KEY_SPACE) = '1' and space_v = '0' then
            move_v := not move_v;
         end if;
         space_v := keys(C_KEY_SPACE);
         sw_v     := "0000" & move_v & (not joy(5) or keys(C_KEY_MINUS)) &
                     std_logic_vector(to_unsigned(palette_v, 2));

         -- Two more clock cycles: one for the registers of the keys, and one
         -- for the palette
         for i in 1 to C_SCAN + 2 loop
            wait until rising_edge(clk);
         end loop;

         for i in 1 to C_SCAN loop
            wait until falling_edge(clk);
            assert btn = btn_v
               report msg & ": btn is " & to_string(btn) & ", expected " & to_string(btn_v)
               severity error;
            assert sw = sw_v
               report msg & ": sw is " & to_string(sw) & ", expected " & to_string(sw_v)
               severity error;
         end loop;
      end procedure check;

      -- Only the key k is pressed
      function key (k : natural) return std_logic_vector is
         variable res_v : std_logic_vector(C_NUM_KEYS-1 downto 0) := (others => '0');
      begin
         res_v(k) := '1';
         return res_v;
      end function key;

      constant C_NO_KEYS : std_logic_vector(C_NUM_KEYS-1 downto 0) := (others => '0');

   begin
      -- After power-on, the outputs are checked without changing the inputs
      check(C_NO_KEYS, C_JOY_NONE, "Power-on");

      -- Each key on its own, and released again
      for k in 0 to C_NUM_KEYS-1 loop
         check(key(k), C_JOY_NONE, "Key " & to_string(k));
         check(C_NO_KEYS, C_JOY_NONE, "Key " & to_string(k) & " released");
      end loop;

      -- The palette keys in another order than above
      for i in 0 to 3 loop
         check(key(C_PALETTE_KEYS((i + 2) mod 4)), C_JOY_NONE, "Palette key " & to_string(i));
         check(C_NO_KEYS, C_JOY_NONE, "Palette key " & to_string(i) & " released");
      end loop;

      -- Several palette keys at the same time
      for i in 1 to 15 loop
         keys_v := C_NO_KEYS;
         for j in 0 to 3 loop
            if (i / 2**j) mod 2 = 1 then
               keys_v(C_PALETTE_KEYS(j)) := '1';
            end if;
         end loop;
         check(keys_v, C_JOY_NONE, "Palette keys " & to_string(i));
         check(key(C_PALETTE_KEYS(3 - (i mod 4))), C_JOY_NONE, "Palette key after " & to_string(i));
      end loop;

      -- The space bar, held down for several scans, and pressed again
      check(key(C_KEY_SPACE), C_JOY_NONE, "Space");
      check(key(C_KEY_SPACE), C_JOY_NONE, "Space held");
      check(C_NO_KEYS, C_JOY_NONE, "Space released");
      check(key(C_KEY_SPACE), C_JOY_NONE, "Space again");
      check(C_NO_KEYS, C_JOY_NONE, "Space released again");

      -- All the combinations of the joystick inputs
      for i in 0 to 63 loop
         check(C_NO_KEYS, std_logic_vector(to_unsigned(i, 6)), "Joystick " & to_string(i));
      end loop;

      -- Random keys and joystick inputs
      for i in 1 to 300 loop
         for k in 0 to C_NUM_KEYS-1 loop
            uniform(seed1_v, seed2_v, rand_v);
            keys_v(k) := '1' when rand_v < 0.1 else '0';
         end loop;
         for j in 0 to 5 loop
            uniform(seed1_v, seed2_v, rand_v);
            joy_v(j) := '0' when rand_v < 0.3 else '1';
         end loop;
         check(keys_v, joy_v, "Random " & to_string(i));
      end loop;

      report "controls_tb: finished";
      std.env.finish;
   end process p_test;

end architecture simulation;
