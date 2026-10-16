-- This module instantiates a number of job modules, dispatches jobs to them,
-- and collects results from them.
--
-- The picture is divided into blocks of G_COLS_IN_JOB columns, and each job is
-- one picture row of a block. The jobs are given out one picture row at a
-- time: First all the blocks of the top row, from left to right, then all the
-- blocks of the next row, and so on. Smaller jobs make the work more evenly shared
-- between the job modules at the end of the picture, when the expensive
-- jobs would otherwise keep a few job modules busy long after the others
-- have finished.
--
-- Each write to the display memory is G_PIXELS pixels: consecutive columns of
-- a picture row, starting at the column given by wr_addr_o, with the first
-- column in the lowest 9 bits of wr_data_o (see job_wide.vhd). Writing more
-- than one pixel at a time lets the dispatcher write more than one pixel per
-- clock cycle.
--
-- The address of the pixel in column x and row y of the picture is
-- y*G_ROW_STRIDE + x, with G_ADDR_BITS bits. When G_ROW_STRIDE is a power of
-- two, this is the row followed by the column, e.g. 1024 for 640x480 (19
-- bits). Otherwise G_ROW_STRIDE can be the number of columns, so that the
-- picture takes fewer addresses, e.g. 1280 for 1280x1024 (21 bits).
--
-- The dispatcher has two parts: dispatcher_jobs.vhd gives out the jobs, and
-- finds out when the picture is done, and dispatcher_results.vhd collects the
-- results and writes them to the display memory.
--
-- The values (the position of the picture and the size of a pixel) are in
-- 2.33 fixed point format (35 bits). The job modules are job_wide.vhd, with
-- iterator_wide.vhd, which needs G_PIXELS = 4.

library ieee;
use ieee.std_logic_1164.all;

use work.dispatcher_pkg.all;
use work.util_pkg.all;

entity dispatcher is
   generic (
      G_MAX_COUNT     : positive;
      G_NUM_ROWS      : positive;
      G_NUM_COLS      : positive;
      G_ROW_STRIDE    : positive;         -- Address distance between rows
      G_ADDR_BITS     : positive;         -- Bits of the address
      G_COLS_IN_JOB   : positive;         -- Columns in each job
      G_NUM_ITERATORS : positive;
      G_GROUP_SIZE    : positive := 16;
      G_PIXELS        : positive          -- Pixels in each write
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;
      start_i   : in  std_logic;
      startx_i  : in  std_logic_vector(34 downto 0);
      starty_i  : in  std_logic_vector(34 downto 0);
      stepx_i   : in  std_logic_vector(34 downto 0);
      stepy_i   : in  std_logic_vector(34 downto 0);
      wr_addr_o : out std_logic_vector(G_ADDR_BITS-1 downto 0);
      wr_data_o : out std_logic_vector(9*G_PIXELS-1 downto 0);
      wr_en_o   : out std_logic;
      done_o    : out std_logic
   );
end entity dispatcher;

architecture rtl of dispatcher is

   constant C_NUM_GROUPS : natural := (G_NUM_ITERATORS + G_GROUP_SIZE - 1) / G_GROUP_SIZE;

   signal sched_active_s : std_logic;

   -- The index of the job module, the picture row, and the block of each job
   signal tbl_valid_s    : std_logic;
   signal tbl_idx_s      : natural range 0 to G_NUM_ITERATORS-1;
   signal tbl_row_s      : std_logic_vector(maximum(1, log2(G_NUM_ROWS))-1 downto 0);
   signal tbl_blk_s      : natural range 0 to G_NUM_COLS/G_COLS_IN_JOB-1;

   -- To and from the job modules. The reset and the job are one for each
   -- group of G_GROUP_SIZE job modules.
   signal job_rst_s      : std_logic_vector(C_NUM_GROUPS-1 downto 0);
   signal job_startx_s   : value_vector(C_NUM_GROUPS-1 downto 0)(34 downto 0);
   signal job_cy_s       : value_vector(C_NUM_GROUPS-1 downto 0)(34 downto 0);
   signal job_stepx_s    : value_vector(C_NUM_GROUPS-1 downto 0)(34 downto 0);
   signal job_start_s    : std_logic_vector(G_NUM_ITERATORS-1 downto 0);
   signal job_busy_s     : std_logic_vector(G_NUM_ITERATORS-1 downto 0);
   signal res_addr_s     : res_addr_vector(G_NUM_ITERATORS-1 downto 0);
   signal res_data_s     : std_logic_vector(G_NUM_ITERATORS*9*G_PIXELS-1 downto 0);
   signal res_valid_s    : std_logic_vector(G_NUM_ITERATORS-1 downto 0);
   signal res_ack_s      : std_logic_vector(G_NUM_ITERATORS-1 downto 0);

