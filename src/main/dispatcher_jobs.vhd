-- This module is the part of the dispatcher (see dispatcher.vhd) that gives
-- out the jobs to the job modules, and finds out when the picture is done.
--
-- The jobs are given out one picture row at a time: First all the blocks of
-- the top row, from left to right, then all the blocks of the next row, and
-- so on. Each job goes to all the job modules (job_startx_o, job_cy_o, and
-- job_stepx_o, one register for each group of G_GROUP_SIZE job modules), and
-- the job module selected by i_job_scheduler takes it (job_start_o).
--
-- For each job, the index of the job module, the picture row, and the block
-- are given to dispatcher_results.vhd (tbl_*_o), so the address of the
-- results can be calculated.
--
-- The values (cx, cy, and the steps) are in 2.33 fixed point format, i.e. 35
-- bits, see dispatcher.vhd.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

use work.dispatcher_pkg.all;
use work.util_pkg.all;

entity dispatcher_jobs is
   generic (
      G_NUM_ROWS      : positive;
      G_NUM_COLS      : positive;
      G_COLS_IN_JOB   : positive;         -- Columns in each job
      G_NUM_ITERATORS : positive;
      G_GROUP_SIZE    : positive
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;
      start_i        : in  std_logic;
      startx_i       : in  std_logic_vector(34 downto 0);
      starty_i       : in  std_logic_vector(34 downto 0);
      stepx_i        : in  std_logic_vector(34 downto 0);
      stepy_i        : in  std_logic_vector(34 downto 0);
      -- High while the picture is being calculated
      sched_active_o : out std_logic;
      done_o         : out std_logic;

      -- To and from the job modules. All but job_busy_i are one for each
      -- group of G_GROUP_SIZE job modules.
      job_rst_o      : out std_logic_vector((G_NUM_ITERATORS+G_GROUP_SIZE-1)/G_GROUP_SIZE-1 downto 0);
      job_startx_o   : out value_vector((G_NUM_ITERATORS+G_GROUP_SIZE-1)/G_GROUP_SIZE-1 downto 0)
                                      (34 downto 0);
      job_cy_o       : out value_vector((G_NUM_ITERATORS+G_GROUP_SIZE-1)/G_GROUP_SIZE-1 downto 0)
                                      (34 downto 0);
      job_stepx_o    : out value_vector((G_NUM_ITERATORS+G_GROUP_SIZE-1)/G_GROUP_SIZE-1 downto 0)
                                      (34 downto 0);
      job_start_o    : out std_logic_vector(G_NUM_ITERATORS-1 downto 0);
      job_busy_i     : in  std_logic_vector(G_NUM_ITERATORS-1 downto 0);

      -- To dispatcher_results: The index of the job module, the picture
      -- row, and the block of each job, when tbl_valid_o is high
      tbl_valid_o    : out std_logic;
      tbl_idx_o      : out natural range 0 to G_NUM_ITERATORS-1;
      tbl_row_o      : out std_logic_vector(maximum(1, log2(G_NUM_ROWS))-1 downto 0);
      tbl_blk_o      : out natural range 0 to G_NUM_COLS/G_COLS_IN_JOB-1
   );
end entity dispatcher_jobs;

