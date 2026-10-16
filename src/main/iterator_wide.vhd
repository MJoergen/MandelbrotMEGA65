---------------------------
-- This module iterates the Mandelbrot fractal equation
--    new_z = z^2 + c
-- for four points at the same time, with numbers in 2.33 fixed point format
-- (35 bits). It is the iterator of the job modules, see job_wide.vhd.
--
-- The four points are four consecutive columns of a picture row: they have
-- cx, cx+stepx, cx+2*stepx, and cx+3*stepx, and the same cy. Inputs to this
-- block are cx_i, cy_i, and stepx_i, as well as start_i. start_i should be
-- pulsed for one clock cycle. cx_i, cy_i, and stepx_i must remain constant
-- until the iteration is finished. stepx_i is registered (stepx_r) before it
-- is added to cx, so it must be stable one clock cycle before start_i. On
-- output, done_o goes high when all four points are finished, with the
-- iteration count of each point in cnt_o (the first point in the lowest
-- bits). Both stay unchanged until the next start_i. The count is the number of the first iteration where x or y is
-- out of range (see below), or G_MAX_COUNT if this does not happen.
--
-- Separating real and imaginary parts, each iteration is:
--    new_x = (x+y)*(x-y) + cx
--    new_y = 2*x*y + cy
-- These are two multiplications. A multiplication of 35-bit numbers needs
-- several DSPs, which have a 25x18 bit multiplier. The numbers are split into
-- a high part and a low part of 17 bits (unsigned), e.g. a = ah*2^17 + al, and
-- then
--    a*b = ah*bh*2^34 + (ah*bl + al*bh)*2^17 + al*bl.
-- The last product (al*bl, less than 2^34) is left out, so each
-- multiplication needs three DSPs, which are cascaded (see p_dsp below), and
-- the iterator uses six DSPs. Without the last product, the new values are
-- slightly too small, by up to 2 LSB for x and 4 LSB for y (y is twice the
-- product). Half an LSB of the result is added to each product, which
-- compensates for part of this, but keeps the values exact when the low parts
-- are zero, e.g. new_x = 0 when x = y = 0 and cx = 0, and new_y = cy when
-- y = 0. So the new values are (in units of
-- 2^-33, where al and bl are the lowest 17 bits of x+y and x-y, and xl and yl
-- those of x and y)
--    new_x = floor(((x+y)*(x-y) - al*bl + 2^32) / 2^33) + cx
--    new_y = floor((x*y - xl*yl + 2^31) / 2^32) + cy.
-- This is the bit-accurate model in sim/model.py and
-- sim/iterator_model_pkg.vhd. The values do not depend on which of x+y and
-- x-y is called a (see below), because the formula is symmetric in a and b.
--
-- The iteration is pipelined, and takes four clock cycles (see p_dsp):
--   1. x+y and x-y are calculated in the FPGA fabric, and registered in the
--      DSPs (the registers A and B).
--   2. The first two DSPs of each multiplication calculate ah*bl + al*bh,
--      with the cascade from the first to the second one, and the result is
--      registered in the second DSP (the register P). The third DSP
--      calculates ah*bh, and registers it (the register M).
--   3. The third DSP calculates (the result of step 2)/2^17 + ah*bh, with the
--      cascade (shifted by 17 bits) from the second DSP, and registers it
--      (the register P).
--   4. The constants cx and cy (and half an LSB, see p_dsp) are added in the
--      FPGA fabric, and the new values of x and y are registered (x_r and
--      y_r), with the overflow check.
-- In each clock cycle, each stage works on a different point. So the four
-- points are calculated in turns, one iteration of each point in every four
-- clock cycles, and the iterator calculates one iteration in every clock
-- cycle. The point in x_r and y_r is called the slot
-- (sl_r): the four slots are 0, 1, 2, 3, 0, 1, ... in consecutive clock
-- cycles, and each slot has its own value of cx, its own saved values for the
-- periodicity detection, and its own count. All four points have done the
-- same number of iterations (it_r) when they are in x_r and y_r.
--
-- At the start, x_r and y_r are cleared in the first four clock cycles, i.e.
-- x = y = 0 for each slot, and the values of cx of the four slots are
-- calculated (cx_acc_r). Then the next values are calculated in every clock
-- cycle, until all four points are finished (the values of the points that
-- are finished first are not used then). A point that stops after n
-- iterations is done after 4n+2 clock cycles (counted from the start), plus
-- the slot, and done_o is high from one clock cycle after the last of the
-- four points is done.
--
-- After that, x_r and y_r, the values of cx, and the saved values of the
-- periodicity detection keep their value until the next start (their clock
-- enable is run_r), so the iterator does not toggle while it is idle: the
-- inputs of the DSPs do not change, so their registers stop changing three
-- clock cycles after done_o goes high. Otherwise the iterator would go on
-- iterating, and use as much power as when it calculates. The DSPs themselves have no clock enable, so they are the
-- same as without it.
--
-- Periodicity detection: x and y are saved after
-- iterations 1, 2, 4, 8, 16, ..., and compared with the saved values in each
-- iteration. When they are equal, the iteration of that point stops, with the
-- count G_MAX_COUNT. The saved values of the four slots are in a shift register
-- of four entries (sx_r and sy_r), which moves along with the slots, so the
-- saved values of the slot in x_r and y_r are always in the first entry.
--
-- Overflow: The iteration stops when the new x or y is outside the range -2
-- to 2 (not including 2). The range is checked on the sums, before they are
-- truncated to 35 bits. The new value of x is between -6
-- and 6 (37 bits), and the new value of y between -10 and 10 (38 bits).
--
-- The values x+y and x-y are between -4 and 4, so they need 36 bits (3.33
-- format). The multiplication splits them into a high part of 19 bits and a
-- low part of 17 bits, but the high part of the second input can only have
-- 18 bits (the B input of the DSP). But at most one of x+y and x-y is
-- outside the range -2 to 2: If x and y have the same sign bit, then
-- x-y is in range, and otherwise x+y is in range. So the one that may be out
-- of range is a, and the other one is b, and each of them is calculated by an
-- adder that adds or subtracts y.
--
-- The XC7A200T (MEGA65) has 740 DSPs, so 120 iterators use 720 of them, and
-- the XC7A100T (Nexys 4 DDR) has 240 DSPs in three columns of 80, so 39
-- iterators use 234 of them (a cascade must be in one column).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std_unsigned.all;
use ieee.numeric_std.all;

