-- This is the design for the MEGA65. It is used by the top level modules of
-- the board revisions R3 (mega65_r3.vhd) and R6 (mega65_r6.vhd), which have
-- the same FPGA. Its ports are the reset and the pins that are the same on
-- both revisions. The top level modules connect them to the pins of the FPGA,
-- and handle the pins that only one of the revisions has.
--
-- The design calculates the Mandelbrot set, and shows it on the VGA and the
-- HDMI output (1280x1024 @ 60 Hz). The picture is calculated by the
-- dispatcher and stored in the display memory. A new picture is only
-- calculated when the view changes (see main.vhd), so the design uses little
-- power when the view is not changed.
--
-- The part that is the same on all the boards is in core.vhd (the MAIN clock
-- domain, the display memory, and the VGA clock domain). This module holds the
-- constants of the MEGA65 and instantiates the clock and reset generation,
-- core, and what is specific to the MEGA65: the keyboard, the joysticks, the
-- video DAC, and the HDMI output. The same design, only smaller, also runs on
-- the Nexys 4 DDR board, see nexys4ddr.vhd.
--
-- The numbers are in 2.33 fixed point format, and the maximum count is 1023.
-- The iterators (iterator_wide.vhd) use six DSPs each, and calculate four
-- rows at the same time.
--
-- The ports of the MEGA65:
-- * The view is controlled by the joysticks and the keyboard: The directions
--   of joystick port 1 (fa_*) and the cursor keys pan the view. The fire
--   button of port 1 and the "+" key zoom in, and the fire button of port 2
--   (fb_*) and the "-" key zoom out. They are mapped to the inputs btn_i and
--   sw_i of main.vhd, which are the buttons and switches on the Nexys 4 DDR,
--   by controls.vhd. The keyboard is read by the MiSTer2MEGA65 keyboard
--   driver (m2m_keyb.vhd, in src/keyboard/), in the MAIN clock domain. It also
--   turns on the power LED of the keyboard (green).
-- * The keys "1" to "4" select the palettes 1 to 4 (see palette_pkg.vhd).
--   controls.vhd stores the palette in switches 0 and 1, which are used by
--   vga.vhd, as on the Nexys 4 DDR.
-- * The space bar toggles the movement of the palette (see disp.vhd).
--   controls.vhd stores it in switch 3, which is used by vga.vhd, as on the
--   Nexys 4 DDR.
-- * There is no 7-segment display, so the frame rate is only shown on the VGA
--   and the HDMI output.
-- * The VGA output goes through a video DAC with 8 bits per colour. The DAC
--   needs a clock, which is the VGA clock inverted, so the DAC samples the
--   pixel colour in the middle of each pixel. The colour and the sync signals
--   are registered in the IOBs, so they all change at the same time, half a
--   clock cycle (4.6 ns) before the DAC samples them.
-- * The same picture is also output on the HDMI connector, in DVI mode (i.e.
--   without audio and InfoFrames), because 1280x1024 is not a CEA-861 video
--   mode. vga_to_hdmi.vhd encodes the picture to TMDS symbols, and the
--   serialisers output them with the TMDS clock (5 * 108 = 540 MHz, on both
--   edges).
--
-- The frame rate and the view are moved to the VGA clock domain in core.vhd.
-- The constraints for this are in mega65-r3.xdc and mega65-r6.xdc.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;

library unisim;
use unisim.vcomponents.all;

use work.video_pkg.all;
use work.types_pkg.all;

