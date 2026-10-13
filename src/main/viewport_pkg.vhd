-- This package holds the states of the update of the view, which is shared by
-- the two axes (see viewport.vhd and viewport_axis.vhd).

package viewport_pkg is

   type state_t is (IDLE_ST, ZOOM_ST, STEP_ST, PREP_ST, MULT_ST, CENTRE_ST,
                    PAN_ST, CLAMP_ST);

end package viewport_pkg;