use work.util_pkg.all;
use work.dispatcher_pkg.all;

entity iterator_wide is
   generic (
      G_MAX_COUNT : positive
   );
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      start_i : in  std_logic;
      cx_i    : in  std_logic_vector(34 downto 0);
      cy_i    : in  std_logic_vector(34 downto 0);
      stepx_i : in  std_logic_vector(34 downto 0);
      cnt_o   : out std_logic_vector(4*log2(G_MAX_COUNT+1)-1 downto 0);
      done_o  : out std_logic
   );
end entity iterator_wide;

architecture rtl of iterator_wide is

   -- The number of bits of a count
   constant C_CNT_BITS : natural := log2(G_MAX_COUNT+1);

   -- The counts of the slots. The values of the slots (cx_r, sx_r, and sy_r)
   -- are of the type value_vector, from dispatcher_pkg.vhd.
   type cnt_vector is array (natural range <>) of
      std_logic_vector(C_CNT_BITS-1 downto 0);

   -- Stage 4: The new values of x and y (2.33) of the slot sl_r, and the
   -- overflow of the new values. These are the values after it_r iterations.
   signal x_r        : std_logic_vector(34 downto 0);
   signal y_r        : std_logic_vector(34 downto 0);
   signal ovf_r      : std_logic;

   -- Stage 1: The inputs of the first multiplication. a_s is x+y or x-y
   -- (3.33), and b_s is the other one (2.33). sub_s is high when a_s is x-y.
   signal sub_s      : std_logic;
   signal a_s        : std_logic_vector(35 downto 0);
   signal b_s        : std_logic_vector(34 downto 0);

   -- The inputs of the six DSPs (the registers A and B). The first, second,
   -- and third DSP calculate (x+y)*(x-y), and the fourth, fifth, and sixth
   -- x*y.
   signal dsp1_a_r   : std_logic_vector(16 downto 0);  -- al
   signal dsp1_b_r   : std_logic_vector(17 downto 0);  -- bh
   signal dsp2_a_r   : std_logic_vector(18 downto 0);  -- ah
   signal dsp2_b_r   : std_logic_vector(16 downto 0);  -- bl
   signal dsp3_a_r   : std_logic_vector(18 downto 0);  -- ah
   signal dsp3_b_r   : std_logic_vector(17 downto 0);  -- bh
   signal dsp4_a_r   : std_logic_vector(16 downto 0);  -- xl
   signal dsp4_b_r   : std_logic_vector(17 downto 0);  -- yh
   signal dsp5_a_r   : std_logic_vector(17 downto 0);  -- xh
   signal dsp5_b_r   : std_logic_vector(16 downto 0);  -- yl
   signal dsp6_a_r   : std_logic_vector(17 downto 0);  -- xh
   signal dsp6_b_r   : std_logic_vector(17 downto 0);  -- yh

   -- Stage 2: The registers P of the second and fifth DSP, and the registers
   -- M of the third and sixth DSP
   signal p2_r       : signed(37 downto 0);
   signal p5_r       : signed(37 downto 0);
   signal m3_r       : signed(36 downto 0);
   signal m6_r       : signed(35 downto 0);

   -- Stage 3: The registers P of the third and sixth DSP, and the bits of
   -- the registers P of the second and fifth DSP that are part of the result
   signal p3_r       : signed(37 downto 0);
   signal p6_r       : signed(37 downto 0);
   signal p2_lo_r    : std_logic_vector(1 downto 0);
   signal p5_lo_r    : std_logic_vector(2 downto 0);

   -- Stage 4: The new values, before they are truncated to 35 bits
   signal new_x_s    : std_logic_vector(36 downto 0);  -- 4.33
   signal new_y_s    : std_logic_vector(37 downto 0);  -- 5.33
   signal ovf_s      : std_logic;

   -- The values of cx of the four slots, and the constant cy. The first entry
   -- of cx_r is the value of cx of the slot in stage 3, which is added in
   -- stage 4.
   signal cx_r       : value_vector(0 to 3)(34 downto 0);
   signal cx_acc_r   : std_logic_vector(34 downto 0);
   signal stepx_r    : std_logic_vector(34 downto 0);
   signal cy_r       : std_logic_vector(34 downto 0);

   -- The start: init_s is high in the clock cycle of the start and the three
   -- after it, when x_r and y_r are cleared.
   signal init_r     : std_logic_vector(2 downto 0) := (others => '0');
   signal init_s     : std_logic;

   -- The slot in x_r and y_r, and the number of iterations of the values in
   -- x_r and y_r. The flags are about it_r: it is a power of two, it is at
   -- least two, and it is the last iteration (G_MAX_COUNT-1).
   signal sl_r       : natural range 0 to 3;
   signal it_r       : std_logic_vector(C_CNT_BITS-1 downto 0) := (others => '0');
   signal it_pow2_r  : std_logic := '0';
   signal it_ge2_r   : std_logic := '0';
   signal it_last_r  : std_logic := '0';

   -- Periodicity detection. The saved values of x and y of the four slots,
   -- with the slot in x_r and y_r first.
   signal sx_r       : value_vector(0 to 3)(34 downto 0);
   signal sy_r       : value_vector(0 to 3)(34 downto 0);
   signal match_s    : std_logic;

   -- The results of the checks of the slot sl_r, one clock cycle later
   signal sl_d       : natural range 0 to 3;
   signal it_d       : std_logic_vector(C_CNT_BITS-1 downto 0);
   signal ovf_d      : std_logic;
   signal match_d    : std_logic;
   signal last_d     : std_logic;

   -- High from the start until all the slots are done. busy_r are the slots
   -- that are still iterating, and cnt_r the count of each slot.
   signal run_r      : std_logic := '0';
   signal busy_r     : std_logic_vector(3 downto 0) := (others => '0');
   signal cnt_r      : cnt_vector(0 to 3) := (others => (others => '0'));
   signal done_r     : std_logic := '0';

