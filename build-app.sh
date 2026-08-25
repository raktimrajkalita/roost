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
# SwiftPM compiles Package.swift itself before it touches any source, linking that against the
# toolchain's PackageDescription. On a machine where the active SDK doesn't match the Swift
# version (beta macOS, stale Command Line Tools, xcode-select pointing at the wrong Xcode) that
# manifest step fails before the build even starts. Roost has no dependencies, so when that
# happens we skip SwiftPM entirely and compile the sources directly.
echo "[*] building ${CONFIG}"
if ! swift build -c "${CONFIG}"; then
    echo
    echo "[!] swift build failed — falling back to a direct swiftc compile"
    echo "    (this usually means the SDK and the Swift toolchain disagree; check"
    echo "     'xcode-select -p' and 'xcrun --show-sdk-version')"
    mkdir -p "$(dirname "${BIN}")"
    swiftc -O -target "$(uname -m)-apple-macosx13.0" -o "${BIN}" Sources/Roost/*.swift
    echo "[ok] direct compile succeeded"
fi

# 3. assemble the bundle
echo "[*] assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}"             "${APP}/Contents/MacOS/Roost"
cp packaging/Info.plist "${APP}/Contents/Info.plist"
cp icon/Roost.icns      "${APP}/Contents/Resources/Roost.icns"
printf 'APPL????'     > "${APP}/Contents/PkgInfo"

# 3b. stamp provenance so the app can update itself later (must precede signing,
#     which seals the bundle)
COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -n "${COMMIT}" ]; then
    PL="${APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :RoostCommit string ${COMMIT}" "${PL}" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Set :RoostCommit ${COMMIT}" "${PL}" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :RoostSourcePath string $(pwd)" "${PL}" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Set :RoostSourcePath $(pwd)" "${PL}" >/dev/null 2>&1 || true
    echo "[*] stamped ${COMMIT:0:7} from $(pwd)"
fi

# 4. ad-hoc sign (stable TCC identity so the Automation grant sticks)
echo "[*] signing (ad-hoc)"
codesign --force --deep --sign - "${APP}"
codesign --verify --deep --strict "${APP}" && echo "    signature ok"

echo "[ok] built ${APP}"

# 5. optional install
if [ "${1:-}" = "--install" ]; then
    echo "[*] installing to /Applications"
    PLIST="${HOME}/Library/LaunchAgents/com.raktim.roost.plist"

    # Order matters. Unload launchd FIRST so it can't respawn the old build while we're
    # swapping the bundle, then kill, then WAIT for the process to actually exit. Killing
    # before unloading is what left an old instance alive next to the new one.
    launchctl unload "${PLIST}" 2>/dev/null || true
    pkill -x Roost 2>/dev/null || true
    for _ in $(seq 1 25); do
        pgrep -x Roost >/dev/null 2>&1 || break
        sleep 0.2
    done
    if pgrep -x Roost >/dev/null 2>&1; then
        echo "[!] Roost didn't exit on SIGTERM — forcing"
        pkill -9 -x Roost 2>/dev/null || true
        sleep 0.3
    fi

    rm -rf /Applications/Roost.app
    cp -R "${APP}" /Applications/Roost.app

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
    launchctl load "${PLIST}"
    echo "[ok] installed. Roost is running and will start at login."
    echo "     remove login item:  launchctl unload \"${PLIST}\" && rm \"${PLIST}\""
fi
