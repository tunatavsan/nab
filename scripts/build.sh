#!/usr/bin/env bash
# Builds dist/Nab.app (release). --run relaunches it; --install replaces /Applications/Nab.app
# with the new bundle, registers it with LaunchServices and opens it. NAB_SIGN_IDENTITY overrides the signing
# identity; a stable identity keeps the Automation permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product NabApp
swift build -c release --product nab
BIN="$(swift build -c release --show-bin-path)"

APP=dist/Nab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NabApp" "$APP/Contents/MacOS/Nab"
cp "$BIN/nab" "$APP/Contents/Resources/nab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${NAB_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP/Contents/Resources/nab"
codesign --force --options runtime --entitlements Resources/Nab.entitlements --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x Nab 2>/dev/null || true
    sleep 0.3
    open "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Nab 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Nab.app
    ditto "$APP" /Applications/Nab.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Nab.app
    open /Applications/Nab.app
fi
