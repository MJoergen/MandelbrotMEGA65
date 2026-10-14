-- This is a self-checking testbench for the view control. It holds the buttons
-- down for many updates, and checks after every update:
-- * The view is inside the range -2 to 2 (not including 2): The first column
--   (row) is at least -2, and the last column (row) is less than 2.
-- * The size of a pixel is at least one LSB, and the same in both directions.
-- * The new view is the expected one, calculated by a simple model. Zooming
--   keeps the centre fixed (the pixel in column C_CENTRE_X and row
--   C_CENTRE_Y), unless the view is moved to keep it inside the range.
-- * The outputs all change in the same clock cycle.
-- It also checks the initial view, that panning and zooming reach the ends of
-- the range and stop there (also when starting from the other end), and that a
-- pulse on upd_i during an update is ignored, but one just after an update is
-- not.
--
-- This is done for both boards, each with its own instance, and with the
-- initial view of main.vhd: 640x480 with 2.16 (as on the Nexys 4 DDR, a pan
-- step of 2 pixels, and an update of 17 clock cycles) and 1280x1024 with 2.33
-- (as on the MEGA65, a pan step of 4 pixels, and an update of 18 clock
-- cycles, because 1279 has 11 bits). The values of the model are real
-- numbers, because the 2.33 values do not fit in an integer (they are exact
-- for integers up to 2^53). The tests that zoom or pan across the whole range
-- need more updates with 2.33, about 45 more for each extra bit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity viewport_tb is
end entity viewport_tb;