entity mega65 is
   port (
      clk_i          : in  std_logic;                      -- 100 MHz
      rstn_i         : in  std_logic;                      -- Active low

      -- Joystick ports, active low
      fa_up_n_i      : in  std_logic;
      fa_down_n_i    : in  std_logic;
      fa_left_n_i    : in  std_logic;
      fa_right_n_i   : in  std_logic;
      fa_fire_n_i    : in  std_logic;
      fb_fire_n_i    : in  std_logic;

      -- MEGA65 keyboard
      kb_io0_o       : out std_logic;                      -- Clock to keyboard
      kb_io1_o       : out std_logic;                      -- Data to keyboard
      kb_io2_i       : in  std_logic;                      -- Data from keyboard

      -- VGA via the video DAC
      vga_red_o      : out std_logic_vector(7 downto 0);
      vga_green_o    : out std_logic_vector(7 downto 0);
      vga_blue_o     : out std_logic_vector(7 downto 0);
      vga_hs_o       : out std_logic;
      vga_vs_o       : out std_logic;
      vdac_clk_o     : out std_logic;
      vdac_sync_n_o  : out std_logic;
      vdac_blank_n_o : out std_logic;

      -- HDMI
      tmds_data_p_o  : out std_logic_vector(2 downto 0);
      tmds_data_n_o  : out std_logic_vector(2 downto 0);
      tmds_clk_p_o   : out std_logic;
      tmds_clk_n_o   : out std_logic
   );
end entity mega65;

