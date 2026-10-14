-- This is a self-checking testbench for main.vhd, which compares the pictures
-- that it calculates with the bit-accurate model of the iterator
-- (iterator_model_pkg.vhd). It is the same check as main_tb.vhd with
-- cmp_rtl.py, but with a small picture (64x48, with 8 job modules, four
-- pixels in each write, and jobs of 12 rows), so that it is part of make sim.
--
-- For each picture it checks:
-- * Each write is inside the picture, at the first row of a word.
-- * Each pixel is written exactly once, and the picture is complete when the
--   frame rate is updated (fps_valid_o, at the end of the picture).
-- * The value of each pixel is the value of the model, for the value of c of
--   the pixel: 511 for the points in the set, and otherwise the count modulo
--   511 (see job_wide.vhd). The view of the picture (pic_startx etc.) is
--   inside main.vhd, so it is read with external names.
-- The pictures are the initial view, then the view after an update with zoom
-- in, pan right, and pan down, and then the view after an update with zoom
-- out (switch 2), pan left, and pan up.
--
-- The maximum count is 127 instead of the 1023 of the boards, so that the
-- simulation is short: with 1023 a picture takes 3.6 times as many clock
-- cycles (66275 instead of 18430, from the model), and the simulation of the
-- three pictures took more than half an hour.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.iterator_model_pkg.all;

entity picture_tb is
end entity picture_tb;

