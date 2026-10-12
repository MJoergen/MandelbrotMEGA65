-- This module moves the frame rate (see fps.vhd) from the MAIN clock domain,
-- where main.vhd calculates it, to the VGA clock domain, where overlay.vhd
-- shows it. It is used by the designs of both boards (mega65.vhd and
-- nexys4ddr.vhd), so main.vhd does not depend on the VGA clock.
--
-- main.vhd sets main_valid_i for one clock cycle each time it changes the
-- frame rate (main_digits_i and main_blank_i), and then a toggle signal is
-- changed (p_toggle). The toggle signal is synchronized to the VGA clock with
-- two registers (p_cdc), and when it changes, the frame rate is copied. The
-- frame rate changes only at the end of a picture, so it is constant for much
-- longer than the synchronizer takes (a few VGA clock cycles), and it is
-- never copied while it changes. Until the first frame rate has been copied,
-- all the digits are blanked, so nothing is shown.
--
-- The constraints for this are in the constraint file of each board
-- (set_max_delay -datapath_only from the MAIN clock to the VGA clock): the
-- frame rate must arrive before the toggle signal, and these paths are left
-- out of the normal timing between the two clocks.

library ieee;
use ieee.std_logic_1164.all;

entity fps_cdc is
   port (
      -- The MAIN clock domain
      main_clk_i    : in  std_logic;
      main_digits_i : in  std_logic_vector(31 downto 0);
      main_blank_i  : in  std_logic_vector( 7 downto 0);
      main_valid_i  : in  std_logic;

      -- The VGA clock domain
      vga_clk_i     : in  std_logic;
      vga_digits_o  : out std_logic_vector(31 downto 0);
      vga_blank_o   : out std_logic_vector( 7 downto 0)
   );
end entity fps_cdc;

architecture rtl of fps_cdc is

   -- Changed each time the frame rate changes
   signal main_toggle_r : std_logic := '0';

   -- The toggle signal in the VGA clock domain, and the frame rate. Nothing
   -- is shown (all digits are blanked) until the first frame rate is copied.
   signal vga_meta      : std_logic := '0';
   signal vga_sync      : std_logic := '0';
   signal vga_sync_d    : std_logic := '0';
   signal vga_digits_r  : std_logic_vector(31 downto 0) := (others => '0');
   signal vga_blank_r   : std_logic_vector( 7 downto 0) := (others => '1');

   attribute async_reg : string;
   attribute async_reg of vga_meta : signal is "true";
   attribute async_reg of vga_sync : signal is "true";

begin

   p_toggle : process (main_clk_i)
   begin
      if rising_edge(main_clk_i) then
         if main_valid_i = '1' then
            main_toggle_r <= not main_toggle_r;
         end if;
      end if;
   end process p_toggle;

   p_cdc : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         vga_meta   <= main_toggle_r;
         vga_sync   <= vga_meta;
         vga_sync_d <= vga_sync;

         if vga_sync /= vga_sync_d then
            vga_digits_r <= main_digits_i;
            vga_blank_r  <= main_blank_i;
         end if;
      end if;
   end process p_cdc;

   vga_digits_o <= vga_digits_r;
   vga_blank_o  <= vga_blank_r;

end architecture rtl;
