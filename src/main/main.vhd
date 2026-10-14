-- This module runs entirely in the MAIN clock domain (G_CLK_FREQ). It
-- controls the view (from the buttons and switches), runs the dispatcher that
-- calculates the picture, and writes the result to the display memory.
--
-- The view is controlled by the buttons and switches of the Nexys 4 DDR. The
-- MEGA65 maps its joysticks and keyboard to them, see mega65.vhd:
--   btn_i(4)         : Zoom in. If sw_i(2) is set then zoom out instead.
--   btn_i(3 downto 0): Move the view left, right, up, and down.
-- While a button is pressed, the view is updated 18 times per second, i.e.
-- every G_CLK_FREQ/18 clock cycles.
-- The view is kept inside the range -2 to 2, see viewport.vhd.
-- Switches 0 and 1 select the colour palette, and switch 3 moves it, but they
-- are used in vga.vhd, not here. The other switches are not used.
--
-- The numbers are in 2.33 fixed point format (35 bits), see dispatcher.vhd.
-- The maximum count is G_MAX_COUNT, 1023 on both boards.
--
-- A picture is only calculated when the view has changed, i.e. after reset,
-- and when the view is changed by the buttons. In between, the dispatcher and
-- the job modules are idle, and use much less power.
--
-- The 7-segment display of the Nexys 4 DDR shows the frame rate, i.e. the
-- clock frequency divided by the time taken by the latest picture, see
-- fps.vhd. This is the number of pictures per second if the picture was
-- recalculated continuously. The frame rate is also output (fps_*_o), and
-- shown on the VGA output by vga.vhd.
-- fps_valid_o is high for one clock cycle when fps_digits_o and fps_blank_o
-- are changed. The top level module moves the frame rate to the VGA clock
-- domain, so this module does not depend on the VGA clock.
--
-- The view of each picture (the centre and the zoom) is converted to text
-- when the picture is started, see view_text.vhd, and shown on the VGA output
-- too. view_text_o is changed together with the frame rate, at the end of the
-- picture (fps_valid_o), so the text and the frame rate on the screen are
-- always those of the same picture, i.e. the latest one, and the top level
-- moves them to the VGA clock domain together. The conversion takes 130
-- clock cycles (for 1280x1024), which is much less than a picture.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

entity main is
   generic (
      -- The frequency of the MAIN clock in Hz, used to calculate the frame
      -- rate. This depends on the board, so it is set by the top level module.
      G_CLK_FREQ      : natural;
      -- The number of job modules, i.e. iterators (with six DSPs each). This
      -- depends on the size of the FPGA, so it is set by the top level
      -- module.
      G_NUM_ITERATORS : positive;
      -- The number of pixels in each write to the display memory, see
      -- dispatcher.vhd and disp_mem.vhd. The wide iterator calculates four
      -- rows at a time, so this must be 4 (see job_wide.vhd), and the rows in
      -- a job (G_ROWS_IN_JOB) must be a multiple of it.
      G_PIXELS        : positive;
      -- Rows in each job given to a job module, see dispatcher.vhd. The
      -- number of rows of the picture must be a multiple of it.
      G_ROWS_IN_JOB   : positive;
      -- The size of the picture, i.e. the resolution of the VGA output, the
      -- address distance between two picture columns in the display memory,
      -- and the number of bits of the address, see dispatcher.vhd.
      G_NUM_COLS      : positive;
      G_NUM_ROWS      : positive;
      G_COL_STRIDE    : positive;
      G_ADDR_BITS     : positive;
      -- The maximum count. The count is converted to the 9-bit value of the
      -- display memory, see job_wide.vhd.
      G_MAX_COUNT     : positive
   );
   port (
      clk_i        : in  std_logic;                      -- G_CLK_FREQ
      rst_i        : in  std_logic;

      btn_i        : in  std_logic_vector( 4 downto 0);  -- "CLRUD"
      sw_i         : in  std_logic_vector( 7 downto 0);
      seg_o        : out std_logic_vector( 6 downto 0);  -- "GFEDCBA"
      seg_an_o     : out std_logic_vector( 7 downto 0);

      -- The frame rate, see fps.vhd
      fps_digits_o : out std_logic_vector(31 downto 0);
      fps_blank_o  : out std_logic_vector( 7 downto 0);
      fps_valid_o  : out std_logic;

      -- The view of the latest picture, as text, see view_text.vhd
      view_text_o  : out std_logic_vector(99 downto 0);

      -- Write port of the display memory
      wr_addr_o    : out std_logic_vector(G_ADDR_BITS-1 downto 0);
      wr_data_o    : out std_logic_vector(9*G_PIXELS-1 downto 0);
      wr_en_o      : out std_logic
   );
