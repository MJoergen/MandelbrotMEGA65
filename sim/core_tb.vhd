-- This is a self-checking testbench for core.vhd, i.e. the whole design from
-- the buttons and switches to the VGA output, with the display memory and the
-- clock domain crossing of the frame rate between the two clock domains. A
-- picture of a real size is too slow to simulate (the first picture is the
-- initial view, which is mostly inside the set), so the video mode is 640x4
-- (640 is the smallest width that vga.vhd accepts, because of the overlay),
-- with short blanking so that a frame is short, 16 job modules, and jobs of
-- one word (4 rows). The clocks are in the ratio of the Nexys 4 DDR (120 MHz
-- and 25 MHz), but about 17 times faster (2 GHz and 417 MHz).
--
-- It checks two pictures. For each of them it waits until the picture is
-- complete in the display memory (the frame rate is updated), and then
-- checks the next complete frame of the VGA output:
-- * The colour of every pixel is the colour that the palette selected by
--   switches 0 and 1 gives for the count of the bit-accurate model of the
--   iterator (iterator_model_pkg.vhd), converted to the value of the pixel as
--   in job_wide.vhd. The maximum count is 127 instead of 1023, so that the
--   simulation is shorter. So the whole path is checked: the
--   dispatcher and the job modules, the display memory with the two clock
--   domains, and the pixel and palette in the VGA clock domain. The view of
--   the picture (pic_startx etc.) is inside main.vhd, so it is read with
--   external names.
-- * The frame rate and the view as text in the VGA clock domain are the
--   same as in the MAIN clock domain (through cdc_data.vhd), and different from
--   the value at reset, when nothing is shown.
--
-- The first picture is the initial view, with palette 1. The second picture
-- is after the button for pan right has been held down for one update of the
-- view (see viewport.vhd), with palette 3. The view of the second picture
-- must differ from the first one. Switch 3 is off, so the palette does not
-- move (this is checked by disp_tb.vhd).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.iterator_model_pkg.all;
use work.palette_pkg.all;
use work.video_pkg.all;

entity core_tb is
end entity core_tb;

architecture simulation of core_tb is

   constant C_VIDEO         : video_mode_t := (
      h_visible => 640, h_front =>  8, h_sync =>  8, h_back =>  8,
      v_visible =>   4, v_front =>  1, v_sync =>  1, v_back =>  1,
      sync_active => '0');
   constant C_MAX_COUNT     : positive := 127;    -- Smaller than on the boards

   -- The frequency of the MAIN clock given to main.vhd sets the time between
   -- two updates of the view, so it is chosen such that this is longer than
   -- a picture (about 10,000 clock cycles) and the simulation is short.
   constant C_CLK_FREQ      : positive := 18*20000;

   -- The values at reset of the frame rate and the view, see core.vhd
   constant C_FPS_INIT      : std_logic_vector(159 downto 0) :=
      X"00000000FF" & X"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";

   signal main_clk : std_logic;
   signal main_rst : std_logic := '1';
   signal vga_clk  : std_logic;
   signal btn      : std_logic_vector(4 downto 0) := "00000";
   signal sw       : std_logic_vector(7 downto 0) := X"00";
   signal vga_hs   : std_logic;
   signal vga_vs   : std_logic;
   signal vga_de   : std_logic;
   signal vga_col  : std_logic_vector(7 downto 0);

