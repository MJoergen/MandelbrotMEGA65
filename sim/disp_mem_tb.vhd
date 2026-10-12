-- This is a small self-checking testbench for the display memory. It writes
-- to a few words in each of the blocks (BRAMs) of 2^12 pixels, and reads all
-- their pixels back on the read port, which has a different clock. It
-- checks:
-- * The value read is the value written, i.e. each write goes to the right
--   block and to the right address in the block, and each pixel is in the
--   right position in the word.
-- * Back-to-back writes work, both to different blocks and to the same block.
-- * A second write to the same address overwrites the first value.
-- * Nothing is written when wr_en_i is low.
-- * The read port has a latency of exactly four clock cycles, also for
--   back-to-back reads from different blocks.
-- * In each clock cycle of the read port, only the block of the read address
--   is read, i.e. only its read enable is high, to save power, and no block
--   for an address beyond the last block.
-- * Writes to addresses outside the memory (when it has fewer blocks than the
--   address allows) are ignored, i.e. they do not change any pixel.
-- * A word that is never written reads as 0 in every block, i.e. the memory
--   starts cleared (it has no reset).
--
-- This is done for these configurations, each with its own instance:
-- * 128 blocks (2^19 pixels, as on the Nexys 4 DDR), with one and four pixels
--   in each word, and a register for each block.
-- * 320 blocks with 21 bits of address (as on the MEGA65), with four
--   pixels in each word, and no register for each block.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity disp_mem_tb is
end entity disp_mem_tb;