architecture rtl of dispatcher_jobs is

   -- The number of bits of the row (at least one, also for a single row),
   -- and of the values
   constant C_ROW_BITS   : natural := maximum(1, log2(G_NUM_ROWS));
   constant C_VALUE_BITS : natural := 35;

   -- The job (startx, cy, and stepx) and the reset go to all the job modules.
   -- To make the routing shorter, they go through an extra register in each
   -- group of G_GROUP_SIZE job modules. The registers in each group are
   -- identical, so the attribute keep prevents the synthesis tool from
   -- merging them.
   constant C_NUM_GROUPS : natural := (G_NUM_ITERATORS + G_GROUP_SIZE - 1) / G_GROUP_SIZE;

   -- The number of blocks of columns
   constant C_NUM_BLOCKS : natural := G_NUM_COLS / G_COLS_IN_JOB;

   signal sched_active_r    : std_logic;
   --
   -- The job: cx of the first column of the block, and cy of the picture row
   signal job_startx_r      : std_logic_vector(C_VALUE_BITS-1 downto 0);
   signal job_cy_r          : std_logic_vector(C_VALUE_BITS-1 downto 0);
   signal job_leftx_r       : std_logic_vector(C_VALUE_BITS-1 downto 0);
   signal job_stepx_r       : std_logic_vector(C_VALUE_BITS-1 downto 0);
   signal job_stepy_r       : std_logic_vector(C_VALUE_BITS-1 downto 0);
   -- The difference in cx between two blocks
   signal job_blk_stepx_r   : std_logic_vector(C_VALUE_BITS-1 downto 0);
   --
   signal job_start_r       : std_logic_vector(G_NUM_ITERATORS-1 downto 0);
   signal job_started_r     : std_logic;
   -- High together with job_started_r, when the job is the last block of a
   -- picture row
   signal job_wrap_r        : std_logic;
   -- The index of the job module, the picture row, and the block of the job,
   -- when job_started_r is high
   signal job_idx_r         : natural range 0 to G_NUM_ITERATORS-1;
   signal job_row_r         : std_logic_vector(C_ROW_BITS-1 downto 0);
   signal job_blk_r         : natural range 0 to C_NUM_BLOCKS-1;
   -- The block and the picture row of the next job. All the jobs have been
   -- given out when cur_row_r is G_NUM_ROWS.
   signal cur_blk_r         : natural range 0 to C_NUM_BLOCKS-1 := 0;
   signal cur_row_r         : natural range 0 to G_NUM_ROWS := 0;
   --
   -- The job, delayed by one clock cycle, in each group of job modules
   signal grp_startx_r      : value_vector(C_NUM_GROUPS-1 downto 0)(C_VALUE_BITS-1 downto 0);
   signal grp_cy_r          : value_vector(C_NUM_GROUPS-1 downto 0)(C_VALUE_BITS-1 downto 0);
   signal grp_stepx_r       : value_vector(C_NUM_GROUPS-1 downto 0)(C_VALUE_BITS-1 downto 0);
   signal job_start_d       : std_logic_vector(G_NUM_ITERATORS-1 downto 0);
   signal job_started_d     : std_logic;
   signal job_started_dd    : std_logic;
   -- High when any job module in the group is busy with a job
   signal grp_job_busy_r    : std_logic_vector(C_NUM_GROUPS-1 downto 0);
   signal grp_rst_r         : std_logic_vector(C_NUM_GROUPS-1 downto 0);

   -- The multiplication by the constant G_COLS_IN_JOB uses LUTs, because all
   -- the DSPs are used by the iterators.
   attribute use_dsp : string;
   attribute use_dsp of job_blk_stepx_r : signal is "no";

   attribute keep : string;
   attribute keep of grp_startx_r : signal is "true";
   attribute keep of grp_cy_r     : signal is "true";
   attribute keep of grp_stepx_r  : signal is "true";
   attribute keep of grp_rst_r    : signal is "true";

   signal done_r            : std_logic;

   signal idx_start_r       : natural range 0 to G_NUM_ITERATORS-1;
   signal idx_start_valid_r : std_logic;