end entity main;

architecture structural of main is

   -- The initial view. The real axis is from -1.6667 to 1.0, and the
   -- imaginary axis is centred on 0. The size has the same aspect ratio as
   -- the picture, so the pixels are square: The imaginary axis is from -1.0
   -- to 1.0 for 4:3 (640x480), and from -1.0667 to 1.0667 for 5:4
   -- (1280x1024). The size of the real axis is 8/3 exactly, so the sizes of
   -- a pixel in the two directions (C_SIZE_X/G_NUM_COLS and
   -- C_SIZE_Y/G_NUM_ROWS) are equal.
   constant C_START_X       : real := -1.6667;
   constant C_SIZE_X        : real :=  8.0 / 3.0;
   constant C_SIZE_Y        : real :=  C_SIZE_X * real(G_NUM_ROWS) / real(G_NUM_COLS);
   constant C_START_Y       : real := -C_SIZE_Y / 2.0;

   -- The initial size of a pixel in LSBs of 2.16, as in viewport.vhd. The
   -- text of the view (view_text.vhd) is calculated in 2.16, see below.
   constant C_INIT_STEP     : positive := integer(C_SIZE_X*real(2**16))/G_NUM_COLS;

   signal startx         : std_logic_vector(34 downto 0);
   signal starty         : std_logic_vector(34 downto 0);
   signal stepx          : std_logic_vector(34 downto 0);
   signal stepy          : std_logic_vector(34 downto 0);

   signal start          : std_logic;
   signal active         : std_logic;
   signal done           : std_logic;
   signal pic_done       : std_logic;

   -- The view of the latest picture, i.e. the one the dispatcher uses. first is
   -- set after reset, until the first picture is started. view_new is set
   -- when the view differs from the one of the latest picture (or after
   -- reset), i.e. when a new picture must be calculated. The initial value of
   -- first is the same as after reset, so the view is not compared before it
   -- has a value (in simulation).
   signal pic_startx     : std_logic_vector(34 downto 0);
   signal pic_starty     : std_logic_vector(34 downto 0);
   signal pic_stepx      : std_logic_vector(34 downto 0);
   signal pic_stepy      : std_logic_vector(34 downto 0);
   signal first          : std_logic := '1';
   signal view_new       : std_logic;

   signal wr_addr_s      : std_logic_vector(G_ADDR_BITS-1 downto 0);
   signal wr_data_s      : std_logic_vector(9*G_PIXELS-1 downto 0);
   signal wr_en_s        : std_logic;

   -- Time taken by the current picture, in clock cycles
   signal cnt            : std_logic_vector(26 downto 0);

   -- The frame rate, in decimal
   signal fps_digits     : std_logic_vector(31 downto 0);
   signal fps_blank      : std_logic_vector( 7 downto 0);
   signal fps_valid      : std_logic;

   -- The view in 2.16, for view_text.vhd
   signal txt_startx     : std_logic_vector(17 downto 0);
   signal txt_starty     : std_logic_vector(17 downto 0);
   signal txt_stepx      : std_logic_vector(17 downto 0);
   signal txt_stepy      : std_logic_vector(17 downto 0);

   -- The view of the picture, as text. view_text_r is changed together with
   -- the frame rate. Nothing is shown before the first picture.
   signal view_text      : std_logic_vector(99 downto 0);
   signal view_text_r    : std_logic_vector(99 downto 0) := (others => '1');

   -- The view is updated 18 times per second.
   constant C_UPD_PERIOD : natural := G_CLK_FREQ / 18;
   signal upd_cnt        : natural range 0 to C_UPD_PERIOD-1 := 0;
   signal upd            : std_logic;

   -- The buttons and switches are asynchronous (on the MEGA65 the joysticks,
   -- combined with the keys), so they are synchronized with two registers.
   signal btn_meta       : std_logic_vector(4 downto 0);
   signal btn_sync       : std_logic_vector(4 downto 0);
   signal sw_meta        : std_logic_vector(7 downto 0);
   signal sw_sync        : std_logic_vector(7 downto 0);

   attribute async_reg : string;
   attribute async_reg of btn_meta : signal is "true";
   attribute async_reg of btn_sync : signal is "true";
   attribute async_reg of sw_meta  : signal is "true";
   attribute async_reg of sw_sync  : signal is "true";

