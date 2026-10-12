-- This module moves a value (s_data_i) from one clock domain (the source,
-- s_clk_i) to another (the destination, m_clk_i), for a value that changes
-- seldom: it must be constant for much longer than the synchronizer takes
-- (a few clock cycles of the destination clock) after each change.
--
-- The source sets s_valid_i for one clock cycle each time it changes the
-- value, and then a toggle signal is changed (p_toggle). The toggle signal
-- is synchronized to the destination clock with two registers (p_cdc), and
-- when it changes, the value is copied to m_data_o. Because the value is
-- constant by then, it is never copied while it changes, so all its bits
-- are copied together. Until the first value is copied, m_data_o is
-- G_INIT.
--
-- The paths from the source clock to the destination clock (the value and
-- the toggle signal) need a constraint in the constraint file
-- (set_max_delay -datapath_only), so that the value arrives before the
-- toggle signal, and these paths are left out of the normal timing between
-- the two clocks.
--
-- The design uses it to move the frame rate and the view from the MAIN clock
-- domain (main.vhd) to the VGA clock domain (overlay.vhd), see mega65.vhd and
-- nexys4ddr.vhd.

library ieee;
use ieee.std_logic_1164.all;

entity cdc_data is
   generic (
      G_DATA_SIZE : positive;
      G_INIT      : std_logic_vector    -- Of G_DATA_SIZE bits
   );
   port (
      -- The source clock domain
      s_clk_i   : in  std_logic;
      s_data_i  : in  std_logic_vector(G_DATA_SIZE-1 downto 0);
      s_valid_i : in  std_logic;

      -- The destination clock domain
      m_clk_i   : in  std_logic;
      m_data_o  : out std_logic_vector(G_DATA_SIZE-1 downto 0)
   );
end entity cdc_data;

architecture rtl of cdc_data is

   -- Changed each time the value changes
   signal s_toggle_r : std_logic := '0';

   -- The toggle signal in the destination clock domain, and the value
   signal m_meta     : std_logic := '0';
   signal m_sync     : std_logic := '0';
   signal m_sync_d   : std_logic := '0';
   signal m_data_r   : std_logic_vector(G_DATA_SIZE-1 downto 0) := G_INIT;

   attribute async_reg : string;
   attribute async_reg of m_meta : signal is "true";
   attribute async_reg of m_sync : signal is "true";

begin

   assert G_INIT'length = G_DATA_SIZE
      report "G_INIT must have G_DATA_SIZE bits"
      severity failure;

   p_toggle : process (s_clk_i)
   begin
      if rising_edge(s_clk_i) then
         if s_valid_i = '1' then
            s_toggle_r <= not s_toggle_r;
         end if;
      end if;
   end process p_toggle;

   p_cdc : process (m_clk_i)
   begin
      if rising_edge(m_clk_i) then
         m_meta   <= s_toggle_r;
         m_sync   <= m_meta;
         m_sync_d <= m_sync;

         if m_sync /= m_sync_d then
            m_data_r <= s_data_i;
         end if;
      end if;
   end process p_cdc;

   m_data_o <= m_data_r;

end architecture rtl;