begin

   -- When the scheduler samples the busy flag of a job module and selects
   -- it, the new busy flag of that job module (job_busy_i) is sampled by
   -- the scheduler five clock cycles later at the earliest (the selection goes
   -- through the scheduler, job_start_r, and job_start_d). The scheduler
   -- samples the busy flag of the same job module again G_NUM_ITERATORS
   -- clock cycles later. With fewer than five job modules a job could
   -- therefore be started twice (and the first one would be lost).
   assert G_NUM_ITERATORS >= 5
      report "The dispatcher needs at least five job modules"
      severity failure;

   assert G_NUM_COLS mod G_COLS_IN_JOB = 0
      report "The number of columns must be a multiple of the columns in a job"
      severity failure;

   p_sched_active : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if done_r = '1' then
            sched_active_r <= '0';
         end if;

         if start_i = '1' then
            sched_active_r <= '1';
         end if;

         if rst_i = '1' then
            sched_active_r <= '0';
         end if;
      end if;
   end process p_sched_active;


   -------------------------
   -- Instantiate scheduler
   -------------------------

   i_job_scheduler : entity work.job_scheduler
      generic map (
         G_SIZE       => G_NUM_ITERATORS,
         G_GROUP_SIZE => G_GROUP_SIZE
      )
      port map (
         clk_i           => clk_i,
         rst_i           => rst_i,
         sched_active_i  => sched_active_r,
         job_idx_valid_o => idx_start_valid_r,
         job_idx_start_o => idx_start_r,
         job_busy_i      => job_busy_i
      ); -- i_job_scheduler


   ----------------------------------
   -- Start any idle job module
   ----------------------------------

   p_job_start : process (clk_i)
   begin
      if rising_edge(clk_i) then

         -- Only pulse for one clock cycle. The signal job_started_r is high
         -- when any bit of job_start_r is high.
         job_start_r   <= (others => '0');
         job_started_r <= '0';
         job_wrap_r    <= '0';

         if idx_start_valid_r = '1' and
            cur_row_r < G_NUM_ROWS
         then
            job_start_r(idx_start_r) <= '1';
            job_started_r            <= '1';
            job_idx_r                <= idx_start_r;
            job_row_r                <= to_slv(cur_row_r, C_ROW_BITS);
            job_blk_r                <= cur_blk_r;
            if cur_blk_r = C_NUM_BLOCKS-1 then
               job_wrap_r <= '1';
               cur_blk_r  <= 0;
               cur_row_r  <= cur_row_r + 1;
            else
               cur_blk_r  <= cur_blk_r + 1;
            end if;
         end if;

         if start_i = '1' then
            cur_blk_r <= 0;
            cur_row_r <= 0;
         end if;

         if rst_i = '1' then
            job_start_r   <= (others => '0');
            job_started_r <= '0';
            job_wrap_r    <= '0';
            cur_blk_r     <= 0;
            cur_row_r     <= 0;
         end if;
      end if;
   end process p_job_start;


   ----------------------------------------
   -- Prepare job for next job module
   ----------------------------------------

   -- The next block starts G_COLS_IN_JOB columns to the right. The job
   -- modules add stepx in C_VALUE_BITS bits, so adding G_COLS_IN_JOB times
   -- stepx (also in C_VALUE_BITS bits) gives exactly the same values of cx as
   -- if all the columns were calculated in one job. After the last block of a
   -- picture row, cx starts again from the left edge, and cy moves to the
   -- next row. The value of job_blk_stepx_r is ready two clock cycles after a
   -- start (start_i), and it is not used until the first job has been
   -- started, which is at least five clock cycles after the start.
   p_job_c : process (clk_i)
      variable blk_stepx_v : std_logic_vector(2*C_VALUE_BITS-1 downto 0);
   begin
      if rising_edge(clk_i) then
         blk_stepx_v     := job_stepx_r * to_slv(G_COLS_IN_JOB, C_VALUE_BITS);
         job_blk_stepx_r <= blk_stepx_v(C_VALUE_BITS-1 downto 0);

         if job_started_r = '1' then
            job_startx_r <= job_startx_r + job_blk_stepx_r;
            if job_wrap_r = '1' then
               job_startx_r <= job_leftx_r;
               job_cy_r     <= job_cy_r + job_stepy_r;
            end if;
         end if;

         if start_i = '1' then
            job_startx_r <= startx_i;
            job_leftx_r  <= startx_i;
            job_stepx_r  <= stepx_i;
            job_cy_r     <= starty_i;
            job_stepy_r  <= stepy_i;
         end if;
      end if;
   end process p_job_c;


   -----------------------------------------------
   -- Delay the job by one clock cycle, in groups
   -----------------------------------------------

   -- The job module takes the values of startx and cy when it sees the
   -- start of the job, so job_start_r is delayed too. The value of stepx does
   -- not change during a picture. After a start (start_i), the first job is
   -- started (job_start_d) five clock cycles later, and by then the new value
   -- has reached the job modules.
   p_grp : process (clk_i)
   begin
      if rising_edge(clk_i) then
         for g in 0 to C_NUM_GROUPS-1 loop
            grp_startx_r(g) <= job_startx_r;
            grp_cy_r(g)     <= job_cy_r;
            grp_stepx_r(g)  <= job_stepx_r;
         end loop;

         -- These need no reset, because job_start_r and job_started_r are
         -- reset, and the reset lasts more than one clock cycle.
         job_start_d    <= job_start_r;
         job_started_d  <= job_started_r;
         job_started_dd <= job_started_d;

         -- The job modules are reset two clock cycles after the rest of the
         -- dispatcher (they register the reset again).
         for g in 0 to C_NUM_GROUPS-1 loop
            grp_rst_r(g) <= rst_i;
         end loop;
      end if;
   end process p_grp;


   ------------------------------------------
   -- Find out when the picture is done
   ------------------------------------------

   -- The busy flags of all the job modules are combined in two steps, to
   -- keep the paths short: first in each group (grp_job_busy_r), and then in
   -- p_done.
   gen_grp_job_busy : for g in 0 to C_NUM_GROUPS-1 generate
      p_grp_job_busy : process (clk_i)
      begin
         if rising_edge(clk_i) then
            grp_job_busy_r(g) <= '0';
            for i in g*G_GROUP_SIZE to minimum((g+1)*G_GROUP_SIZE, G_NUM_ITERATORS)-1 loop
               if job_busy_i(i) = '1' then
                  grp_job_busy_r(g) <= '1';
               end if;
            end loop;
         end if;
      end process p_grp_job_busy;
   end generate gen_grp_job_busy;

   -- The signal done_r stays high until the next start. It is cleared by the
   -- start, because otherwise the old value of done_r would stop the scheduler
   -- (see p_sched_active) just after the start. It is not set while a job has
   -- just been started (job_started_r, job_started_d, or job_started_dd),
   -- because then the busy flag of the job module has not reached
   -- grp_job_busy_r yet.
   p_done : process (clk_i)
   begin
      if rising_edge(clk_i) then
         done_r <= '0';
         if cur_row_r = G_NUM_ROWS and grp_job_busy_r = 0 and
            job_started_r = '0' and job_started_d = '0' and
            job_started_dd = '0' and start_i = '0'
         then
            done_r <= '1';
         end if;
      end if;
   end process p_done;


   --------------------------
   -- Connect output signals
   --------------------------

   sched_active_o <= sched_active_r;
   done_o         <= done_r;

   job_rst_o      <= grp_rst_r;
   job_startx_o   <= grp_startx_r;
   job_cy_o       <= grp_cy_r;
   job_stepx_o    <= grp_stepx_r;
   job_start_o    <= job_start_d;

   tbl_valid_o    <= job_started_r;
   tbl_idx_o      <= job_idx_r;
   tbl_row_o      <= job_row_r;
   tbl_blk_o      <= job_blk_r;

end architecture rtl;
