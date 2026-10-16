-- This package has the types used in the ports of the two parts of the
-- dispatcher (dispatcher_jobs.vhd and dispatcher_results.vhd). The type
-- value_vector is also used by the wide iterator (iterator_wide.vhd).

library ieee;
use ieee.std_logic_1164.all;

package dispatcher_pkg is

   -- One value (startx, cy, or stepx) for each group of job modules. The
   -- width of the values (35 bits for 2.33) is given where the type is used.
   type value_vector is array (natural range <>) of std_logic_vector;

   -- The column within the job of the result of each job module
   type res_addr_vector is array (natural range <>) of
      std_logic_vector(8 downto 0);

end package dispatcher_pkg;