architecture structural of mega65 is

   -- The number of job modules. Each of them uses six DSPs (see
   -- iterator_wide.vhd), in two cascades of three, and the XC7A200T has 740.
   -- The two cascades of an iterator are placed next to each other, in a
   -- column of six DSPs (see mandelbrot.tcl). The DSPs of the XC7A200T are in
   -- five columns of 100 and four columns of 60, which have room for
   -- 5*16 + 4*10 = 120 iterators (720 DSPs). Each job module has its own
   -- region next to its DSPs, see mega65_floorplan.tcl, which is written for
   -- 120 job modules.
   constant C_NUM_ITERATORS : positive := 120;

   -- The maximum count (see main.vhd and job_wide.vhd). The numbers are in
   -- 2.33 fixed point format, with iterator_wide.vhd.
   constant C_MAX_COUNT     : positive := 1023;

   -- The number of pixels in each write to the display memory. The dispatcher
   -- accepts at most one result per clock cycle, so with one pixel in each
   -- write the picture would take at least 1280*1024 clock cycles (7.28 ms).
   -- The wide iterator calculates the four rows of a result at the same time,
   -- so this must be 4. The model (sim/model.py) estimates 1.10 million clock
   -- cycles for the initial picture (5.75 ms, i.e. 174 pictures per second),
   -- and about 11.2 million (58 ms, 17 pictures per second) if every pixel
   -- needed the maximum count.
   constant C_PIXELS        : positive := 4;

   -- The VCO of the MMCM (see clk_rst.vhd): 100 MHz / 5 * 54 = 1080 MHz. This
   -- is the only VCO frequency which gives the pixel clock of 108 MHz exactly.
   constant C_VCO_DIVIDE    : positive := 5;
   constant C_VCO_MULT      : real    := 54.0;

   -- The video mode (see video_pkg.vhd), and the divider of the VGA clock,
   -- which gives the pixel clock (1080 MHz / 10 = 108 MHz, see clk_rst.vhd).
   constant C_VIDEO         : video_mode_t := C_VIDEO_1280X1024;
   constant C_VGA_DIVIDE    : positive := 10;

   -- The divider of the TMDS clock of the HDMI output, which must be five
   -- times the pixel clock (1080 MHz / 2 = 540 MHz, see clk_rst.vhd).
   constant C_TMDS_DIVIDE   : positive := C_VGA_DIVIDE / 5;

   -- The divider of the MAIN clock (see clk_rst.vhd), and its frequency in Hz.
   -- 1080 MHz / 5.625 = 192 MHz. The iterators (see iterator_wide.vhd) are
   -- pipelined, so their paths are short, but the timing is only met with the
   -- floorplan of the job modules (mega65_floorplan.tcl), which keeps the
   -- logic of each iterator next to its DSPs. The main clock can not go much
   -- higher: 196.4 MHz (5.5) met timing with +0.014 ns, but at 200.9 MHz the
   -- keyboard driver (src/keyboard) fails, and at 205.7 MHz the cascade of
   -- the DSPs in the iterators.
   constant C_MAIN_DIVIDE   : real    := 5.625;
   constant C_MAIN_FREQ     : natural :=
      natural(100.0E6 / real(C_VCO_DIVIDE) * C_VCO_MULT / C_MAIN_DIVIDE);

   -- Rows in each job given to a job module, see dispatcher.vhd. The
   -- number of rows (1024) must be a multiple of it, and of C_PIXELS. The
   -- model gives 172 to 175 pictures per second for 32 to 256 rows.
   constant C_ROWS_IN_JOB   : positive := 64;

   -- The address distance between two picture columns in the display memory,
   -- see dispatcher.vhd. 1024 rows per column means the address is the column
   -- (11 bits) followed by the row (10 bits).
   constant C_COL_STRIDE    : positive := 1024;

   -- The display memory (see disp_mem.vhd): 1280*1024 pixels, i.e. 320 blocks
   -- (BRAMs) of 4096 pixels, with 21 bits of address. The XC7A200T has 365
   -- BRAMs. Without a register for the write port of each block, the register
   -- of each group of 8 blocks drives their BRAMs directly. This saves about
   -- 15,000 registers, which made the slices too full for the 450 job modules
   -- of an earlier version (92% used, and the MAIN clock failed timing).
   constant C_ADDR_BITS     : positive := 21;
   constant C_MEM_BLOCKS    : positive := 320;
   constant C_BLOCK_REGS    : boolean := false;

   signal btn            : std_logic_vector( 4 downto 0);  -- "CLRUD"
   signal sw             : std_logic_vector( 7 downto 0);

   signal main_clk       : std_logic;
   signal main_rst       : std_logic;

   -- The keyboard driver cycles through all the keys (key_num), and shows
   -- whether each of them is pressed (key_pressed_n, active low), see
   -- controls.vhd.
   signal key_num        : natural range 0 to 79;
   signal key_pressed_n  : std_logic;

   signal vga_clk        : std_logic;
   signal vga_rst        : std_logic;

   signal tmds_clk       : std_logic;

   signal vga_hs         : std_logic;
   signal vga_vs         : std_logic;
   signal vga_de         : std_logic;
   signal vga_col        : std_logic_vector( 7 downto 0);  -- RRRGGGBB

   -- The colour expanded to 8 bits per colour, for the DAC and for HDMI
   signal vga_red        : std_logic_vector( 7 downto 0);
   signal vga_green      : std_logic_vector( 7 downto 0);
   signal vga_blue       : std_logic_vector( 7 downto 0);

   -- The sync signals, active high, for vga_to_hdmi
   signal hdmi_hs        : std_logic;
   signal hdmi_vs        : std_logic;

   -- The TMDS symbols of the three HDMI data channels
   signal hdmi_tmds      : slv_9_0_t(0 to 2);

   -- The registers of the outputs to the DAC and the VGA connector. Several of
   -- the colour registers are identical, so the attribute keep prevents the
   -- synthesis tool from merging them, and the attribute IOB places them in
   -- the IOBs.
   signal vdac_red_r     : std_logic_vector( 7 downto 0);
   signal vdac_green_r   : std_logic_vector( 7 downto 0);
   signal vdac_blue_r    : std_logic_vector( 7 downto 0);
   signal vdac_hs_r      : std_logic;
   signal vdac_vs_r      : std_logic;

   attribute keep : string;
   attribute keep of vdac_red_r   : signal is "true";
   attribute keep of vdac_green_r : signal is "true";
   attribute keep of vdac_blue_r  : signal is "true";

   attribute iob : string;
   attribute iob of vdac_red_r   : signal is "true";
   attribute iob of vdac_green_r : signal is "true";
   attribute iob of vdac_blue_r  : signal is "true";
   attribute iob of vdac_hs_r    : signal is "true";
   attribute iob of vdac_vs_r    : signal is "true";

