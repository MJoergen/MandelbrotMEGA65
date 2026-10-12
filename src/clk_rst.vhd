-- This module generates the clocks and the resets of the design.
--
-- It started as the output of the Xilinx Clocking Wizard
-- (clk_wiz_0_clk_wiz.vhd), and has since been rewritten by hand: the Ethernet
-- clock has been removed, the frequencies are set by generics, the reset
-- generation has been added, and the code follows the coding style of this
-- repository.
--
-- The MMCM divides the 100 MHz input clock by G_VCO_DIVIDE and multiplies it
-- by G_VCO_MULT, which gives the VCO frequency, and generates the following
-- output clocks from the VCO:
--
--   Output clock   Output    Divider         Freq (MHz)
--   vga_clk        CLKOUT1   G_VGA_DIVIDE    VCO/G_VGA_DIVIDE
--   main_clk       CLKOUT0   G_MAIN_DIVIDE   VCO/G_MAIN_DIVIDE
--   tmds_clk       CLKOUT2   G_TMDS_DIVIDE   VCO/G_TMDS_DIVIDE
--
-- All of these are set by the top level module:
-- * MEGA65: The VCO is 100 MHz / 5 * 54 = 1080 MHz (speed grade -2 allows up
--   to 1440 MHz), the only VCO frequency which gives the 108 MHz pixel clock
--   of 1280x1024 exactly. The VGA clock is 1080/10 = 108 MHz, and the main
--   clock is 1080/7.625 = 141.64 MHz. The TMDS clock of the HDMI output is
--   1080/2 = 540 MHz, i.e. five times the VGA clock, because the HDMI
--   serialisers output ten bits in each VGA clock cycle on both edges of the
--   TMDS clock (see serialiser_10to1_selectio.vhd).
-- * Nexys 4 DDR: The VCO is 100 MHz * 12 = 1200 MHz (the maximum for speed
--   grade -1). The VGA clock is 1200/48 = 25 MHz (640x480), and the main clock
--   is 1200/10 = 120 MHz.
-- The Nexys 4 DDR has no HDMI output, so the TMDS clock is not used there.
-- The main clock uses CLKOUT0, because it is the only output with a
-- fractional divider (in steps of 0.125).
--
-- Input clock: clk_i, 100.000 MHz.
--
-- Each output clock has a corresponding reset, which is synchronous to that
-- clock. The design is held in reset while the reset button is pressed
-- (rstn_i low), and while the MMCM is not locked. This signal is
-- asynchronous, so it is first synchronized to each clock domain (two
-- registers), and the reset is then stretched to eight clock cycles after it
-- is released.

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity clk_rst is
   generic (
      G_VCO_DIVIDE  : positive;     -- The VCO is 100 MHz / G_VCO_DIVIDE * G_VCO_MULT
      G_VCO_MULT    : real;
      G_MAIN_DIVIDE : real;         -- The main clock is VCO / G_MAIN_DIVIDE
      G_VGA_DIVIDE  : positive;     -- The VGA clock is VCO / G_VGA_DIVIDE
      G_TMDS_DIVIDE : positive := 2 -- The TMDS clock is VCO / G_TMDS_DIVIDE
   );
   port (
      clk_i      : in  std_logic;  -- 100 MHz
      rstn_i     : in  std_logic;  -- Asynchronous, active low

      main_clk_o : out std_logic;  -- VCO / G_MAIN_DIVIDE
      main_rst_o : out std_logic;  -- Synchronous to main_clk_o

      vga_clk_o  : out std_logic;  -- VCO / G_VGA_DIVIDE
      vga_rst_o  : out std_logic;  -- Synchronous to vga_clk_o

      tmds_clk_o : out std_logic   -- VCO / G_TMDS_DIVIDE
   );
end entity clk_rst;

architecture structural of clk_rst is

   signal clkfb_mmcm     : std_logic;
   signal clkfb          : std_logic;
   signal main_clk_mmcm  : std_logic;
   signal vga_clk_mmcm   : std_logic;
   signal tmds_clk_mmcm  : std_logic;
   signal locked         : std_logic;
   signal rstn           : std_logic;

   -- The resets are high from the configuration of the FPGA until the
   -- reset has been stretched, also in the first clock cycle.
   signal main_clk       : std_logic;
   signal main_rstn_sync : std_logic_vector(1 downto 0) := "00";
   signal main_rst_delay : std_logic_vector(7 downto 0) := X"FF";
   signal main_rst_r     : std_logic := '1';

   signal vga_clk        : std_logic;
   signal vga_rstn_sync  : std_logic_vector(1 downto 0) := "00";
   signal vga_rst_delay  : std_logic_vector(7 downto 0) := X"FF";
   signal vga_rst_r      : std_logic := '1';

   -- The registers of the reset synchronizers
   attribute async_reg : string;
   attribute async_reg of main_rstn_sync : signal is "true";
   attribute async_reg of vga_rstn_sync  : signal is "true";

