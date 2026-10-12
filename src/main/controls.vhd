-- This module maps the controls of the MEGA65, i.e. the joysticks and the
-- keyboard, to the buttons and switches of the Nexys 4 DDR, which are the
-- inputs btn_i and sw_i of main.vhd (see the description there):
-- * btn_o(4), zoom: the fire buttons of both joystick ports, and the "+" and
--   "-" keys.
-- * sw_o(2), zoom out instead of in: the fire button of joystick port 2, and
--   the "-" key.
-- * btn_o(3 downto 0), pan left, right, up, and down: the directions of
--   joystick port 1, and the cursor keys.
-- * sw_o(1 downto 0), the palette (see palette_pkg.vhd): the keys "1" to "4"
--   select the palettes 0 to 3. The palette stays selected when the key is
--   released, and palette 0 is used after power-on. The palette is only
--   changed at the end of a cycle through the keys (key 79), when all the
--   keys have been read, so it changes only once when a key is pressed while
--   another one is released. If several of these keys are pressed, the lowest
--   one wins, so the palette does not change back and forth while they are
--   held down.
-- The other switches are always off.
--
-- The keyboard is read by the MiSTer2MEGA65 keyboard driver (m2m_keyb.vhd, in
-- the MAIN clock domain), which cycles through all the keys (key_num_i), and
-- shows whether each of them is pressed (key_pressed_n_i, active low). The
-- keys that are used are stored here (p_keys). The key numbers are the same
-- as in the MiSTer2MEGA65 framework, see e.g. matrix_to_keynum.vhd. The
-- MEGA65 has separate keys for cursor up and left (73 and 74), unlike the
-- C64, where they are SHIFT with cursor down and right (7 and 2).
--
-- The joystick lines are active low, and asynchronous. They are combined with
-- the keys without a register, because main.vhd synchronizes the outputs (and
-- vga.vhd synchronizes the palette).

library ieee;
use ieee.std_logic_1164.all;

entity controls is
   port (
      clk_i           : in  std_logic;                      -- MAIN clock

      -- From the keyboard driver
      key_num_i       : in  natural range 0 to 79;
      key_pressed_n_i : in  std_logic;

      -- Joystick ports, active low
      fa_up_n_i       : in  std_logic;
      fa_down_n_i     : in  std_logic;
      fa_left_n_i     : in  std_logic;
      fa_right_n_i    : in  std_logic;
      fa_fire_n_i     : in  std_logic;
      fb_fire_n_i     : in  std_logic;

      -- To main.vhd
      btn_o           : out std_logic_vector( 4 downto 0);  -- "CLRUD"
      sw_o            : out std_logic_vector( 7 downto 0)
   );
end entity controls;

architecture rtl of controls is

   -- The key numbers, see matrix_to_keynum.vhd
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
   constant C_KEY_LAST  : natural := 79;

   -- The keys that are used, active high
   signal key_up_r    : std_logic := '0';
   signal key_down_r  : std_logic := '0';
   signal key_left_r  : std_logic := '0';
   signal key_right_r : std_logic := '0';
   signal key_plus_r  : std_logic := '0';
   signal key_minus_r : std_logic := '0';
   signal key_1_r     : std_logic := '0';
   signal key_2_r     : std_logic := '0';
   signal key_3_r     : std_logic := '0';
   signal key_4_r     : std_logic := '0';

   -- The selected palette
   signal palette_r   : std_logic_vector(1 downto 0) := "00";

begin

   p_keys : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case key_num_i is
            when C_KEY_UP    => key_up_r    <= not key_pressed_n_i;
            when C_KEY_DOWN  => key_down_r  <= not key_pressed_n_i;
            when C_KEY_LEFT  => key_left_r  <= not key_pressed_n_i;
            when C_KEY_RIGHT => key_right_r <= not key_pressed_n_i;
            when C_KEY_PLUS  => key_plus_r  <= not key_pressed_n_i;
            when C_KEY_MINUS => key_minus_r <= not key_pressed_n_i;
            when C_KEY_1     => key_1_r     <= not key_pressed_n_i;
            when C_KEY_2     => key_2_r     <= not key_pressed_n_i;
            when C_KEY_3     => key_3_r     <= not key_pressed_n_i;
            when C_KEY_4     => key_4_r     <= not key_pressed_n_i;
            when others      => null;
         end case;
      end if;
   end process p_keys;

   -- At the end of a cycle through the keys, the lowest key wins, see above
   p_palette : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if key_num_i = C_KEY_LAST then
            if key_1_r = '1' then
               palette_r <= "00";
            elsif key_2_r = '1' then
               palette_r <= "01";
            elsif key_3_r = '1' then
               palette_r <= "10";
            elsif key_4_r = '1' then
               palette_r <= "11";
            end if;
         end if;
      end if;
   end process p_palette;

   -- Both fire buttons and both "+" and "-" zoom, switch 2 selects zoom out
   btn_o(4) <= not (fa_fire_n_i and fb_fire_n_i) or key_plus_r or key_minus_r;
   btn_o(3) <= not fa_left_n_i  or key_left_r;
   btn_o(2) <= not fa_right_n_i or key_right_r;
   btn_o(1) <= not fa_up_n_i    or key_up_r;
   btn_o(0) <= not fa_down_n_i  or key_down_r;
   sw_o     <= "00000" & (not fb_fire_n_i or key_minus_r) & palette_r;

end architecture rtl;
