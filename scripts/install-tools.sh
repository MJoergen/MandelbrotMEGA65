#!/bin/bash
# Installs the free tools needed by "make sim", "make formal", and the check
# of the coding style (VSG), see Tools in README.md:
# * The OSS CAD Suite (https://github.com/YosysHQ/oss-cad-suite-build) of the
#   date OSS_CAD_SUITE_DATE, which has Yosys with the GHDL plugin, SymbiYosys,
#   and Yices, for make formal.
# * GHDL (https://github.com/ghdl/ghdl) of the version GHDL_VERSION, with the
#   mcode backend, for make sim. The OSS CAD Suite has a GHDL too, but with
#   the LLVM backend, which fails on the external names of the testbenches
#   (see Tools in README.md), so this one comes first in the PATH.
# * VSG and numpy, in a Python virtual environment (or with pip --user, if
#   the module venv is missing).
# Vivado is not free to download, and is not installed.
#
# Usage: scripts/install-tools.sh [<dir>]
#
# The tools are installed in <dir> (default: ~/.cache/mandelbrot-tools). A
# second run with the same versions downloads nothing. The directories to add
# to the PATH are written to stdout, one per line, in the order of the PATH
# (the first one first), and everything else to stderr. Used by the CI
# (.github/workflows/ci.yml) and by scripts/claude-session-start.sh.

set -euo pipefail

OSS_CAD_SUITE_DATE=2026-10-01
GHDL_VERSION=6.0.0
VSG_VERSION=3.35.0

dir=${1:-$HOME/.cache/mandelbrot-tools}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)

# The OSS CAD Suite is about 750 MB, so it is only downloaded when the date
# has changed.
oss=$dir/oss-cad-suite
if [ "$(cat "$dir/oss-cad-suite.date" 2>/dev/null)" != "$OSS_CAD_SUITE_DATE" ]; then
   echo "Installing the OSS CAD Suite $OSS_CAD_SUITE_DATE in $dir" >&2
   rm -rf "$oss" "$dir/oss-cad-suite.date"
   url=https://github.com/YosysHQ/oss-cad-suite-build/releases/download
   curl -sSfL "$url/$OSS_CAD_SUITE_DATE/oss-cad-suite-linux-x64-${OSS_CAD_SUITE_DATE//-/}.tgz" |
      tar xzf - -C "$dir"
   echo "$OSS_CAD_SUITE_DATE" > "$dir/oss-cad-suite.date"
fi

# GHDL, about 20 MB
ghdl=$dir/ghdl-mcode-$GHDL_VERSION-ubuntu24.04-x86_64
if [ ! -x "$ghdl/bin/ghdl" ]; then
   echo "Installing GHDL $GHDL_VERSION in $dir" >&2
   url=https://github.com/ghdl/ghdl/releases/download
   curl -sSfL "$url/v$GHDL_VERSION/ghdl-mcode-$GHDL_VERSION-ubuntu24.04-x86_64.tar.gz" |
      tar xzf - -C "$dir"
fi

# VSG and numpy
venv=$dir/venv
if [ ! -x "$venv/bin/vsg" ] || [ "$("$venv/bin/vsg" --version | grep -o '[0-9.]*$')" != "$VSG_VERSION" ]; then
   echo "Installing VSG $VSG_VERSION and numpy in $venv" >&2
   if python3 -m venv "$venv" >&2; then
      "$venv/bin/pip" install --quiet "vsg==$VSG_VERSION" numpy >&2
   else
      echo "No Python module venv, installing with pip --user instead" >&2
      rm -rf "$venv"
      python3 -m pip install --quiet --user "vsg==$VSG_VERSION" numpy >&2 ||
         python3 -m pip install --quiet --user --break-system-packages "vsg==$VSG_VERSION" numpy >&2
   fi
fi

echo "$ghdl/bin"
echo "$oss/bin"
if [ -d "$venv/bin" ]; then
   echo "$venv/bin"
else
   echo "$HOME/.local/bin"
fi
