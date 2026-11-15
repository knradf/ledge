#!/bin/bash
# Compiles Ledge and wraps it in build/Ledge.app
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Install the command line tools: xcode-select --install"
  exit 1
fi

swift build -c release

APP="build/Ledge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Ledge" "$APP/Contents/MacOS/Ledge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# the app glyphs ship inside Ledge (sketchybar-app-font, CC0): the font is
# picked up by macOS from Contents/Resources/Fonts, the map is read by Ledge
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Glyphs/sketchybar-app-font.ttf "$APP/Contents/Resources/Fonts/"
cp Resources/Glyphs/icon_map.json Resources/Glyphs/LICENSE Resources/Glyphs/VERSION "$APP/Contents/Resources/"
# Sign with the local certificate if make-cert.sh created one: macOS ties
# permissions to the signature, so they then survive rebuilds.
if security find-certificate -c "Ledge Local" >/dev/null 2>&1; then
  codesign --force --sign "Ledge Local" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "Note: signed ad-hoc. Run make-cert.sh once so permissions survive rebuilds."
fi

echo "Built $APP"
