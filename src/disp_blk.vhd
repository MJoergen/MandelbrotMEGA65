-- This is one block of the display memory (see disp_mem.vhd): 4096 pixels of 9
-- bits in a single BRAM, with asymmetric ports. The write port writes a word
-- of G_PIXELS pixels (9*G_PIXELS bits, i.e. with the parity bits), with the
-- first pixel in the lowest 9 bits, and the read port reads a single pixel, so
-- the BRAM selects the pixel in the word itself. The two ports have separate
-- clocks. The read data is registered in the BRAM, and only changes when the
-- read enable is high.
--
-- Vivado infers the BRAM from the asymmetric RAM template in UG901 (a shared
-- variable, written in a loop over the pixels of the word, with the address of
-- the word followed by the position in the word). It does not infer it when
-- the shared variable is declared in a generate statement, so each block is a
-- separate entity. The memory is cleared when the FPGA is configured.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.util_pkg.all;

entity disp_blk is
   generic (
      G_PIXELS : positive     -- Pixels in each word, a power of two
   );
   port (
      wr_clk_i  : in  std_logic;
      wr_en_i   : in  std_logic;
      wr_addr_i : in  std_logic_vector(11 - log2(G_PIXELS) downto 0);  -- Word
      wr_data_i : in  std_logic_vector(9*G_PIXELS-1 downto 0);
      --
      rd_clk_i  : in  std_logic;
      rd_en_i   : in  std_logic;
      rd_addr_i : in  std_logic_vector(11 downto 0);                   -- Pixel
      rd_data_o : out std_logic_vector( 8 downto 0)
   );
end entity disp_blk;

architecture rtl of disp_blk is

   constant C_SUB_BITS : natural := log2(G_PIXELS);

   type mem_t is array (0 to 4095) of std_logic_vector(8 downto 0);
   shared variable mem_v : mem_t := (others => (others => '0'));

   signal rd_data : std_logic_vector(8 downto 0);

begin

   p_write : process (wr_clk_i)
   begin
      if rising_edge(wr_clk_i) then
         if wr_en_i = '1' then
            for i in 0 to G_PIXELS-1 loop
               mem_v(to_integer(unsigned(wr_addr_i) & to_unsigned(i, C_SUB_BITS))) :=
                  wr_data_i(9*i+8 downto 9*i);
            end loop;
         end if;
      end if;
   end process p_write;

   p_read : process (rd_clk_i)
   begin
      if rising_edge(rd_clk_i) then
         if rd_en_i = '1' then
            rd_data <= mem_v(to_integer(unsigned(rd_addr_i)));
         end if;
      end if;
   end process p_read;

   rd_data_o <= rd_data;

end architecture rtl;