architecture simulation of picture_tb is

   constant C_MAX_COUNT     : positive := 127;    -- See above
   constant C_NUM_ITERATORS : positive := 8;
   constant C_PIXELS        : positive := 4;
   constant C_ROWS_IN_JOB   : positive := 12;
   constant C_NUM_COLS      : positive := 64;
   constant C_NUM_ROWS      : positive := 48;
   constant C_COL_STRIDE    : positive := 64;
   constant C_ADDR_BITS     : positive := 12;

   -- The number of words written for each picture
   constant C_WORDS         : positive := C_NUM_COLS*C_NUM_ROWS/C_PIXELS;

   -- Clock cycles between two updates of the view, longer than a picture
   constant C_UPD_PERIOD    : positive := 30000;

   signal clk       : std_logic;
   signal rst       : std_logic := '1';
   signal btn       : std_logic_vector(4 downto 0) := "00000";
   signal sw        : std_logic_vector(7 downto 0) := X"00";
   signal fps_valid : std_logic;
   signal wr_addr   : std_logic_vector(C_ADDR_BITS-1 downto 0);
   signal wr_data   : std_logic_vector(9*C_PIXELS-1 downto 0);
   signal wr_en     : std_logic;

   -- The pictures that have been checked, and the pixels with the wrong count
   signal pictures  : natural := 0;
   signal errors    : natural := 0;

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


   -------------------
   -- Instantiate DUT
   -------------------

   i_main : entity work.main
      generic map (
         G_CLK_FREQ      => 18*C_UPD_PERIOD,
         G_NUM_ITERATORS => C_NUM_ITERATORS,
         G_PIXELS        => C_PIXELS,
         G_ROWS_IN_JOB   => C_ROWS_IN_JOB,
         G_NUM_COLS      => C_NUM_COLS,
         G_NUM_ROWS      => C_NUM_ROWS,
         G_COL_STRIDE    => C_COL_STRIDE,
         G_ADDR_BITS     => C_ADDR_BITS,
         G_MAX_COUNT     => C_MAX_COUNT
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         btn_i        => btn,
         sw_i         => sw,
         seg_o        => open,
         seg_an_o     => open,
         fps_digits_o => open,
         fps_blank_o  => open,
         fps_valid_o  => fps_valid,
         wr_addr_o    => wr_addr,
         wr_data_o    => wr_data,
         wr_en_o      => wr_en
      ); -- i_main


   -- The external names must come after the instantiation of main
   b_test : block is

      alias upd        is << signal .picture_tb.i_main.upd : std_logic >>;
      alias start      is << signal .picture_tb.i_main.start : std_logic >>;
      alias pic_startx is << signal .picture_tb.i_main.pic_startx :
                             std_logic_vector(34 downto 0) >>;
      alias pic_starty is << signal .picture_tb.i_main.pic_starty :
                             std_logic_vector(34 downto 0) >>;
      alias pic_stepx  is << signal .picture_tb.i_main.pic_stepx :
                             std_logic_vector(34 downto 0) >>;
      alias pic_stepy  is << signal .picture_tb.i_main.pic_stepy :
                             std_logic_vector(34 downto 0) >>;

      type seen_t is array (0 to C_NUM_COLS-1, 0 to C_NUM_ROWS-1) of boolean;

   begin

      ----------------------------------------
      -- Check every write, at each rising edge
      ----------------------------------------

      p_check : process (clk)
         variable seen_v  : seen_t := (others => (others => false));
         variable words_v : natural := 0;   -- Words written by the current picture
         variable col_v   : natural;
         variable row_v   : natural;
         variable cx_v    : signed(34 downto 0);
         variable cy_v    : signed(34 downto 0);
         variable exp_v   : integer;
         variable got_v   : integer;
         variable err_v   : natural := 0;   -- Pixels with the wrong count
      begin
         if rising_edge(clk) and rst = '0' then
            -- main takes the view of the picture (pic_*) at this rising edge
            if start = '1' then
               seen_v  := (others => (others => false));
               words_v := 0;
            end if;

            if wr_en = '1' then
               col_v := to_integer(unsigned(wr_addr)) / C_COL_STRIDE;
               row_v := to_integer(unsigned(wr_addr)) mod C_COL_STRIDE;
               assert col_v < C_NUM_COLS and row_v < C_NUM_ROWS and row_v mod C_PIXELS = 0
                  report "Picture " & integer'image(pictures+1) & ": a word was written to " &
                         "column " & integer'image(col_v) & ", row " & integer'image(row_v)
                  severity failure;
               for i in 0 to C_PIXELS-1 loop
                  assert not seen_v(col_v, row_v+i)
                     report "Picture " & integer'image(pictures+1) & ": the pixel in column " &
                            integer'image(col_v) & ", row " & integer'image(row_v+i) &
                            " was written twice"
                     severity error;
                  seen_v(col_v, row_v+i) := true;

                  -- The dispatcher and the job modules add the steps in 35
                  -- bits, which wrap around
                  cx_v  := resize(signed(pic_startx) +
                                  to_signed(col_v, 12) * signed(pic_stepx), 35);
                  cy_v  := resize(signed(pic_starty) +
                                  to_signed(row_v+i, 12) * signed(pic_stepy), 35);
                  exp_v := to_pixel(iterator_count(cx_v, cy_v, C_MAX_COUNT), C_MAX_COUNT);
                  got_v := to_integer(unsigned(wr_data(9*i+8 downto 9*i)));
                  if got_v /= exp_v then
                     if err_v < 5 then
                        report "Picture " & integer'image(pictures+1) & ": the pixel in column " &
                               integer'image(col_v) & ", row " & integer'image(row_v+i) &
                               " is " & integer'image(got_v) & ", but the model gives " &
                               integer'image(exp_v)
                           severity error;
                     end if;
                     err_v := err_v + 1;
                  end if;
               end loop;
               errors  <= err_v;
               words_v := words_v + 1;
            end if;

            -- The frame rate is updated at the end of each picture
            if fps_valid = '1' then
               assert words_v = C_WORDS
                  report "Picture " & integer'image(pictures+1) & " has " &
                         integer'image(words_v) & " words when the frame rate is updated, " &
                         "expected " & integer'image(C_WORDS)
                  severity error;
               report "Picture " & integer'image(pictures+1) & " checked, with stepx " &
                      to_hstring(pic_stepx);
               pictures <= pictures + 1;
            end if;
         end if;
      end process p_check;


      --------------
      -- Stimulus
      --------------

      p_test : process

         -- Hold the buttons (and switch 2, zoom out) down for exactly one
         -- update. They are set long before the update, and released after
         -- it.
         procedure do_update (
            b        : std_logic_vector(4 downto 0);
            zoom_out : std_logic
         ) is
         begin
            btn   <= b;
            sw(2) <= zoom_out;
            wait until rising_edge(clk) and upd = '1';
            wait until rising_edge(clk);
            btn   <= "00000";
            sw(2) <= '0';
         end procedure do_update;

      begin
         wait until rst = '0';

         -- The initial view, started at once after reset
         wait until pictures = 1;

         -- Zoom in, pan right, and pan down
         do_update("10101", '0');
         wait until pictures = 2;

         -- Zoom out, pan left, and pan up
         do_update("11010", '1');
         wait until pictures = 3;

         assert errors = 0
            report integer'image(errors) & " pixels differ from the model"
            severity error;

         report "picture_tb: finished";
         std.env.finish;
      end process p_test;

   end block b_test;

end architecture simulation;