begin

   assert G_MAX_COUNT >= 2
      report "The iterator needs G_MAX_COUNT >= 2"
      severity failure;


   ---------------------------------------
   -- Stage 1: The inputs of the first multiplication
   ---------------------------------------

   -- The one of x+y and x-y that may be out of range goes to a_s: x+y when
   -- x and y have the same sign bit, and otherwise x-y. Each of the two is a
   -- single adder, which adds or subtracts y (y xor sub, plus sub), so each
   -- bit needs only one LUT.
   sub_s <= x_r(34) xor y_r(34);
   a_s   <= (x_r(34) & x_r) + ((y_r(34) & y_r) xor (35 downto 0 => sub_s)) + sub_s;
   b_s   <= x_r + (y_r xor (34 downto 0 => not sub_s)) + (not sub_s);


   ----------------------------------------------------
   -- The DSPs: Three cascaded DSPs for each multiplication
   ----------------------------------------------------

   -- These are inferred as six DSP48E1. In each multiplication, the first DSP
   -- calculates a product, without registering it (no registers M and P),
   -- and passes it on through the cascade (PCOUT) to the second DSP, which
   -- adds its own product and registers the sum (P). The third DSP registers
   -- its product (M), and adds it to the sum shifted 17 bits to the right (the
   -- cascade input PCIN>>17), and registers it (P). The inputs of the DSPs are
   -- registered in the DSPs (A and B). The products are less than 2^35, and
   -- the sums less than 2^36, so they fit in 38 bits.
   --
   -- The register M of the third DSP is written explicitly. It used to be a
   -- second register of the inputs of the third DSP, which the synthesis tool
   -- moves to M. In the full MEGA65 design (but not when iterator_wide is
   -- synthesized alone), Vivado 2025.1 did this right for x*y, but for
   -- (x+y)*(x-y) it took the input A from the second DSP through the cascade
   -- ACOUT, without the second register (AREG = 0, MREG = 0), so ah was from
   -- the wrong slot. mandelbrot.tcl checks this.
   --
   -- Half an LSB of the result, i.e. 2^15 units of the register P of the
   -- second DSP for x (2^14 for y), is not added in the DSPs (a constant in
   -- the first DSP, in its input C, prevents the synthesis tool from using
   -- the cascade), but in stage 4, which gives the same result: bits 16 and
   -- 15 of the register P are the only ones that decide whether adding 2^15
   -- changes the result, and it adds 1 when one of them is high and 2 when
   -- both are (bit 15 is added as the carry into the adder in stage 4).
   p_dsp : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- Stage 1
         dsp1_a_r <= a_s(16 downto 0);
         dsp1_b_r <= b_s(34 downto 17);
         dsp2_a_r <= a_s(35 downto 17);
         dsp2_b_r <= b_s(16 downto 0);
         dsp3_a_r <= a_s(35 downto 17);
         dsp3_b_r <= b_s(34 downto 17);
         dsp4_a_r <= x_r(16 downto 0);
         dsp4_b_r <= y_r(34 downto 17);
         dsp5_a_r <= x_r(34 downto 17);
         dsp5_b_r <= y_r(16 downto 0);
         dsp6_a_r <= x_r(34 downto 17);
         dsp6_b_r <= y_r(34 downto 17);

         -- Stage 2
         p2_r <= resize(signed('0' & dsp1_a_r) * signed(dsp1_b_r), 38) +
                 resize(signed(dsp2_a_r) * signed('0' & dsp2_b_r), 38);
         p5_r <= resize(signed('0' & dsp4_a_r) * signed(dsp4_b_r), 38) +
                 resize(signed(dsp5_a_r) * signed('0' & dsp5_b_r), 38);
         m3_r <= signed(dsp3_a_r) * signed(dsp3_b_r);
         m6_r <= signed(dsp6_a_r) * signed(dsp6_b_r);

         -- Stage 3
         p3_r    <= shift_right(p2_r, 17) + resize(m3_r, 38);
         p6_r    <= shift_right(p5_r, 17) + resize(m6_r, 38);
         p2_lo_r <= std_logic_vector(p2_r(16 downto 15));
         p5_lo_r <= std_logic_vector(p5_r(16 downto 14));
      end if;
   end process p_dsp;


   ---------------------------------------
   -- Stage 4: Add the constants, and check the range
   ---------------------------------------

   -- The products are p3_r*2^34 + p2_r(16 downto 0)*2^17 (units of 2^-66),
   -- so (x+y)*(x-y) is p3_r*2 + p2_r(16) (units of 2^-33), and 2*x*y is
   -- p6_r*4 + p5_r(16 downto 15). Half an LSB is added by the carry into the
   -- adder, see p_dsp. p3_r and p6_r are between -4 and 4 (units of 2^-32),
   -- so their top bits are not used.
   new_x_s <= (std_logic_vector(p3_r(35 downto 0)) & p2_lo_r(1)) +
              (cx_r(0)(34) & cx_r(0)(34) & cx_r(0)) + p2_lo_r(0);
   new_y_s <= (std_logic_vector(p6_r(35 downto 0)) & p5_lo_r(2 downto 1)) +
              (cy_r(34) & cy_r(34) & cy_r(34) & cy_r) + p5_lo_r(0);

   -- The new x is in range if it is between -2 and 2, i.e. if the three top
   -- bits are equal, and the same for the new y, with the four top bits.
   ovf_s <= (new_x_s(36) xor new_x_s(35)) or
            (new_x_s(35) xor new_x_s(34)) or
            (new_y_s(37) xor new_y_s(36)) or
            (new_y_s(36) xor new_y_s(35)) or
            (new_y_s(35) xor new_y_s(34));

   init_s <= start_i or init_r(0) or init_r(1) or init_r(2);

   p_value : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if run_r = '1' then
            x_r   <= new_x_s(34 downto 0);
            y_r   <= new_y_s(34 downto 0);
            ovf_r <= ovf_s;
         end if;

         -- Clear the values of the four slots at the start. This has priority
         -- over the clock enable (run_r), which is still low in the clock
         -- cycle of the start.
         if init_s = '1' then
            x_r   <= (others => '0');
            y_r   <= (others => '0');
            ovf_r <= '0';
         end if;
      end if;
   end process p_value;


   ---------------------------------------
   -- The constants of the slots
   ---------------------------------------

   -- cx_r moves along with the slots, while the points are calculated
   -- (run_r). The value of cx that is put in the last entry is in the first
   -- entry three clock cycles later, when the slot is in stage 3, i.e. it is
   -- used one clock cycle before the slot is in x_r and y_r. At the start, the
   -- values of cx of slot 0, 1, 2, and 3 are put in the last entry, in the
   -- clock cycle of the start (where run_r is still low, so the other entries
   -- do not move, but they are not used) and the three after it.
   p_cx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         cy_r    <= cy_i;
         stepx_r <= stepx_i;

         if run_r = '1' then
            cx_r(0 to 2) <= cx_r(1 to 3);
            cx_r(3)      <= cx_r(0);
         end if;
         if (init_r(0) or init_r(1) or init_r(2)) = '1' then
            cx_r(3)  <= cx_acc_r;
            cx_acc_r <= cx_acc_r + stepx_r;
         end if;
         if start_i = '1' then
            cx_r(3)  <= cx_i;
            cx_acc_r <= cx_i + stepx_r;
         end if;
      end if;
   end process p_cx;


   -----------------------------
   -- Periodicity detection
   -----------------------------

   -- The saved values move along with the slots, like cx_r (also only while
   -- run_r is high). The values of the slot in x_r and y_r are saved if it_r
   -- is a power of two. The saved values are not cleared at the start
   -- (otherwise each bit would need a LUT), because they are first saved
   -- after iteration 1, before they are compared (from iteration 2).
   p_save : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if run_r = '1' then
            sx_r(0 to 2) <= sx_r(1 to 3);
            sy_r(0 to 2) <= sy_r(1 to 3);
            sx_r(3)      <= sx_r(0);
            sy_r(3)      <= sy_r(0);
            if it_pow2_r = '1' then
               sx_r(3) <= x_r;
               sy_r(3) <= y_r;
            end if;
         end if;
      end if;
   end process p_save;

   -- Compare x and y with the saved values of the slot (from an earlier
   -- iteration, so only from iteration 2)
   match_s <= '1' when it_ge2_r = '1' and x_r = sx_r(0) and y_r = sy_r(0) else '0';


   -----------------
   -- Control
   -----------------

   -- The slot and the number of iterations in x_r and y_r. The number of
   -- iterations increases when the slot goes from 3 to 0, while the points
   -- are calculated.
   p_slot : process (clk_i)
      variable it_v : std_logic_vector(C_CNT_BITS-1 downto 0);
   begin
      if rising_edge(clk_i) then
         init_r <= init_r(1 downto 0) & start_i;

         if sl_r = 3 then
            sl_r <= 0;
            if run_r = '1' then
               it_v := it_r + 1;
               it_r <= it_v;
               it_pow2_r <= '0';
               if (it_v and (it_v - 1)) = 0 then
                  it_pow2_r <= '1';
               end if;
               it_ge2_r  <= '0';
               if it_v(C_CNT_BITS-1 downto 1) /= 0 then
                  it_ge2_r <= '1';
               end if;
               it_last_r <= '0';
               if it_v = G_MAX_COUNT-1 then
                  it_last_r <= '1';
               end if;
            end if;
         else
            sl_r <= sl_r + 1;
         end if;

         if start_i = '1' then
            sl_r      <= 0;
            it_r      <= (others => '0');
            it_pow2_r <= '0';
            it_ge2_r  <= '0';
            it_last_r <= '0';
         end if;

         if rst_i = '1' then
            init_r <= (others => '0');
         end if;
      end if;
   end process p_slot;

   -- The checks of the slot in x_r and y_r are used one clock cycle later.
   -- They are cleared at the start, so the values from before the start are
   -- not used.
   p_ctrl : process (clk_i)
   begin
      if rising_edge(clk_i) then
         sl_d    <= sl_r;
         it_d    <= it_r;
         ovf_d   <= ovf_r;
         match_d <= match_s;
         last_d  <= it_last_r;

         -- Stop on an overflow in the last iteration (the count is the
         -- number of that iteration), or when a cycle is found, or after the
         -- last iteration.
         if busy_r(sl_d) = '1' then
            if ovf_d = '1' then
               busy_r(sl_d) <= '0';
               cnt_r(sl_d)  <= it_d;
            elsif match_d = '1' or last_d = '1' then
               busy_r(sl_d) <= '0';
               cnt_r(sl_d)  <= to_slv(G_MAX_COUNT, C_CNT_BITS);
            end if;
         end if;

         if run_r = '1' and busy_r = "0000" then
            run_r  <= '0';
            done_r <= '1';
         end if;

         if start_i = '1' then
            ovf_d   <= '0';
            match_d <= '0';
            last_d  <= '0';
            run_r   <= '1';
            busy_r  <= "1111";
            done_r  <= '0';
         end if;

         if rst_i = '1' then
            run_r  <= '0';
            busy_r <= "0000";
            done_r <= '0';
         end if;
      end if;
   end process p_ctrl;


   --------------------------
   -- Connect output signals
   --------------------------

   cnt_o  <= cnt_r(3) & cnt_r(2) & cnt_r(1) & cnt_r(0);
   done_o <= done_r;

end architecture rtl;
