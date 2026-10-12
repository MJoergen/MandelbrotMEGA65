#!/bin/bash
# The SessionStart hook of Claude Code, see .claude/settings.json.
#
# The cloud environment of Claude Code (where CLAUDE_CODE_REMOTE is "true")
# has none of the tools, so there this installs the free ones with
# scripts/install-tools.sh (GHDL, Yosys, SymbiYosys, Yices, VSG, and numpy),
# and adds them to the PATH of the later commands of the session, through the
# file CLAUDE_ENV_FILE. The first time this downloads about 750 MB. Vivado is
# not installed, so the builds for the boards can not be run there.
#
# Elsewhere it does nothing: the tools are expected to be installed, see
# Tools in README.md.

set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
   exit 0
fi

mkdir -p "$HOME/.cache"
log=$HOME/.cache/mandelbrot-tools.log
if ! paths=$("$(dirname "$0")/install-tools.sh" 2> "$log"); then
   echo "Installing the tools failed, see $log." >&2
   exit 1
fi

# The first directory must come first in the PATH, so they are added in the
# reverse order.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
   for p in $(echo "$paths" | tac); do
      echo "export PATH=\"$p:\$PATH\"" >> "$CLAUDE_ENV_FILE"
   done
fi

# This is added to the context of the session.
echo "The free tools are installed (GHDL, Yosys, SymbiYosys, Yices, VSG," \
     "numpy, see scripts/install-tools.sh), so make sim, make formal, and" \
     "VSG can be run. Vivado is not installed, so the builds for the boards" \
     "(make mega65-r3, make mega65-r6, make nexys4ddr) can not be run here."
