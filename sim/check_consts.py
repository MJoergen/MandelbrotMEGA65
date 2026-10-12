#!/usr/bin/env python3
"""Checks that the constants of the boards in the model and in the testbench
of main are the same as in the design.

sim/model.py and the defaults of the generics of sim/main_tb.vhd have their
own copies of the constants of src/mega65.vhd (and the model also those of
src/nexys4ddr.vhd), see the comments "Must match" in sim/model.py. This script
reads the constants from the VHDL files, and compares them. It prints each
difference, and exits with the status 1 if there is one.

Usage (from the top directory of the repository, "make consts" does this):
  python3 sim/check_consts.py
"""

import re
import sys
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOP / 'sim'))

import model  # noqa: E402  (after the path is set)


def vhdl_constants(filename):
    """The values of the constants (and the defaults of the generics) in a
    VHDL file, as strings, without comments."""
    text = re.sub(r'--[^\n]*', '', (TOP / filename).read_text())
    consts = {}
    for name, value in re.findall(r'constant\s+(\w+)\s*:\s*[\w ]+?:=\s*([^;]+);', text):
        consts[name] = value.strip()
    for name, value in re.findall(r'\b(G_\w+)\s*:\s*\w+\s*:=\s*([^;)\n]+)', text):
        consts[name] = value.strip()
    return consts


def video_modes():
    """The visible size of each video mode in src/vga/video_pkg.vhd."""
    text = (TOP / 'src/vga/video_pkg.vhd').read_text()
    modes = {}
    for name, body in re.findall(r'constant\s+(C_VIDEO_\w+)\s*:\s*video_mode_t\s*:=\s*\((.*?)\);',
                                 text, re.S):
        fields = dict(re.findall(r'(\w+)\s*=>\s*([\w\']+)', body))
        modes[name] = (int(fields['h_visible']), int(fields['v_visible']))
    return modes


def board(filename):
    """The constants of the design of a board."""
    c = vhdl_constants(filename)
    cols, rows = video_modes()[c['C_VIDEO']]
    main_clock_khz = (100e3 / float(c['C_VCO_DIVIDE']) * float(c['C_VCO_MULT']) /
                      float(c['C_MAIN_DIVIDE']))
    return {
        'NUM_COLS':       cols,
        'NUM_ROWS':       rows,
        'ROWS_IN_JOB':    int(c['C_ROWS_IN_JOB']),
        'NUM_ITERATORS':  int(c['C_NUM_ITERATORS']),
        'PIXELS':         int(c['C_PIXELS']),
        'COL_STRIDE':     int(c['C_COL_STRIDE']),
        'ADDR_BITS':      int(c['C_ADDR_BITS']),
        'MAIN_CLOCK_KHZ': main_clock_khz,
    }


def main():
    errors = []

    def check(what, got, expected):
        if isinstance(expected, float):
            same = abs(got - expected) <= 1e-9 * abs(expected)
        else:
            same = got == expected
        if not same:
            errors.append(f'{what} is {got}, but it must be {expected}')

    mega65 = board('src/mega65.vhd')
    nexys4ddr = board('src/nexys4ddr.vhd')
    main_vhd = vhdl_constants('src/main/main.vhd')
    dispatcher = vhdl_constants('src/main/dispatcher.vhd')
    main_tb = vhdl_constants('sim/main_tb.vhd')

    # sim/model.py
    check('MAX_COUNT in sim/model.py', model.MAX_COUNT, int(main_vhd['C_MAX_COUNT']))
    check('GROUP_SIZE in sim/model.py', model.GROUP_SIZE, int(dispatcher['G_GROUP_SIZE']))
    for name in ['NUM_COLS', 'NUM_ROWS', 'ROWS_IN_JOB', 'NUM_ITERATORS', 'PIXELS',
                 'MAIN_CLOCK_KHZ']:
        check(f'{name} in sim/model.py', getattr(model, name), mega65[name])
        check(f'NEXYS4DDR_{name} in sim/model.py', getattr(model, 'NEXYS4DDR_' + name),
              nexys4ddr[name])

    # The initial view in sim/model.py (pixel_c) and src/main/main.vhd
    text = (TOP / 'sim/model.py').read_text()
    startx = re.search(r'round\(\((-?[\d.]+) \+ 4\.0\) \* 65536\)', text)
    sizex = re.search(r'round\(([\d.]+) \* 65536\)\) // cols', text)
    check('The start of the real axis in sim/model.py', float(startx.group(1)),
          float(main_vhd['C_START_X']))
    check('The size of the real axis in sim/model.py', float(sizex.group(1)),
          float(main_vhd['C_SIZE_X']))

    # The defaults of the generics of sim/main_tb.vhd
    for name in ['NUM_ITERATORS', 'PIXELS', 'ROWS_IN_JOB', 'NUM_COLS', 'NUM_ROWS',
                 'COL_STRIDE', 'ADDR_BITS']:
        check(f'The default of G_{name} in sim/main_tb.vhd', int(main_tb['G_' + name]),
              mega65[name])

    for e in errors:
        print(e)
    if errors:
        sys.exit(1)
    print('The constants of the model and of main_tb match the design')


if __name__ == '__main__':
    main()