begin

   p_upd : process (clk_i)
   begin
      if rising_edge(clk_i) then
         upd <= '0';
         if upd_cnt = C_UPD_PERIOD-1 then
            upd_cnt <= 0;
            upd     <= '1';
         else
            upd_cnt <= upd_cnt + 1;
         end if;
      end if;
   end process p_upd;


   p_btn : process (clk_i)
   begin
      if rising_edge(clk_i) then
         btn_meta <= btn_i;
         btn_sync <= btn_meta;
         sw_meta  <= sw_i;
         sw_sync  <= sw_meta;
      end if;
   end process p_btn;


   --------------------------------------------------
   -- Instantiate view control
   --------------------------------------------------

   i_viewport : entity work.viewport
      generic map (
         G_NUM_COLS => G_NUM_COLS,
         G_NUM_ROWS => G_NUM_ROWS,
         G_START_X  => C_START_X,
         G_START_Y  => C_START_Y,
         G_SIZE_X   => C_SIZE_X,
         G_SIZE_Y   => C_SIZE_Y
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         upd_i      => upd,
         btn_i      => btn_sync,
         zoom_out_i => sw_sync(2),
         startx_o   => startx,
         starty_o   => starty,
         stepx_o    => stepx,
         stepy_o    => stepy
      ); -- i_viewport


   -- The current picture is finished. The signal done stays high until the
   -- dispatcher has seen the start, so done is ignored while start is high.
   -- Otherwise done would cancel the new picture, and a second start would be
   -- generated. This is high for a single clock cycle for each picture.
   pic_done <= active and done and not start;

   -- The view is compared with the view of the latest picture. The view is
   -- updated 18 times per second, also when no button is held down, so the
   -- picture is only recalculated when the update has changed something. The
   -- result is registered, so the comparison of 140 bits has a clock cycle of its own. view_new is therefore set one clock cycle
   -- after the view changes, and cleared two clock cycles after the start. It
   -- is only used when no picture is being calculated, and a picture takes far
   -- longer.
   p_view_new : process (clk_i)
   begin
      if rising_edge(clk_i) then
         view_new <= '0';
         if first = '1' or
            startx /= pic_startx or starty /= pic_starty or
            stepx /= pic_stepx or stepy /= pic_stepy
         then
            view_new <= '1';
         end if;
      end if;
   end process p_view_new;

   p_active : process (clk_i)
   begin
      if rising_edge(clk_i) then
         start <= '0';

         -- Start a new picture when the previous one is finished, and the view
         -- has changed since the previous one was started (or after reset).
         if active = '0' then
            if view_new = '1' then
               active <= '1';
               start  <= '1';
            end if;
         elsif pic_done = '1' then
            active <= '0';
         end if;

         -- The dispatcher takes the view when it sees the start, so the view
         -- of the picture is taken at the same time.
         if start = '1' then
            pic_startx <= startx;
            pic_starty <= starty;
            pic_stepx  <= stepx;
            pic_stepy  <= stepy;
            first      <= '0';
         end if;

         if rst_i = '1' then
            active <= '0';
            start  <= '0';
            first  <= '1';
         end if;
      end if;
   end process p_active;


   p_cnt : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if active = '1' then
            cnt <= cnt + 1;
         end if;

         if start = '1' then
            cnt <= (others => '0');
         end if;
      end if;
   end process p_cnt;


   --------------------------------------------------
   -- Calculate the frame rate, and show it on the
   -- 7-segment display
   --------------------------------------------------

   -- At the end of a picture, cnt is the time taken by the picture, and the
   -- frame rate is updated. The frame rate is that of the latest picture, i.e.
   -- the one shown. A picture is only calculated when the view changes, at
   -- most 18 times per second, so an average over many pictures would take
   -- many seconds to follow a change of the view.
   -- cnt wraps around after 2^27 clock cycles (0.71 s at 187.8 MHz), but a
   -- picture takes far less: even if every pixel needed the maximum count,
   -- the model (sim/model.py) gives about 11.2 million clock cycles (60 ms)
   -- on the MEGA65, i.e. a frame rate of about 16, and 8.1 million (67 ms, a
   -- frame rate of about 15) on the Nexys 4 DDR.
   i_fps : entity work.fps
      generic map (
         G_CLK_FREQ  => G_CLK_FREQ,
         G_TIME_BITS => 27,
         G_DIGITS    => 8
      )
      port map (
         clk_i    => clk_i,
         rst_i    => rst_i,
         time_i   => cnt,
         valid_i  => pic_done,
         digits_o => fps_digits,
         blank_o  => fps_blank,
         valid_o  => fps_valid
      ); -- i_fps

   fps_digits_o <= fps_digits;
   fps_blank_o  <= fps_blank;
   fps_valid_o  <= fps_valid;


   --------------------------------------------------
   -- Convert the view of the picture to text
   --------------------------------------------------

   -- view_text.vhd only handles 2.16, so the view is truncated to 2.16, i.e.
   -- the top 18 bits are used. The size of a pixel is at least one LSB of
   -- 2.16. This is only an approximation: the centre is calculated with the
   -- truncated size of a pixel, so it is off by up to G_NUM_COLS/2 LSBs of
   -- 2.16 (about 0.01 for 1280 columns, and 0.005 for 640), and the zoom
   -- shown stops at the initial size of a pixel in LSBs of 2.16 (136.00x for
   -- 1280 columns, and 273.00x for 640), although the view can be zoomed in
   -- 2^17 times further.
   txt_startx <= startx(34 downto 17);
   txt_starty <= starty(34 downto 17);
   txt_stepx  <= stepx(34 downto 17) when stepx(34 downto 17) /= 0 else
                 to_slv(1, 18);
   txt_stepy  <= stepy(34 downto 17) when stepy(34 downto 17) /= 0 else
                 to_slv(1, 18);

   -- The dispatcher takes the view when it sees the start, so the text is of
   -- the same view.
   i_view_text : entity work.view_text
      generic map (
         G_NUM_COLS  => G_NUM_COLS,
         G_NUM_ROWS  => G_NUM_ROWS,
         G_INIT_STEP => C_INIT_STEP
      )
      port map (
         clk_i    => clk_i,
         rst_i    => rst_i,
         start_i  => start,
         startx_i => txt_startx,
         starty_i => txt_starty,
         stepx_i  => txt_stepx,
         stepy_i  => txt_stepy,
         text_o   => view_text,
         valid_o  => open
      ); -- i_view_text

   p_view_text : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if fps_valid = '1' then
            view_text_r <= view_text;
         end if;

         if rst_i = '1' then
            view_text_r <= (others => '1');
         end if;
      end if;
   end process p_view_text;

   view_text_o <= view_text_r;

   i_seg : entity work.seg
      port map (
         clk_i    => clk_i,
         digits_i => fps_digits,
         blank_i  => fps_blank,
         seg_o    => seg_o,
         seg_an_o => seg_an_o
      ); -- i_seg


   --------------------------------------------------
   -- Instantiate job dispatcher
   --------------------------------------------------

   i_dispatcher : entity work.dispatcher
      generic map (
         G_MAX_COUNT     => G_MAX_COUNT,
         G_NUM_ROWS      => G_NUM_ROWS,
         G_NUM_COLS      => G_NUM_COLS,
         G_COL_STRIDE    => G_COL_STRIDE,
         G_ADDR_BITS     => G_ADDR_BITS,
         G_ROWS_IN_JOB   => G_ROWS_IN_JOB,
         G_NUM_ITERATORS => G_NUM_ITERATORS,
         G_PIXELS        => G_PIXELS
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         start_i   => start,
         startx_i  => startx,
         starty_i  => starty,
         stepx_i   => stepx,
         stepy_i   => stepy,
         wr_addr_o => wr_addr_s,
         wr_data_o => wr_data_s,
         wr_en_o   => wr_en_s,
         done_o    => done
      ); -- i_dispatcher


   --------------------------
   -- Connect output signals
   --------------------------

   -- The display memory holds a 9-bit value for each pixel, see
   -- palette_pkg.vhd.
   wr_addr_o <= wr_addr_s;
   wr_data_o <= wr_data_s;
   wr_en_o   <= wr_en_s;

end architecture structural;