architecture simulation of viewport_tb is

   type config_t is record
      cols   : positive;
      rows   : positive;
      frac   : positive;    -- The number format, 2.frac
      -- The number of clock cycles of an update
      cycles : positive;
   end record config_t;
   type config_vector is array (natural range <>) of config_t;

   constant C_CONFIGS : config_vector := (
      (cols =>  640, rows =>  480, frac => 16, cycles => 17),
      (cols => 1280, rows => 1024, frac => 33, cycles => 18));

   -- The number of clock cycles to wait for an update to finish
   constant C_UPD_CYCLES : positive := 32;

   -- The view: the position of the first column and row (signed fixed
   -- point, as an integer), and the size of a pixel
   type view_t is record
      sx : real;
      sy : real;
      dx : real;
      dy : real;
   end record view_t;

   -- Convert a vector to a real number, as a signed or an unsigned integer.
   -- The vector has at least 18 bits.
   function to_real (v : std_logic_vector; sgn : boolean) return real is
      variable hi_v : real;
   begin
      if sgn then
         hi_v := real(to_integer(signed(v(v'left downto 16))));
      else
         hi_v := real(to_integer(unsigned(v(v'left downto 16))));
      end if;
      return hi_v * 65536.0 + real(to_integer(unsigned(v(15 downto 0))));
   end function to_real;

   signal clk      : std_logic;
   signal finished : std_logic_vector(C_CONFIGS'range) := (others => '0');

   -- Button bits, "CLRUD"
   constant C_BTN_C : std_logic_vector(4 downto 0) := "10000";
   constant C_BTN_L : std_logic_vector(4 downto 0) := "01000";
   constant C_BTN_R : std_logic_vector(4 downto 0) := "00100";
   constant C_BTN_U : std_logic_vector(4 downto 0) := "00010";
   constant C_BTN_D : std_logic_vector(4 downto 0) := "00001";
   constant C_NONE  : std_logic_vector(4 downto 0) := "00000";

begin

   ----------------------------
   -- Generate clock and reset
   ----------------------------

   p_clk : process
   begin
      clk <= '0', '1' after 5 ns;
      wait for 10 ns;
   end process p_clk;

   p_finish : process
   begin
      wait until finished = (finished'range => '1');
      report "viewport_tb: finished";
      std.env.finish;
   end process p_finish;


   gen_dut : for n in C_CONFIGS'range generate
      constant C_CFG      : config_t := C_CONFIGS(n);
      constant C_NUM_COLS : positive := C_CFG.cols;
      constant C_NUM_ROWS : positive := C_CFG.rows;
      constant C_FRAC     : positive := C_CFG.frac;

      -- The pan step in pixels, 1/320 of the number of columns (see
      -- viewport.vhd)
      constant C_PAN_PIXELS : positive := C_NUM_COLS/320;

      -- The column and row of the pixel that is kept fixed when zooming
      constant C_CENTRE_X : natural := C_NUM_COLS/2;
      constant C_CENTRE_Y : natural := C_NUM_ROWS/2;

      -- The size of the initial view, as in main.vhd
      constant C_SIZE_X : real := 8.0/3.0;
      constant C_SIZE_Y : real := C_SIZE_X * real(C_NUM_ROWS) / real(C_NUM_COLS);

      constant C_BITS  : positive := C_FRAC + 2;

      constant C_MIN   : real := -2.0**(C_BITS-1);       -- -2
      constant C_MAX   : real :=  2.0**(C_BITS-1) - 1.0; --  2-2^-C_FRAC

      -- The extra updates for zooming or panning across the whole range
      constant C_EXTRA : natural := 45*(C_FRAC-16);

      -- The initial view, as in main.vhd and viewport.vhd
      constant C_INIT_SX : real := floor((-1.6667+2.0) * 2.0**C_FRAC + 0.5) + C_MIN;
      constant C_INIT_SY : real := floor((-C_SIZE_Y/2.0+2.0) * 2.0**C_FRAC + 0.5) + C_MIN;
      constant C_INIT_DX : real := floor(floor(C_SIZE_X * 2.0**C_FRAC + 0.5) / real(C_NUM_COLS));

      signal rst      : std_logic := '1';
      signal upd      : std_logic := '0';
      signal btn      : std_logic_vector(4 downto 0) := (others => '0');
      signal zoom_out : std_logic := '0';
      signal startx   : std_logic_vector(C_BITS-1 downto 0);
      signal starty   : std_logic_vector(C_BITS-1 downto 0);
      signal stepx    : std_logic_vector(C_BITS-1 downto 0);
      signal stepy    : std_logic_vector(C_BITS-1 downto 0);

   begin


   ----------------------------
   -- Stimulus and checking
   ----------------------------

      p_test : process

      -- The current view (the outputs of the DUT)
         impure function cur_view return view_t is
         begin
            return (sx => to_real(startx, true),
                 sy => to_real(starty, true),
                 dx => to_real(stepx, false),
                 dy => to_real(stepy, false));
         end function cur_view;

         impure function sx return real is
         begin
            return cur_view.sx;
         end function sx;
         impure function sy return real is
         begin
            return cur_view.sy;
         end function sy;
         impure function dx return real is
         begin
            return cur_view.dx;
         end function dx;
         impure function dy return real is
         begin
            return cur_view.dy;
         end function dy;

      -- The position of the pixel that is kept fixed when zooming
         impure function centre_x return real is
         begin
            return sx + real(C_CENTRE_X)*dx;
         end function centre_x;
         impure function centre_y return real is
         begin
            return sy + real(C_CENTRE_Y)*dy;
         end function centre_y;

         function image (v : view_t) return string is
         begin
            return "(" & real'image(v.sx) & ", " & real'image(v.sy) & ", " &
                real'image(v.dx) & ", " & real'image(v.dy) & ")";
         end function image;

      -- The expected new size of a pixel when zooming
         function zoom (step : real; out_v : std_logic) return real is
         begin
            if out_v = '1' then
               return step + floor(step/64.0) + 1.0;
            else
               return step - floor(step/64.0) - 1.0;
            end if;
         end function zoom;

      -- The expected new position in one direction. The arguments are the
      -- position, the (new) size of a pixel, the number of pixels, and whether
      -- to pan towards larger or smaller values. The values are signed fixed
      -- point (as integers). The view moves by C_PAN_PIXELS pixels.
         function pan (pos : real; step : real; num : integer;
                    plus : boolean; minus : boolean) return real is
            variable res_v : real := pos;
         begin
            if plus then
               res_v := pos + real(C_PAN_PIXELS)*step;
            elsif minus then
               res_v := realmax(pos - real(C_PAN_PIXELS)*step, C_MIN);
            end if;
            return realmin(res_v, C_MAX - real(num-1)*step);
         end function pan;

      -- The expected view after one update, with the buttons b
         function next_view (v : view_t; b : std_logic_vector(4 downto 0);
                          out_v : std_logic) return view_t is
            variable res_v : view_t := v;
         begin
            if b(4) = '1' then
               if zoom(v.dx, out_v) >= 1.0 and zoom(v.dy, out_v) >= 1.0 and
               zoom(v.dx, out_v)*real(C_NUM_COLS-1) <= C_MAX - C_MIN and
               zoom(v.dy, out_v)*real(C_NUM_ROWS-1) <= C_MAX - C_MIN
            then
                  res_v.dx := zoom(v.dx, out_v);
                  res_v.dy := zoom(v.dy, out_v);

               -- Keep the centre fixed, but not before the start of the range
                  res_v.sx := realmax(v.sx + (v.dx - res_v.dx)*real(C_CENTRE_X), C_MIN);
                  res_v.sy := realmax(v.sy + (v.dy - res_v.dy)*real(C_CENTRE_Y), C_MIN);
               end if;
            end if;
            res_v.sx := pan(res_v.sx, res_v.dx, C_NUM_COLS, b(2) = '1', b(3) = '1');
            res_v.sy := pan(res_v.sy, res_v.dy, C_NUM_ROWS, b(0) = '1', b(1) = '1');
            return res_v;
         end function next_view;

      -- Check that the view is in range
         procedure check_range is
         begin
            assert sx >= C_MIN and sx + real(C_NUM_COLS-1)*dx <= C_MAX
               report "View out of range in x: startx = " & real'image(sx) &
                      ", stepx = " & real'image(dx)
               severity error;
            assert sy >= C_MIN and sy + real(C_NUM_ROWS-1)*dy <= C_MAX
               report "View out of range in y: starty = " & real'image(sy) &
                      ", stepy = " & real'image(dy)
               severity error;
            assert dx >= 1.0 and dy >= 1.0
               report "Size of a pixel less than one LSB"
               severity error;
            assert dx = dy
               report "Different size of a pixel in x and y"
               severity error;
         end procedure check_range;

      -- Wait until just after the next rising edge of the clock
         procedure clk_cycle is
         begin
            wait until rising_edge(clk);
            wait for 1 ns;
         end procedure clk_cycle;

      -- Pulse upd for one clock cycle, and wait for the update to finish. If
      -- second is larger than zero, pulse upd again, second clock cycles after
      -- the first pulse. Returns the number of clock cycles in which the view
      -- changed, and the last clock cycle (counted from the first pulse) in
      -- which it changed.
         procedure run_update (second  : in  integer;
                            changes : out integer;
                            last    : out integer) is
            variable prev_v : view_t;
            variable view_v : view_t;
         begin
            changes := 0;
            last    := -1;
            prev_v  := cur_view;
            upd     <= '1';
            for i in 0 to second + C_UPD_CYCLES loop
               clk_cycle;    -- The DUT samples upd in this clock cycle
               upd <= '0';
               if i+1 = second then
                  upd <= '1';
               end if;

               view_v := cur_view;
               if view_v /= prev_v then
                  changes := changes + 1;
                  last    := i;
               end if;
               prev_v := view_v;
            end loop;
         end procedure run_update;

      -- Hold the buttons down for a number of updates, and check the view
      -- after each update.
         procedure hold (b : std_logic_vector(4 downto 0); out_v : std_logic;
                      num : integer) is
            variable expected_v : view_t;
            variable changes_v  : integer;
            variable last_v     : integer;
         begin
            btn      <= b;
            zoom_out <= out_v;
            clk_cycle;
            for i in 1 to num loop
               expected_v := next_view(cur_view, b, out_v);
               run_update(0, changes_v, last_v);

               check_range;

               assert cur_view = expected_v
                  report "Wrong view after update " & integer'image(i) &
                         ": got " & image(cur_view) & ", expected " & image(expected_v)
                  severity error;

               assert changes_v <= 1
                  report "The outputs changed in " & integer'image(changes_v) &
                         " different clock cycles during an update"
                  severity error;
            end loop;
            btn <= C_NONE;
         end procedure hold;

      -- Check that a second pulse on upd during an update is ignored, and that
      -- one just after the update is not. The view is panned to the right, so
      -- that it changes in every update.
         procedure test_second_pulse is
            variable expected_v : view_t;
            variable changes_v  : integer;
            variable len_v      : integer;
            variable last_v     : integer;
         begin
            btn      <= C_BTN_R;
            zoom_out <= '0';
            clk_cycle;

         -- The clock cycle (counted from the pulse) in which the outputs
         -- change, i.e. the length of an update
            expected_v := next_view(cur_view, C_BTN_R, '0');
            run_update(0, changes_v, len_v);
            assert changes_v = 1 and cur_view = expected_v
               report "Wrong view after a single update"
               severity error;
            assert len_v = C_CFG.cycles
               report "An update takes " & integer'image(len_v) & " clock cycles, expected " &
                      integer'image(C_CFG.cycles)
               severity error;

            for k in 1 to len_v+1 loop
               if k <= len_v then
               -- The second pulse is during the update, and is ignored
                  expected_v := next_view(cur_view, C_BTN_R, '0');
               else
               -- The second pulse is just after the update, so there are two
               -- updates
                  expected_v := next_view(next_view(cur_view, C_BTN_R, '0'), C_BTN_R, '0');
               end if;

               run_update(k, changes_v, last_v);

               assert cur_view = expected_v
                  report "Wrong view with a second pulse after " & integer'image(k) &
                         " clock cycles: got " & image(cur_view) &
                         ", expected " & image(expected_v)
                  severity error;
            end loop;
            btn <= C_NONE;
         end procedure test_second_pulse;

         procedure do_reset is
         begin
            rst <= '1';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            rst <= '0';
            wait until rising_edge(clk);
         end procedure do_reset;

         variable cx0_v : real;
         variable cy0_v : real;

      begin
         do_reset;

      -- The initial view, as in main.vhd. The values for 640x480 with 2.16 are
      -- given directly too.
         assert sx = C_INIT_SX and sy = C_INIT_SY and dx = C_INIT_DX and dy = C_INIT_DX
            report "Wrong initial view: " & image(cur_view)
            severity error;
         assert C_NUM_COLS /= 640 or (sx = -109229.0 and sy = -65536.0 and dx = 273.0)
            report "Wrong initial view"
            severity error;
         check_range;

      -- Without buttons nothing changes
         hold(C_NONE, '0', 3);

      -- A pulse on upd during an update is ignored
         test_second_pulse;

      -- Zoom in. The centre stays fixed.
         cx0_v := centre_x;
         cy0_v := centre_y;
         hold(C_BTN_C, '0', 100);
         assert centre_x = cx0_v and centre_y = cy0_v and dx < C_INIT_DX
            report "Zoom in did not keep the centre fixed"
            severity error;

      -- Zoom out until the view can not get larger. The centre is fixed until
      -- the left edge reaches the start of the range, and then the view moves
      -- right.
         hold(C_BTN_C, '1', 200);
         assert sx = C_MIN and zoom(dx, '1')*real(C_NUM_COLS-1) > C_MAX - C_MIN
            report "Zoom out did not reach the full range in x"
            severity error;

      -- Pan in all directions to the ends of the range
         hold(C_BTN_D, '0', 300);
         assert sy + real(C_NUM_ROWS-1)*dy = C_MAX
            report "Pan down did not stop at the end"
            severity error;
         hold(C_BTN_U, '0', 300);
         assert sy = C_MIN
            report "Pan up did not stop at the end"
            severity error;
         hold(C_BTN_R, '0', 10);
         hold(C_BTN_L, '0', 20);
         assert sx = C_MIN
            report "Pan left did not stop at the end"
            severity error;

      -- Zoom in until the size of a pixel is one LSB. The centre stays fixed.
         cx0_v := centre_x;
         cy0_v := centre_y;
         hold(C_BTN_C, '0', 400 + C_EXTRA);
         assert dx = 1.0 and dy = 1.0 and centre_x = cx0_v and centre_y = cy0_v
            report "Zoom in did not stop at one LSB, with the centre fixed"
            severity error;

      -- Pan at maximum zoom, right and down at the same time
         cx0_v := sx;
         cy0_v := sy;
         hold(C_BTN_R or C_BTN_D, '0', 200);
         assert sx = cx0_v + 200.0*real(C_PAN_PIXELS) and sy = cy0_v + 200.0*real(C_PAN_PIXELS)
            report "Wrong pan at maximum zoom"
            severity error;

      -- Zoom out a little, and pan all the way to the right and bottom, both at
      -- the same time
         hold(C_BTN_C, '1', 60 + C_EXTRA);
         hold(C_BTN_R or C_BTN_D, '0', 6000);
         assert sx + real(C_NUM_COLS-1)*dx = C_MAX and sy + real(C_NUM_ROWS-1)*dy = C_MAX
            report "Pan right and down did not stop at the end"
            severity error;

      -- Zoom out from the bottom right corner. The view moves left and up, so
      -- the right and bottom edges stay in range.
         hold(C_BTN_C, '1', 400);
         assert zoom(dx, '1')*real(C_NUM_COLS-1) > C_MAX - C_MIN
            report "Zoom out from the right edge did not reach the full range"
            severity error;

      -- Zoom in and pan at the same time, with both left and right (right has
      -- priority) and both up and down (down has priority)
         hold(C_BTN_C or C_BTN_L or C_BTN_R or C_BTN_U or C_BTN_D, '0', 100);

      -- Reset returns to the initial view
         do_reset;
         assert sx = C_INIT_SX and sy = C_INIT_SY and dx = C_INIT_DX and dy = C_INIT_DX
            report "Wrong view after reset"
            severity error;

         report integer'image(C_NUM_COLS) & "x" & integer'image(C_NUM_ROWS) & ": finished";
         finished(n) <= '1';
         wait;
      end process p_test;


   -------------------
   -- Instantiate DUT
   -------------------

      i_viewport : entity work.viewport
         generic map (
            G_NUM_COLS  => C_NUM_COLS,
            G_NUM_ROWS  => C_NUM_ROWS,
            G_START_X   => -1.6667,
            G_START_Y   => -C_SIZE_Y / 2.0,
            G_SIZE_X    =>  C_SIZE_X,
            G_SIZE_Y    =>  C_SIZE_Y,
            G_FRAC_BITS => C_FRAC
         )
         port map (
            clk_i      => clk,
            rst_i      => rst,
            upd_i      => upd,
            btn_i      => btn,
            zoom_out_i => zoom_out,
            startx_o   => startx,
            starty_o   => starty,
            stepx_o    => stepx,
            stepy_o    => stepy
         ); -- i_viewport

   end generate gen_dut;

end architecture simulation;
