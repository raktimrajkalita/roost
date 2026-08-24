#!/usr/bin/env bash
# Builds Roost.app -- a double-clickable menu-bar agent -- with Command Line Tools only.
#   ./build-app.sh            build dist/Roost.app
#   ./build-app.sh --install  build, then copy to /Applications and start at login
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
BIN=".build/${CONFIG}/Roost"
APP="dist/Roost.app"

# 1. icon (only if missing) -- rebuild from the wordmark source
if [ ! -f icon/Roost.icns ]; then
    echo "[*] generating icon from icon/roost.png"
    swift icon/png-to-icns.swift icon/roost.png icon/Roost.iconset
    iconutil -c icns icon/Roost.iconset -o icon/Roost.icns
fi

# 2. build
echo "[*] building ${CONFIG}"
swift build -c "${CONFIG}"

# 3. assemble the bundle
echo "[*] assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}"             "${APP}/Contents/MacOS/Roost"
cp packaging/Info.plist "${APP}/Contents/Info.plist"
cp icon/Roost.icns      "${APP}/Contents/Resources/Roost.icns"
printf 'APPL????'     > "${APP}/Contents/PkgInfo"

# 4. ad-hoc sign (stable TCC identity so the Automation grant sticks)
echo "[*] signing (ad-hoc)"
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}" && echo "    signature ok"

echo "[ok] built ${APP}"

# 5. optional install
if [ "${1:-}" = "--install" ]; then
    echo "[*] installing to /Applications"
    pkill -x Roost 2>/dev/null || true
    rm -rf /Applications/Roost.app
    cp -R "${APP}" /Applications/Roost.app

    PLIST="${HOME}/Library/LaunchAgents/com.raktim.roost.plist"
    echo "[*] installing login item -> ${PLIST}"
    mkdir -p "${HOME}/Library/LaunchAgents"
    cat > "${PLIST}" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.raktim.roost</string>
    <key>ProgramArguments</key> <array><string>/Applications/Roost.app/Contents/MacOS/Roost</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <false/>
    <key>ProcessType</key>      <string>Interactive</string>
</dict>
</plist>
PL
    launchctl unload "${PLIST}" 2>/dev/null || true
    launchctl load  "${PLIST}"
    echo "[ok] installed. Roost is running and will start at login."
    echo "     remove login item:  launchctl unload \"${PLIST}\" && rm \"${PLIST}\""
fi