architecture simulation of disp_mem_tb is

   type int_vector is array (natural range <>) of natural;

   type config_t is record
      pixels    : positive;   -- Pixels in each word
      blocks    : positive;   -- Blocks (BRAMs) in the memory
      addr_bits : positive;   -- Bits of the address
      blk_regs  : boolean;    -- A register for each block
   end record config_t;
   type config_vector is array (natural range <>) of config_t;

   constant C_CONFIGS : config_vector := (
      (pixels => 1, blocks => 128, addr_bits => 19, blk_regs => true),
      (pixels => 4, blocks => 128, addr_bits => 19, blk_regs => true),
      (pixels => 4, blocks => 320, addr_bits => 21, blk_regs => false));

   signal wr_clk   : std_logic;
   signal rd_clk   : std_logic;
   signal finished : std_logic_vector(C_CONFIGS'range) := (others => '0');

   -- The value written to each pixel. It is different for each block, also
   -- at the same offset.
   function value (addr : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((addr*37 + (addr/2**12)*101 + 11) mod 512, 9));
   end function value;

   -- Checks the read enables of the memory of the configuration n in every
   -- clock cycle of the read port. The read enables between two rising edges
   -- belong to the read address at the first of them: the block of the
   -- address is read at the second edge. Addresses beyond the last block read
   -- no block.
   procedure check_read_en (
      n                : natural;
      signal rd_addr   : in std_logic_vector;
      signal rd_blk_en : in std_logic_vector
   ) is
      variable blk_v : natural := 0;    -- The block of the previous address
      variable exp_v : std_logic_vector(rd_blk_en'range);
   begin
      -- The bounds of the external names are written as numbers, see below
      assert rd_addr'length = C_CONFIGS(n).addr_bits and
             rd_blk_en'length = C_CONFIGS(n).blocks
         report "The external names of configuration " & integer'image(n) &
                " do not match C_CONFIGS"
         severity failure;

      loop
         wait until rising_edge(rd_clk);
         exp_v := (others => '0');
         if blk_v <= exp_v'high then
            exp_v(blk_v) := '1';
         end if;
         assert rd_blk_en = exp_v
            report "Wrong read enables for block " & integer'image(blk_v) &
                   " with " & integer'image(rd_blk_en'length) & " blocks"
            severity error;
         blk_v := to_integer(unsigned(rd_addr)) / 2**12;
      end loop;
   end procedure check_read_en;

begin

   ---------------------
   -- Generate clocks
   ---------------------

   p_wr_clk : process
   begin
      wr_clk <= '0', '1' after 3.5 ns;
      wait for 7 ns;
   end process p_wr_clk;

   p_rd_clk : process
   begin
      rd_clk <= '0', '1' after 20 ns;
      wait for 40 ns;
   end process p_rd_clk;

   p_finish : process
   begin
      wait until finished = (finished'range => '1');
      report "disp_mem_tb: finished";
      std.env.finish;
   end process p_finish;


   gen_dut : for n in C_CONFIGS'range generate
      constant C_PIX        : natural := C_CONFIGS(n).pixels;
      constant C_NUM_BLOCKS : natural := C_CONFIGS(n).blocks;
      constant C_ADDR_BITS  : natural := C_CONFIGS(n).addr_bits;
      constant C_BLK_REGS   : boolean := C_CONFIGS(n).blk_regs;
      -- The read latency
      constant C_LAT        : positive := 4;
      -- Words in each block
      constant C_WORDS      : natural := 2**12 / C_PIX;
      -- Word offsets in each block. The word at C_WORDS/2 is never written.
      constant C_OFFSETS    : int_vector := (0, 1, C_WORDS/3, 2*C_WORDS/3, C_WORDS-2, C_WORDS-1);
      constant C_NUM_ADDR   : natural := C_NUM_BLOCKS * C_OFFSETS'length;
      -- The blocks outside the memory that the address allows
      constant C_OUTSIDE    : natural := 2**(C_ADDR_BITS-12) - C_NUM_BLOCKS;

      signal wr_addr    : std_logic_vector(C_ADDR_BITS-1 downto 0) := (others => '0');
      signal wr_data    : std_logic_vector(9*C_PIX-1 downto 0) := (others => '0');
      signal wr_en      : std_logic := '0';
      signal rd_addr    : std_logic_vector(C_ADDR_BITS-1 downto 0) := (others => '0');
      signal rd_data    : std_logic_vector( 8 downto 0);
      signal write_done : boolean := false;

      -- The pixel address of the first pixel of the word used in the test
      -- number i. In the first order, consecutive words are in different
      -- blocks, and in the second order they are in the same block.
      function addr_block_first (i : natural) return natural is
      begin
         return (i mod C_NUM_BLOCKS) * 2**12 + C_OFFSETS(i / C_NUM_BLOCKS) * C_PIX;
      end function addr_block_first;

      function addr_offset_first (i : natural) return natural is
      begin
         return (i / C_OFFSETS'length) * 2**12 + C_OFFSETS(i mod C_OFFSETS'length) * C_PIX;
      end function addr_offset_first;

      -- The values of the pixels of the word starting at addr
      function word (addr : natural) return std_logic_vector is
         variable res_v : std_logic_vector(9*C_PIX-1 downto 0);
      begin
         for i in 0 to C_PIX-1 loop
            res_v(9*i+8 downto 9*i) := value(addr+i);
         end loop;
         return res_v;
      end function word;

   begin

      ----------------------------
      -- Write to the memory
      ----------------------------

      p_write : process

         procedure write (
            addr : natural;
            data : std_logic_vector(9*C_PIX-1 downto 0);
            en   : std_logic
         ) is
         begin
            wait until rising_edge(wr_clk);
            wr_addr <= std_logic_vector(to_unsigned(addr, C_ADDR_BITS));
            wr_data <= data;
            wr_en   <= en;
         end procedure write;

      begin
         wait for 100 ns;

         -- A wrong value, to be overwritten. Consecutive writes in the same
         -- block.
         for i in 0 to C_NUM_ADDR-1 loop
            write(addr_offset_first(i), not word(addr_offset_first(i)), '1');
         end loop;

         -- The right value. Consecutive writes in different blocks.
         for i in 0 to C_NUM_ADDR-1 loop
            write(addr_block_first(i), word(addr_block_first(i)), '1');
         end loop;

         -- A wrong value, but not written.
         for i in 0 to C_NUM_ADDR-1 loop
            write(addr_block_first(i), not word(addr_block_first(i)), '0');
         end loop;

         -- A wrong value, written outside the memory, at the same offsets in
         -- the blocks beyond the last block.
         if C_OUTSIDE > 0 then
            for i in 0 to C_NUM_ADDR-1 loop
               write(addr_block_first(i) + (C_NUM_BLOCKS - i mod C_NUM_BLOCKS +
                                            i mod C_OUTSIDE) * 2**12,
                     not word(addr_block_first(i)), '1');
            end loop;
         end if;

         wait until rising_edge(wr_clk);
         wr_en <= '0';

         -- Wait for the write latency
         for t in 1 to 5 loop
            wait until rising_edge(wr_clk);
         end loop;
         write_done <= true;
         wait;
      end process p_write;


      ----------------------------
      -- Read from the memory
      ----------------------------

      -- An address is given in each clock cycle, and the value is checked
      -- C_LAT clock cycles later. All the pixels of each word are read. First
      -- a pixel of the word that is never written is read in each block.
      p_read : process
         variable exp_addr_v : natural;
         variable addr_v     : natural;
      begin
         wait until write_done;

         for i in 0 to C_NUM_BLOCKS+C_LAT-1 loop
            wait until rising_edge(rd_clk);
            wait for 1 ns;
            if i >= C_LAT then
               assert rd_data = "000000000"
                  report "Wrong value of a word never written in block " & integer'image(i-C_LAT) &
                         ": got " & integer'image(to_integer(unsigned(rd_data)))
                  severity error;
            end if;
            if i < C_NUM_BLOCKS then
               addr_v := i * 2**12 + (C_WORDS/2) * C_PIX + i mod C_PIX;
               rd_addr <= std_logic_vector(to_unsigned(addr_v, C_ADDR_BITS));
            end if;
         end loop;

         for i in 0 to C_NUM_ADDR*C_PIX+C_LAT-1 loop
            wait until rising_edge(rd_clk);
            wait for 1 ns;
            if i >= C_LAT then
               exp_addr_v := addr_block_first((i-C_LAT) / C_PIX) + (i-C_LAT) mod C_PIX;
               assert rd_data = value(exp_addr_v)
                  report "Wrong value read at address " & integer'image(exp_addr_v) &
                         " with " & integer'image(C_PIX) & " pixels in each word: got " &
                         integer'image(to_integer(unsigned(rd_data))) &
                         ", expected " & integer'image(to_integer(unsigned(value(exp_addr_v))))
                  severity error;
            end if;
            if i < C_NUM_ADDR*C_PIX then
               rd_addr <= std_logic_vector(to_unsigned(addr_block_first(i / C_PIX) + i mod C_PIX, C_ADDR_BITS));
            end if;
         end loop;

         -- An address beyond the last block, which reads no block (checked by
         -- p_read_en). Its value is not used.
         if C_OUTSIDE > 0 then
            rd_addr <= std_logic_vector(to_unsigned(C_NUM_BLOCKS * 2**12, C_ADDR_BITS));
            for t in 1 to 2 loop
               wait until rising_edge(rd_clk);
            end loop;
         end if;

         finished(n) <= '1';
         wait;
      end process p_read;


      -------------------
      -- Instantiate DUT
      -------------------

      i_disp_mem : entity work.disp_mem
         generic map (
            G_ADDR_BITS  => C_ADDR_BITS,
            G_NUM_BLOCKS => C_NUM_BLOCKS,
            G_BLOCK_REGS => C_BLK_REGS,
            G_PIXELS     => C_PIX
         )
         port map (
            wr_clk_i  => wr_clk,
            wr_addr_i => wr_addr,
            wr_data_i => wr_data,
            wr_en_i   => wr_en,
            rd_clk_i  => rd_clk,
            rd_addr_i => rd_addr,
            rd_data_o => rd_data
         ); -- i_disp_mem

   end generate gen_dut;


   -------------------------------------
   -- Only the block of the pixel is read
   -------------------------------------

   -- The read enables (one for each block) are inside the memory, so they
   -- are read with external names, which must come after the instantiation
   -- of the memory. Each configuration has its own process, with an absolute
   -- name (with the index of the generate statement), and the bounds written
   -- as numbers. GHDL 4.1 (the version in Ubuntu 24.04) crashes on an
   -- external name inside the generate statement, or reads the wrong signal,
   -- and it gets the bounds wrong when they are calculated from C_CONFIGS.
   -- check_read_en checks that the numbers match C_CONFIGS.
   assert C_CONFIGS'length = 3
      report "Each configuration needs a process p_read_en_<n> below"
      severity failure;

   p_read_en_0 : process
      alias rd_addr   is << signal .disp_mem_tb.gen_dut(0).rd_addr :
                           std_logic_vector(18 downto 0) >>;
      alias rd_blk_en is << signal .disp_mem_tb.gen_dut(0).i_disp_mem.rd_blk_en :
                           std_logic_vector(127 downto 0) >>;
   begin
      check_read_en(0, rd_addr, rd_blk_en);
   end process p_read_en_0;

   p_read_en_1 : process
      alias rd_addr   is << signal .disp_mem_tb.gen_dut(1).rd_addr :
                           std_logic_vector(18 downto 0) >>;
      alias rd_blk_en is << signal .disp_mem_tb.gen_dut(1).i_disp_mem.rd_blk_en :
                           std_logic_vector(127 downto 0) >>;
   begin
      check_read_en(1, rd_addr, rd_blk_en);
   end process p_read_en_1;

   p_read_en_2 : process
      alias rd_addr   is << signal .disp_mem_tb.gen_dut(2).rd_addr :
                           std_logic_vector(20 downto 0) >>;
      alias rd_blk_en is << signal .disp_mem_tb.gen_dut(2).i_disp_mem.rd_blk_en :
                           std_logic_vector(319 downto 0) >>;
   begin
      check_read_en(2, rd_addr, rd_blk_en);
   end process p_read_en_2;

end architecture simulation;
