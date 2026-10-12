-- This package has the functions that are used in both clock domains, e.g.
-- for the widths of the signals.

library ieee;
use ieee.std_logic_1164.all;

package util_pkg is

   -- The number of bits needed for the values 0 to n-1, e.g. 2 for 3 or 4,
   -- and 0 for 0 or 1
   function log2 (n : natural) return natural;

end package util_pkg;

package body util_pkg is

   function log2 (n : natural) return natural is
      variable r_v : natural := 0;
   begin
      while 2**r_v < n loop
         r_v := r_v + 1;
      end loop;
      return r_v;
   end function log2;

end package body util_pkg;
