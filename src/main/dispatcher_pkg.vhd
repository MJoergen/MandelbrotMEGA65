-- This package has the types used in the ports of the two parts of the
-- dispatcher (dispatcher_jobs.vhd and dispatcher_results.vhd). The type
-- value_vector is also used by the wide iterator (iterator_wide.vhd).

library ieee;
use ieee.std_logic_1164.all;

package dispatcher_pkg is

   -- One value (cx, starty, or stepy) for each group of job modules. The
   -- width of the values depends on the number format (G_FRAC_BITS+2 bits),
   -- so it is given where the type is used.
   type value_vector is array (natural range <>) of std_logic_vector;

   -- The row within the job of the result of each job module
   type res_addr_vector is array (natural range <>) of
      std_logic_vector(8 downto 0);

end package dispatcher_pkg;
