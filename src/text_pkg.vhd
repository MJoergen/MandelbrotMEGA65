-- This package defines the characters of the text shown at the top of the VGA
-- output (see overlay.vhd). A character is 4 bits: the digits 0 to 9 are
-- their own value, and the codes 10 to 14 are the other characters below. The
-- code 15 is not shown, i.e. the picture is shown there. The glyphs are in
-- font_pkg.vhd, at the same codes (see font/gen_font_pkg.py).
--
-- A text of n characters is a std_logic_vector of 4*n bits, with the leftmost
-- character in the highest 4 bits.
--
-- The view text (see view_text.vhd) has C_VIEW_CHARS characters.

library ieee;
use ieee.std_logic_1164.all;

package text_pkg is

   constant C_CHAR_DOT   : std_logic_vector(3 downto 0) := X"A";  -- "."
   constant C_CHAR_MINUS : std_logic_vector(3 downto 0) := X"B";  -- "-"
   constant C_CHAR_PLUS  : std_logic_vector(3 downto 0) := X"C";  -- "+"
   constant C_CHAR_I     : std_logic_vector(3 downto 0) := X"D";  -- "i"
   constant C_CHAR_X     : std_logic_vector(3 downto 0) := X"E";  -- "x"
   constant C_CHAR_NONE  : std_logic_vector(3 downto 0) := X"F";  -- Not shown

   constant C_VIEW_CHARS : natural := 25;

end package text_pkg;