begin

   ----------------------
   -- Give out the jobs
   ----------------------

   i_dispatcher_jobs : entity work.dispatcher_jobs
      generic map (
         G_NUM_ROWS      => G_NUM_ROWS,
         G_NUM_COLS      => G_NUM_COLS,
         G_COLS_IN_JOB   => G_COLS_IN_JOB,
         G_NUM_ITERATORS => G_NUM_ITERATORS,
         G_GROUP_SIZE    => G_GROUP_SIZE
      )
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         start_i        => start_i,
         startx_i       => startx_i,
         starty_i       => starty_i,
         stepx_i        => stepx_i,
         stepy_i        => stepy_i,
         sched_active_o => sched_active_s,
         done_o         => done_o,
         job_rst_o      => job_rst_s,
         job_startx_o   => job_startx_s,
         job_cy_o       => job_cy_s,
         job_stepx_o    => job_stepx_s,
         job_start_o    => job_start_s,
         job_busy_i     => job_busy_s,
         tbl_valid_o    => tbl_valid_s,
         tbl_idx_o      => tbl_idx_s,
         tbl_row_o      => tbl_row_s,
         tbl_blk_o      => tbl_blk_s
      ); -- i_dispatcher_jobs


   ------------------------------
   -- Instantiate job modules
   ------------------------------

   gen_job : for i in 0 to G_NUM_ITERATORS-1 generate
      i_job : entity work.job_wide
         generic map (
            G_MAX_COUNT => G_MAX_COUNT,
            G_NUM_COLS  => G_COLS_IN_JOB,
            G_PIXELS    => G_PIXELS
         )
         port map (
            clk_i        => clk_i,
            rst_i        => job_rst_s(i / G_GROUP_SIZE),
            job_start_i  => job_start_s(i),
            job_startx_i => job_startx_s(i / G_GROUP_SIZE),
            job_cy_i     => job_cy_s(i / G_GROUP_SIZE),
            job_stepx_i  => job_stepx_s(i / G_GROUP_SIZE),
            job_busy_o   => job_busy_s(i),
            res_addr_o   => res_addr_s(i),
            res_data_o   => res_data_s((i+1)*9*G_PIXELS-1 downto i*9*G_PIXELS),
            res_valid_o  => res_valid_s(i),
            res_ack_i    => res_ack_s(i)
         ); -- i_job
   end generate gen_job;


   ----------------------------------------
   -- Collect the results and write them
   ----------------------------------------

   i_dispatcher_results : entity work.dispatcher_results
      generic map (
         G_NUM_ROWS      => G_NUM_ROWS,
         G_NUM_COLS      => G_NUM_COLS,
         G_ROW_STRIDE    => G_ROW_STRIDE,
         G_ADDR_BITS     => G_ADDR_BITS,
         G_COLS_IN_JOB   => G_COLS_IN_JOB,
         G_NUM_ITERATORS => G_NUM_ITERATORS,
         G_GROUP_SIZE    => G_GROUP_SIZE,
         G_PIXELS        => G_PIXELS
      )
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         sched_active_i => sched_active_s,
         tbl_valid_i    => tbl_valid_s,
         tbl_idx_i      => tbl_idx_s,
         tbl_row_i      => tbl_row_s,
         tbl_blk_i      => tbl_blk_s,
         res_addr_i     => res_addr_s,
         res_data_i     => res_data_s,
         res_valid_i    => res_valid_s,
         res_ack_o      => res_ack_s,
         wr_addr_o      => wr_addr_o,
         wr_data_o      => wr_data_o,
         wr_en_o        => wr_en_o
      ); -- i_dispatcher_results

end architecture rtl;