begin

   --------------------------------------------------
   -- Instantiate the keyboard driver
   --------------------------------------------------

   i_m2m_keyb : entity work.m2m_keyb
      port map (
         clk_main_i       => main_clk,
         clk_main_speed_i => C_MAIN_FREQ,
         kio8_o           => kb_io0_o,
         kio9_o           => kb_io1_o,
         kio10_i          => kb_io2_i,
         enable_core_i    => '1',
         key_num_o        => key_num,
         key_pressed_n_o  => key_pressed_n,
         power_led_i      => '1',
         power_led_col_i  => X"00FF00",         -- Green
         drive_led_i      => '0',
         drive_led_col_i  => X"000000",
         qnice_keys_n_o   => open
      ); -- i_m2m_keyb


   --------------------------------------------------
   -- Map the joysticks and keys to the buttons and switches
   --------------------------------------------------

   i_controls : entity work.controls
      port map (
         clk_i           => main_clk,
         key_num_i       => key_num,
         key_pressed_n_i => key_pressed_n,
         fa_up_n_i       => fa_up_n_i,
         fa_down_n_i     => fa_down_n_i,
         fa_left_n_i     => fa_left_n_i,
         fa_right_n_i    => fa_right_n_i,
         fa_fire_n_i     => fa_fire_n_i,
         fb_fire_n_i     => fb_fire_n_i,
         btn_o           => btn,
         sw_o            => sw
      ); -- i_controls


   --------------------------------------------------
   -- Instantiate clock and reset generation
   --------------------------------------------------

   i_clk_rst : entity work.clk_rst
      generic map (
         G_VCO_DIVIDE  => C_VCO_DIVIDE,
         G_VCO_MULT    => C_VCO_MULT,
         G_MAIN_DIVIDE => C_MAIN_DIVIDE,
         G_VGA_DIVIDE  => C_VGA_DIVIDE,
         G_TMDS_DIVIDE => C_TMDS_DIVIDE
      )
      port map (
         clk_i      => clk_i,
         rstn_i     => rstn_i,
         main_clk_o => main_clk,
         main_rst_o => main_rst,
         vga_clk_o  => vga_clk,
         vga_rst_o  => vga_rst,
         tmds_clk_o => tmds_clk
      ); -- i_clk_rst


   --------------------------------------------------
   -- Instantiate the design
   --------------------------------------------------

   i_core : entity work.core
      generic map (
         G_CLK_FREQ      => C_MAIN_FREQ,
         G_NUM_ITERATORS => C_NUM_ITERATORS,
         G_PIXELS        => C_PIXELS,
         G_ROWS_IN_JOB   => C_ROWS_IN_JOB,
         G_VIDEO         => C_VIDEO,
         G_COL_STRIDE    => C_COL_STRIDE,
         G_ADDR_BITS     => C_ADDR_BITS,
         G_MEM_BLOCKS    => C_MEM_BLOCKS,
         G_BLOCK_REGS    => C_BLOCK_REGS,
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


   --------------------------------------------------
   -- Video DAC
   --------------------------------------------------

   -- Expand each colour to 8 bits by repeating the bits, so that the full
   -- range is used (e.g. "111" becomes "11111111").
   vga_red   <= vga_col(7 downto 5) & vga_col(7 downto 5) & vga_col(7 downto 6);
   vga_green <= vga_col(4 downto 2) & vga_col(4 downto 2) & vga_col(4 downto 3);
   vga_blue  <= vga_col(1 downto 0) & vga_col(1 downto 0) & vga_col(1 downto 0) & vga_col(1 downto 0);

   -- The outputs are registered, with one register in the IOB of each output,
   -- so that they all change at the same time.
   p_vdac : process (vga_clk)
   begin
      if rising_edge(vga_clk) then
         vdac_red_r   <= vga_red;
         vdac_green_r <= vga_green;
         vdac_blue_r  <= vga_blue;
         vdac_hs_r    <= vga_hs;
         vdac_vs_r    <= vga_vs;
      end if;
   end process p_vdac;

   vga_red_o   <= vdac_red_r;
   vga_green_o <= vdac_green_r;
   vga_blue_o  <= vdac_blue_r;
   vga_hs_o    <= vdac_hs_r;
   vga_vs_o    <= vdac_vs_r;

   -- The DAC samples the colour on the rising edge of its clock. The clock is
   -- low in the first half of the VGA clock cycle and high in the second half,
   -- i.e. the VGA clock inverted.
   i_vdac_clk : ODDR
      generic map (
         DDR_CLK_EDGE => "SAME_EDGE",
         INIT         => '0',
         SRTYPE       => "SYNC"
      )
      port map (
         Q  => vdac_clk_o,
         C  => vga_clk,
         CE => '1',
         D1 => '0',
         D2 => '1',
         R  => '0',
         S  => '0'
      ); -- i_vdac_clk

   vdac_sync_n_o  <= '0';  -- No sync on green
   vdac_blank_n_o <= '1';  -- The colour is black outside the visible area


   --------------------------------------------------
   -- HDMI
   --------------------------------------------------

   -- vga_to_hdmi expects active high sync signals, and outputs them with the
   -- polarity given by hs_pol and vs_pol.
   hdmi_hs <= vga_hs xnor C_VIDEO.sync_active;
   hdmi_vs <= vga_vs xnor C_VIDEO.sync_active;

   -- Encode the picture to TMDS symbols. DVI mode is used, so there are no
   -- data islands (audio and InfoFrames), and the VIC, the aspect ratio, the
   -- pixel repetition, and the audio inputs are not used.
   i_vga_to_hdmi : entity work.vga_to_hdmi
      port map (
         select_44100 => '0',
         dvi          => '1',
         vic          => X"00", -- Not a CEA-861 video mode
         aspect       => "00",  -- No data
         pix_rep      => '0',
         vs_pol       => C_VIDEO.sync_active,
         hs_pol       => C_VIDEO.sync_active,
         vga_rst      => vga_rst,
         vga_clk      => vga_clk,
         vga_vs       => hdmi_vs,
         vga_hs       => hdmi_hs,
         vga_de       => vga_de,
         vga_r        => vga_red,
         vga_g        => vga_green,
         vga_b        => vga_blue,
         pcm_rst      => vga_rst,
         pcm_clk      => vga_clk,
         pcm_clken    => '0',
         pcm_l        => (others => '0'),
         pcm_r        => (others => '0'),
         pcm_acr      => '0',
         pcm_n        => (others => '0'),
         pcm_cts      => (others => '0'),
         tmds         => hdmi_tmds
      ); -- i_vga_to_hdmi

   -- Serialise the three data channels, ten bits in each VGA clock cycle
   gen_hdmi_data : for i in 0 to 2 generate
      i_hdmi_data : entity work.serialiser_10to1_selectio
         port map (
            rst    => vga_rst,
            clk    => vga_clk,
            clk_x5 => tmds_clk,
            d      => hdmi_tmds(i),
            out_p  => tmds_data_p_o(i),
            out_n  => tmds_data_n_o(i)
         ); -- i_hdmi_data
   end generate gen_hdmi_data;

   -- The HDMI clock is the VGA clock, i.e. five ones and five zeros in each
   -- VGA clock cycle.
   i_hdmi_clk : entity work.serialiser_10to1_selectio
      port map (
         rst    => vga_rst,
         clk    => vga_clk,
         clk_x5 => tmds_clk,
         d      => "0000011111",
         out_p  => tmds_clk_p_o,
         out_n  => tmds_clk_n_o
      ); -- i_hdmi_clk

end architecture structural;
