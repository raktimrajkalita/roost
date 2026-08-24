#!/usr/bin/env bash
# Roost installer — copies the reporter + sounds into place and wires up Hammerspoon.
# It does NOT edit your ~/.claude/settings.json for you (that file may hold secrets);
# it prints the hook snippet to add at the end.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HOME/.claude-notch"
HS="$HOME/.hammerspoon/init.lua"

echo "→ Installing Roost…"
mkdir -p "$ROOT/bin" "$ROOT/state" "$ROOT/sounds" "$ROOT/mutes"
cp "$HERE/bin/notch-hook.py" "$ROOT/bin/"
cp "$HERE/bin/gen-sounds.py" "$ROOT/bin/"
cp "$HERE/sounds/"*.wav "$ROOT/sounds/"
chmod +x "$ROOT/bin/"*.py
echo "  ✓ reporter + sounds → $ROOT"

# Hammerspoon config
if [ -f "$HS" ]; then
  cp "$HS" "$HS.bak.$(date +%s)" 2>/dev/null || true
  echo "  ! $HS already exists — backed it up. Review before overwriting."
  echo "    To use Roost's config: cp \"$HERE/hammerspoon/init.lua\" \"$HS\""
else
  mkdir -p "$HOME/.hammerspoon"
  cp "$HERE/hammerspoon/init.lua" "$HS"
  echo "  ✓ Hammerspoon config → $HS"
fi

echo
echo "→ Two things left to do:"
echo
echo "1) Install + launch Hammerspoon (the UI engine):"
echo "     brew install --cask hammerspoon && open -a Hammerspoon"
echo "   Grant it Accessibility when asked; approve Automation on first click-to-focus."
echo
echo "2) Add these hooks to ~/.claude/settings.json (merge into any existing \"hooks\"):"
echo "   ----------------------------------------------------------------"
sed -n '/"hooks"/,$p' "$HERE/hooks/settings.snippet.json"
echo "   ----------------------------------------------------------------"
echo
echo "Done. New Claude Code sessions report automatically; restart open ones to pick up the hooks."
