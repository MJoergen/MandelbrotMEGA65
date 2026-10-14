-- This is a replacement for the wide iterator (src/main/iterator_wide.vhd),
-- used for the formal verification of the job module (job_wide.vhd). It has
-- the same entity, so the job module instantiates it instead of the real
-- iterator, but it does not calculate anything: Its outputs are chosen freely
-- by the solver in every clock cycle. The handshake of the iterator is instead given by
-- assumptions in job_wide.psl.

library ieee;
use ieee.std_logic_1164.all;

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
      stepy_i : in  std_logic_vector(34 downto 0);
      cnt_o   : out std_logic_vector(4*log2(G_MAX_COUNT+1)-1 downto 0);
      done_o  : out std_logic
   );
end entity iterator_wide;

architecture stub of iterator_wide is

   signal any_cnt_s  : std_logic_vector(4*log2(G_MAX_COUNT+1)-1 downto 0);
   signal any_done_s : std_logic;

   attribute anyseq : boolean;
   attribute anyseq of any_cnt_s  : signal is true;
   attribute anyseq of any_done_s : signal is true;

begin

   cnt_o  <= any_cnt_s;
   done_o <= any_done_s;

end architecture stub;