begin

   --------------------------------------------------
   -- Instantiate the MMCM
   --------------------------------------------------

   -- Unused outputs are left unconnected, and unused inputs are tied off.
   -- The reset of the MMCM (RST) is tied off too: the MMCM starts when the
   -- FPGA is configured, and the 100 MHz input clock of the boards runs all
   -- the time. If the input clock stopped and came back, the MMCM would not
   -- be reset, and might not lock again. The design is held in reset while
   -- the MMCM is not locked, see below.
   i_mmcm_adv : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         DIVCLK_DIVIDE        => G_VCO_DIVIDE,
         CLKFBOUT_MULT_F      => G_VCO_MULT,
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => G_MAIN_DIVIDE, -- MAIN
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => G_VGA_DIVIDE,  -- VGA
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_USE_FINE_PS  => FALSE,
         CLKOUT2_DIVIDE       => G_TMDS_DIVIDE, -- TMDS
         CLKOUT2_PHASE        => 0.000,
         CLKOUT2_DUTY_CYCLE   => 0.500,
         CLKOUT2_USE_FINE_PS  => FALSE,
         CLKIN1_PERIOD        => 10.0,
         REF_JITTER1          => 0.010
      )
      port map (
         CLKFBOUT => clkfb_mmcm,
         CLKOUT0  => main_clk_mmcm,
         CLKOUT1  => vga_clk_mmcm,
         CLKOUT2  => tmds_clk_mmcm,
         CLKFBIN  => clkfb,
         CLKIN1   => clk_i,
         CLKIN2   => '0',
         CLKINSEL => '1', -- Select CLKIN1
         DADDR    => (others => '0'),
         DCLK     => '0',
         DEN      => '0',
         DI       => (others => '0'),
         DWE      => '0',
         PSCLK    => '0',
         PSEN     => '0',
         PSINCDEC => '0',
         LOCKED   => locked,
         PWRDWN   => '0',
         RST      => '0'
      ); -- i_mmcm_adv

   i_clkfb_buf : BUFG
      port map (
         I => clkfb_mmcm,
         O => clkfb
      ); -- i_clkfb_buf

   i_main_clk_buf : BUFG
      port map (
         I => main_clk_mmcm,
         O => main_clk
      ); -- i_main_clk_buf

   i_vga_clk_buf : BUFG
      port map (
         I => vga_clk_mmcm,
         O => vga_clk
      ); -- i_vga_clk_buf

   i_tmds_clk_buf : BUFG
      port map (
         I => tmds_clk_mmcm,
         O => tmds_clk_o
      ); -- i_tmds_clk_buf


   --------------------------------------------------
   -- Generate reset signals
   --------------------------------------------------

   -- The design is held in reset while the reset button is pressed, and while
   -- the MMCM is not locked. This signal is asynchronous, so it is first
   -- synchronized to each clock domain (two registers), and the reset is then
   -- stretched to eight clock cycles after it is released.
   rstn <= rstn_i and locked;

   p_main_rst : process (main_clk)
   begin
      if rising_edge(main_clk) then
         main_rstn_sync <= main_rstn_sync(0) & rstn;

         main_rst_delay <= main_rst_delay(6 downto 0) & "0";
         main_rst_r     <= main_rst_delay(7);

         if main_rstn_sync(1) = '0' then
            main_rst_delay <= X"FF";
         end if;
      end if;
   end process p_main_rst;

   p_vga_rst : process (vga_clk)
   begin
      if rising_edge(vga_clk) then
         vga_rstn_sync <= vga_rstn_sync(0) & rstn;

         vga_rst_delay <= vga_rst_delay(6 downto 0) & "0";
         vga_rst_r     <= vga_rst_delay(7);

         if vga_rstn_sync(1) = '0' then
            vga_rst_delay <= X"FF";
         end if;
      end if;
   end process p_vga_rst;

   main_clk_o <= main_clk;
   main_rst_o <= main_rst_r;
   vga_clk_o  <= vga_clk;
   vga_rst_o  <= vga_rst_r;

end architecture structural;
