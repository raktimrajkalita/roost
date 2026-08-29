#!/usr/bin/env bash
# A/B the current build against origin/main, one at a time.
# Both bundles share com.raktim.roost, so whichever you launch replaces the other.
set -euo pipefail
NEW=/Applications/Roost.app/Contents/MacOS/Roost
OLD=/Users/jay/roost-baseline/dist/Roost.app/Contents/MacOS/Roost

case "${1:-}" in
  old)  echo "→ origin/main (8b1f95c), no reply feature";  nohup "$OLD" >/dev/null 2>&1 & ;;
  new)  echo "→ current branch, installed build";          nohup "$NEW" >/dev/null 2>&1 & ;;
  which)
    p=$(pgrep -lf "Roost.app/Contents/MacOS/Roost" | head -1 || true)
    [ -z "$p" ] && { echo "nothing running"; exit 0; }
    case "$p" in
      *roost-baseline*) echo "running: ORIGIN/MAIN baseline" ;;
      *) echo "running: CURRENT branch" ;;
    esac
    echo "  $p" ;;
  *) echo "usage: ./ab.sh [old|new|which]"; exit 1 ;;
esac
sleep 3
pgrep -lf "Roost.app/Contents/MacOS/Roost" | head -1 | sed 's/^/  pid: /'
