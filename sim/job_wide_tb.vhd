-- This is a simple self-checking testbench for the job module (job_wide.vhd),
-- with numbers in 2.33 fixed point format, and always four pixels (columns)
-- in each result. It runs a few jobs, and checks the following:
-- * The job module is not busy, and gives no results, when idle.
-- * The job module is busy from the start of a job until the last result has
--   been acknowledged.
-- * The results come in order, one for each group of four columns, with the
--   column number of the first column, and each result is given only once.
-- * A result stays valid, and unchanged, until it is acknowledged. This is
--   tested by delaying the acknowledge by a varying number of clock cycles.
-- * The value of each pixel is exactly the value given by the bit-accurate
--   model in iterator_model_pkg.vhd, for the value of c of that column: the
--   count, or 511 for the points in the set.
-- This is done for jobs of 12 columns (three results) and of 4 columns (a
-- single result). One of the jobs has values of cx that wrap around (from 2
-- to -2).
--
-- Only a few columns, and a low maximum count, are used to keep the simulation
-- short.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.iterator_model_pkg.all;

entity job_wide_tb is
end entity job_wide_tb;

architecture simulation of job_wide_tb is

   constant C_MAX_COUNT   : positive := 50;
   constant C_PIXELS      : positive := 4;

   -- Columns in each job, in each instance
   type int_vector is array (natural range <>) of integer;
   constant C_NUM_COLS    : int_vector := (12, 4);

   signal clk         : std_logic;
   signal rst         : std_logic;
   signal finished    : std_logic_vector(C_NUM_COLS'range) := (others => '0');

begin

   ----------------------------
   -- Generate clock and reset
   ----------------------------

   p_clk : process
   begin
      clk <= '0', '1' after 5 ns;
      wait for 10 ns;
   end process p_clk;

   p_rst : process
   begin
      rst <= '1';
      wait for 100 ns;
      wait until clk = '1';
      rst <= '0';
      wait;
   end process p_rst;


   p_finish : process
   begin
      wait until finished = (finished'range => '1');
      report "job_wide_tb: finished";
      std.env.finish;
   end process p_finish;


   gen_dut : for n in C_NUM_COLS'range generate
      constant C_COLS : positive := C_NUM_COLS(n);

      -- Maximum number of clock cycles to wait for a single result
      constant C_RES_TIMEOUT : positive := 4*C_MAX_COUNT + 30;

      signal job_start   : std_logic := '0';
      signal job_startx  : std_logic_vector(34 downto 0) := (others => '0');
      signal job_cy      : std_logic_vector(34 downto 0) := (others => '0');
      signal job_stepx   : std_logic_vector(34 downto 0) := (others => '0');
      signal job_busy    : std_logic;
      signal res_addr    : std_logic_vector( 8 downto 0);
      signal res_ack     : std_logic := '0';
      signal res_data    : std_logic_vector(9*C_PIXELS-1 downto 0);
      signal res_valid   : std_logic;

   begin

      ----------------------------
      -- Stimulus and checking
      ----------------------------

      p_test : process

         -- Run a job, and check the results of all the columns. The signals are
         -- all sampled just before a rising clock edge.
         procedure run_job (
            startx_r : real;
            cy_r     : real;
            stepx_r  : real;
            name     : string
         ) is
            variable cx_v       : signed(34 downto 0);
            variable exp_v      : integer;
            variable act_v      : integer;
            variable seen_v     : boolean;
            variable cap_addr_v : std_logic_vector(8 downto 0);
            variable cap_data_v : std_logic_vector(9*C_PIXELS-1 downto 0);
            variable col_v      : integer;
         begin
            report "Starting job " & name & " with " & integer'image(C_COLS) & " columns";

            wait until rising_edge(clk);
            job_startx <= std_logic_vector(to_fixed_wide(startx_r));
            job_cy     <= std_logic_vector(to_fixed_wide(cy_r));
            job_stepx  <= std_logic_vector(to_fixed_wide(stepx_r));
            job_start  <= '1';
            wait until rising_edge(clk);
            job_start  <= '0';

            for res in 0 to C_COLS/C_PIXELS-1 loop
               -- Wait for the result of these columns
               col_v  := res*C_PIXELS;
               seen_v := false;
               for t in 1 to C_RES_TIMEOUT loop
                  wait until rising_edge(clk);
                  assert job_busy = '1'
                     report name & ": Not busy during the job"
                     severity error;
                  if res_valid = '1' then
                     seen_v := true;
                     exit;
                  end if;
               end loop;
               assert seen_v
                  report name & ": Timeout waiting for the result of column " & integer'image(col_v)
                  severity failure;

               cap_addr_v := res_addr;
               cap_data_v := res_data;

               -- Check the column number and the counts
               assert to_integer(unsigned(cap_addr_v)) = col_v
                  report name & ": Wrong column number: got " &
                         integer'image(to_integer(unsigned(cap_addr_v))) &
                         ", expected " & integer'image(col_v)
                  severity error;

               for i in 0 to C_PIXELS-1 loop
                  -- The job module adds the step in 35 bits, so the values
                  -- wrap around
                  cx_v := to_fixed_wide(startx_r);
                  for c in 1 to col_v+i loop
                     cx_v := cx_v + to_fixed_wide(stepx_r);
                  end loop;
                  exp_v  := to_pixel(iterator_count(cx_v, to_fixed_wide(cy_r), C_MAX_COUNT),
                                     C_MAX_COUNT);
                  act_v  := to_integer(unsigned(cap_data_v(9*i+8 downto 9*i)));
                  report name & ": column " & integer'image(col_v+i) &
                         ": pixel = " & integer'image(act_v) &
                         ", expected = " & integer'image(exp_v);
                  assert act_v = exp_v
                     report name & ": Wrong pixel for column " & integer'image(col_v+i) & ": got " &
                            integer'image(act_v) & ", expected " & integer'image(exp_v)
                     severity error;
               end loop;

               -- Delay the acknowledge. The result must remain valid and unchanged.
               for t in 1 to (res mod 3) * 3 loop
                  wait until rising_edge(clk);
                  assert res_valid = '1' and res_addr = cap_addr_v and res_data = cap_data_v
                     report name & ": Result changed before it was acknowledged, column " &
                            integer'image(col_v)
                     severity error;
               end loop;

               res_ack <= '1';
               wait until rising_edge(clk);
               res_ack <= '0';
            end loop;

            -- The job module should now be idle
            for t in 1 to 5 loop
               wait until rising_edge(clk);
               assert job_busy = '0' and res_valid = '0'
                  report name & ": Not idle after the last result"
                  severity error;
            end loop;
         end procedure run_job;

      begin
         wait until rst = '0';

         -- Nothing should happen when idle
         for t in 1 to 10 loop
            wait until rising_edge(clk);
            assert job_busy = '0' and res_valid = '0'
               report "Not idle before the first job"
               severity error;
         end loop;

         -- Job 1: Mixture of points in the set and points that escape quickly
         run_job(-2.0, 0.0, 0.25, "job 1");

         -- Job 2: Points with gradually decreasing counts
         run_job(0.25, 0.0, 0.0625, "job 2");

         -- Job 3: Points near the top of the set (near i), where x+y or x-y is
         -- often outside the range -2 to 2 during the iteration
         run_job(-0.3, 1.0, 0.05, "job 3");

         -- Job 4: The values of cx wrap around from 2 to -2 after the fifth
         -- column
         run_job(1.9, -0.5, 0.0200001, "job 4");

         finished(n) <= '1';
         wait;
      end process p_test;


      -------------------
      -- Instantiate DUT
      -------------------

      i_job_wide : entity work.job_wide
         generic map (
            G_MAX_COUNT => C_MAX_COUNT,
            G_NUM_COLS  => C_COLS,
            G_PIXELS    => C_PIXELS
         )
         port map (
            clk_i        => clk,
            rst_i        => rst,
            job_start_i  => job_start,
            job_startx_i => job_startx,
            job_cy_i     => job_cy,
            job_stepx_i  => job_stepx,
            job_busy_o   => job_busy,
            res_addr_o   => res_addr,
            res_ack_i    => res_ack,
            res_data_o   => res_data,
            res_valid_o  => res_valid
         ); -- i_job_wide

   end generate gen_dut;

end architecture simulation;
