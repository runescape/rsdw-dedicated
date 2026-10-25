#!/bin/bash
set -euo pipefail

# Healthy while the game server process is alive. Matches the shipping binary
# and its launcher wrapper (dev builds rename the binary).
if ! pgrep -f 'RSDragonwildsServer-Linux-Shipping' >/dev/null 2>&1 &&
   ! pgrep -f 'RSDragonwildsServer.sh' >/dev/null 2>&1; then
  exit 1
fi

exit 0