begin

   ----------------------------
   -- Generate clocks and reset
   ----------------------------

   p_main_clk : process
   begin
      main_clk <= '0', '1' after 250 ps;
      wait for 500 ps;
   end process p_main_clk;

   p_vga_clk : process
   begin
      vga_clk <= '0', '1' after 1200 ps;
      wait for 2400 ps;
   end process p_vga_clk;

   p_rst : process
   begin
      main_rst <= '1';
      wait for 20 ns;
      wait until main_clk = '1';
      main_rst <= '0';
      wait;
   end process p_rst;


   -------------------
   -- Instantiate DUT
   -------------------

   i_core : entity work.core
      generic map (
         G_CLK_FREQ      => C_CLK_FREQ,
         G_NUM_ITERATORS => 16,
         G_PIXELS        => 4,
         G_ROWS_IN_JOB   => 4,
         G_VIDEO         => C_VIDEO,
         G_COL_STRIDE    => 4,
         G_ADDR_BITS     => 16,
         G_MEM_BLOCKS    => 16,
         G_BLOCK_REGS    => true,
         G_MAX_COUNT     => C_MAX_COUNT
      )
      port map (
         main_clk_i => main_clk,
         main_rst_i => main_rst,
         vga_clk_i  => vga_clk,
         btn_i      => btn,
         sw_i       => sw,
         seg_o      => open,
         seg_an_o   => open,
         vga_hs_o   => vga_hs,
         vga_vs_o   => vga_vs,
         vga_de_o   => vga_de,
         vga_col_o  => vga_col
      ); -- i_core


   -- The external names must come after the instantiation of core
   b_test : block is

      alias upd        is << signal .core_tb.i_core.i_main.upd : std_logic >>;
      alias fps_valid  is << signal .core_tb.i_core.fps_valid : std_logic >>;
      alias fps        is << signal .core_tb.i_core.fps : std_logic_vector(159 downto 0) >>;
      alias vga_fps    is << signal .core_tb.i_core.vga_fps : std_logic_vector(159 downto 0) >>;
      alias pic_startx is << signal .core_tb.i_core.i_main.pic_startx :
                                 std_logic_vector(34 downto 0) >>;
      alias pic_starty is << signal .core_tb.i_core.i_main.pic_starty :
                                 std_logic_vector(34 downto 0) >>;
      alias pic_stepx  is << signal .core_tb.i_core.i_main.pic_stepx :
                                 std_logic_vector(34 downto 0) >>;
      alias pic_stepy  is << signal .core_tb.i_core.i_main.pic_stepy :
                                 std_logic_vector(34 downto 0) >>;

   begin

      p_test : process

         variable startx_v : std_logic_vector(34 downto 0);  -- The view of the first picture

         -- Wait until the picture is complete, and then check the next frame
         procedure check_picture (num : positive) is
            variable x_v       : natural;
            variable y_v       : natural;
            variable de_v      : std_logic;
            variable cx_v      : signed(34 downto 0);
            variable cy_v      : signed(34 downto 0);
            variable cnt_v     : integer;
            variable exp_v     : std_logic_vector(7 downto 0);
            variable checked_v : natural := 0;
            variable errors_v  : natural := 0;
         begin
            wait until rising_edge(main_clk) and fps_valid = '1';
            report "Picture " & integer'image(num) & " is complete";

            -- Start of the next frame, i.e. the start of the vertical sync
            wait until rising_edge(vga_clk) and vga_vs /= C_VIDEO.sync_active;
            wait until rising_edge(vga_clk) and vga_vs = C_VIDEO.sync_active;

            x_v  := 0;
            y_v  := 0;
            de_v := '0';
            while y_v < C_VIDEO.v_visible loop
               wait until rising_edge(vga_clk);
               if vga_de = '1' then
                  cx_v   := resize(signed(pic_startx) +
                                   to_signed(x_v, 12) * signed(pic_stepx), 35);
                  cy_v   := resize(signed(pic_starty) +
                                   to_signed(y_v, 12) * signed(pic_stepy), 35);
                  cnt_v  := iterator_count(cx_v, cy_v, C_MAX_COUNT);
                  exp_v  := palette_colour(sw(1 downto 0),
                                           std_logic_vector(to_unsigned(
                                              to_pixel(cnt_v, C_MAX_COUNT), 9)));
                  checked_v := checked_v + 1;
                  if vga_col /= exp_v then
                     if errors_v < 5 then
                        report "Picture " & integer'image(num) & ": the colour of column " &
                               integer'image(x_v) & ", row " & integer'image(y_v) &
                               " is " & integer'image(to_integer(unsigned(vga_col))) &
                               ", but the model gives " &
                               integer'image(to_integer(unsigned(exp_v))) &
                               " (count " & integer'image(cnt_v) & ")"
                           severity error;
                     end if;
                     errors_v := errors_v + 1;
                  end if;
                  x_v := x_v + 1;
               elsif de_v = '1' then
                  assert x_v = C_VIDEO.h_visible
                     report "A line has " & integer'image(x_v) & " visible pixels"
                     severity error;
                  x_v := 0;
                  y_v := y_v + 1;
               end if;
               de_v := vga_de;
            end loop;

            assert checked_v = C_VIDEO.h_visible*C_VIDEO.v_visible
               report "Picture " & integer'image(num) & ": " & integer'image(checked_v) &
                      " pixels checked"
               severity error;
            report "Picture " & integer'image(num) & ": " & integer'image(checked_v) &
                   " pixels checked, " & integer'image(errors_v) & " wrong";
            assert errors_v = 0
               report "Picture " & integer'image(num) & ": " & integer'image(errors_v) &
                      " pixels have the wrong colour"
               severity error;

            -- The frame rate and the view, in the VGA clock domain
            assert vga_fps = fps
               report "Picture " & integer'image(num) &
                      ": the frame rate and the view differ in the two clock domains"
               severity error;
            assert vga_fps /= C_FPS_INIT
               report "Picture " & integer'image(num) &
                      ": the frame rate and the view are still the values at reset"
               severity error;
         end procedure check_picture;

      begin
         -- First picture: the initial view, with palette 1
         sw <= X"00";
         check_picture(1);
         startx_v := pic_startx;

         -- Hold the button for pan right down for exactly one update
         wait until rising_edge(main_clk) and upd = '1';
         wait until rising_edge(main_clk);
         btn <= "00100";
         wait until rising_edge(main_clk) and upd = '1';
         wait until rising_edge(main_clk);
         btn <= "00000";

         -- Second picture: the new view, with palette 3
         sw <= X"02";
         check_picture(2);
         assert pic_startx /= startx_v
            report "The view of the second picture is the same as that of the first"
            severity error;

         report "core_tb: finished";
         std.env.finish;
      end process p_test;

   end block b_test;

end architecture simulation;
