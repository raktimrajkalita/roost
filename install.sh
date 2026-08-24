#!/usr/bin/env bash
# Roost installer — copies the reporter + synthesized chimes into ~/.claude-notch/.
# It does NOT edit your ~/.claude/settings.json for you (that file may hold secrets);
# it prints the hook snippet to add at the end.
#
# This installs the shared data layer. For the UI, build the native app next:
#     ./build-app.sh --install
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HOME/.claude-notch"

echo "-> Installing the Roost reporter…"
mkdir -p "$ROOT/bin" "$ROOT/state" "$ROOT/sounds" "$ROOT/mutes"
cp "$HERE/bin/notch-hook.py" "$ROOT/bin/"
cp "$HERE/bin/gen-sounds.py" "$ROOT/bin/"
cp "$HERE/sounds/"*.wav "$ROOT/sounds/"
chmod +x "$ROOT/bin/"*.py
echo "   ok: reporter + chimes -> $ROOT"

echo
echo "-> Add these hooks to ~/.claude/settings.json (merge into any existing \"hooks\"):"
echo "   ----------------------------------------------------------------"
sed -n '/"hooks"/,$p' "$HERE/hooks/settings.snippet.json"
echo "   ----------------------------------------------------------------"
echo
echo "-> Then build the UI (the native app):"
echo "     ./build-app.sh --install       # Roost.app -> /Applications, starts at login"
echo "   (The old Hammerspoon build is retired -> legacy/; the native app replaces it.)"
echo
echo "Done. New Claude Code sessions report automatically; restart open ones to pick up the hooks."
