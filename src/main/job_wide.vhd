-- This is a job module, with numbers in 2.33 fixed point format (35 bits). It
-- calculates (sequentially) G_NUM_ROWS rows of a picture column, using one
-- wide iterator (iterator_wide.vhd), which calculates four rows at the same
-- time.
--
-- Each result is the values of the four rows calculated together by the
-- iterator (a word of the display memory), so G_PIXELS must be 4. The row
-- number given with each result (res_addr_o) is that of the first row of the
-- result, counted from the first row of the job, and the first row is in the
-- lowest 9 bits of res_data_o. G_NUM_ROWS must be a multiple of 4. The job
-- module starts the iterator with the next four rows when the result has been
-- acknowledged.
--
-- The display memory has 9 bits for each pixel, but the count has more bits
-- when G_MAX_COUNT is larger than 511. So the value of a pixel is 511 for the
-- points in the set (the count is G_MAX_COUNT), and otherwise the count
-- modulo 511, i.e. 0 to 510. The colour palettes (palette_pkg.vhd) have 512
-- entries, and the palette offset is also calculated modulo 511, so the
-- colours of the counts 0 to 510 repeat for the larger counts. With the
-- maximum count 1023 the count is reduced by subtracting 511 at most twice.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.util_pkg.all;
use work.dispatcher_pkg.all;

entity job_wide is
   generic (
      G_MAX_COUNT : positive;
      G_NUM_ROWS  : positive;
      G_PIXELS    : positive := 4   -- Rows in each result
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      job_start_i  : in  std_logic;
      job_cx_i     : in  std_logic_vector(34 downto 0);
      job_starty_i : in  std_logic_vector(34 downto 0);
      job_stepy_i  : in  std_logic_vector(34 downto 0);
      job_busy_o   : out std_logic;
      res_addr_o   : out std_logic_vector( 8 downto 0);
      res_ack_i    : in  std_logic;
      res_data_o   : out std_logic_vector(9*G_PIXELS-1 downto 0);
      res_valid_o  : out std_logic
   );
end entity job_wide;

architecture rtl of job_wide is

   -- The number of bits of the row number, and of a count
   constant C_ADDR_BITS : natural := maximum(log2(G_NUM_ROWS), 1);
   constant C_CNT_BITS  : natural := log2(G_MAX_COUNT+1);

   -- The value of a pixel in the display memory, for the count cnt: 511 for
   -- the points in the set, and otherwise the count modulo 511
   function to_pixel (cnt : std_logic_vector) return std_logic_vector is
      variable cnt_v : std_logic_vector(cnt'length-1 downto 0) := cnt;
   begin
      if cnt = G_MAX_COUNT then
         return "111111111";
      end if;
      for i in 1 to G_MAX_COUNT / 511 loop
         if cnt_v >= 511 then
            cnt_v := cnt_v - 511;
         end if;
      end loop;
      return resize(cnt_v, 9);
   end function to_pixel;

   -- The reset, registered locally, so the reset from the dispatcher only goes
   -- to this register.
   signal rst_r        : std_logic;

   signal res_start_r  : std_logic;
   signal res_cx_r     : std_logic_vector(34 downto 0);
   signal res_cy_r     : std_logic_vector(34 downto 0);
   signal res_cnt_s    : std_logic_vector(4*C_CNT_BITS-1 downto 0);
   signal res_valid_s  : std_logic;
   -- The first row of the result
   signal res_addr_r   : std_logic_vector(C_ADDR_BITS-1 downto 0);
   -- High when res_addr_r is the last result. It is a register, so the check
   -- for the last result is not in the paths to res_addr_r and res_cy_r.
   signal res_last_r   : std_logic;

   signal job_busy_r   : std_logic;

   signal res_addr_d   : std_logic_vector(C_ADDR_BITS-1 downto 0);
   signal res_data_d   : std_logic_vector(9*G_PIXELS-1 downto 0);
   signal res_valid_d  : std_logic;

begin

   assert G_PIXELS = 4 and G_NUM_ROWS mod G_PIXELS = 0
      report "G_PIXELS must be 4, and divide G_NUM_ROWS"
      severity failure;

   p_rst : process (clk_i)
   begin
      if rising_edge(clk_i) then
         rst_r <= rst_i;
      end if;
   end process p_rst;


   -----------------------------
   -- Simple state machine to
   -- iterate through the rows,
   -- four at a time.
   -----------------------------

   -- The iterator keeps the counts, and done_o high, until the next start. It
   -- sees the start in the clock cycle after res_start_r is set, so the counts
   -- are only used when res_start_r is low. The iterator calculates the rows
   -- with cy = res_cy_r + k*stepy, for k = 0 to 3, so the first row of the
   -- next result has cy = res_cy_r + 4*stepy. This gives exactly the same
   -- values as adding stepy for each row (in 35 bits).
   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         res_start_r <= '0';

         if job_start_i = '1' then
            res_cx_r    <= job_cx_i;
            res_cy_r    <= job_starty_i;
            res_start_r <= '1';
            res_addr_r  <= (others => '0');
            res_last_r  <= '0';
            if G_NUM_ROWS = G_PIXELS then
               res_last_r <= '1';
            end if;
         end if;

         -- The next rows start when the result has been acknowledged
         if res_valid_s = '1' and res_ack_i = '1' and
            res_start_r = '0' and res_last_r = '0'
         then
            res_addr_r  <= res_addr_r + G_PIXELS;
            res_cy_r    <= res_cy_r + (job_stepy_i(32 downto 0) & "00");
            res_start_r <= '1';
            res_last_r  <= '0';
            if to_integer(res_addr_r) = G_NUM_ROWS-2*G_PIXELS then
               res_last_r <= '1';
            end if;
         end if;
      end if;
   end process p_fsm;


   p_job_done : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if res_valid_s = '1' and res_last_r = '1' and
            res_start_r = '0' and res_ack_i = '1'
         then
            job_busy_r <= '0';
         end if;

         if job_start_i = '1' then
            job_busy_r  <= '1';
         end if;

         if rst_r = '1' then
            job_busy_r  <= '0';
         end if;
      end if;
   end process p_job_done;


   i_iterator : entity work.iterator_wide
      generic map (
         G_MAX_COUNT => G_MAX_COUNT
      )
      port map (
         clk_i   => clk_i,
         rst_i   => rst_r,
         start_i => res_start_r,
         cx_i    => res_cx_r,
         cy_i    => res_cy_r,
         stepy_i => job_stepy_i,
         cnt_o   => res_cnt_s,
         done_o  => res_valid_s
      ); -- i_iterator


   ---------------------------
   -- Pipeline output signals
   ---------------------------

   -- The counts are converted to the values of the pixels here
   p_out : process (clk_i)
   begin
      if rising_edge(clk_i) then
         res_addr_d  <= res_addr_r;
         for k in 0 to G_PIXELS-1 loop
            res_data_d(9*k+8 downto 9*k) <=
               to_pixel(res_cnt_s(C_CNT_BITS*k+C_CNT_BITS-1 downto C_CNT_BITS*k));
         end loop;
         res_valid_d <= res_valid_s and not res_start_r and job_busy_r and
                        not res_ack_i;
      end if;
   end process p_out;


   --------------------------
   -- Connect output signals
   --------------------------

   job_busy_o  <= job_busy_r;

   res_addr_o  <= (8 downto C_ADDR_BITS => '0') & res_addr_d;
   res_data_o  <= res_data_d;
   res_valid_o <= res_valid_d;

end architecture rtl;
