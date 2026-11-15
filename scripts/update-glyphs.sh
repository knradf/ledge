#!/bin/bash
# Maintainers: pulls the latest sketchybar-app-font release (font + map) into
# Resources/Glyphs, which build.sh puts inside Ledge.app. CC0, so it can ship.
set -euo pipefail
cd "$(dirname "$0")/../Resources/Glyphs"
BASE="https://github.com/kvndrsslr/sketchybar-app-font/releases/latest/download"
curl -fsSL -o sketchybar-app-font.ttf "$BASE/sketchybar-app-font.ttf"
curl -fsSL -o icon_map.json "$BASE/icon_map.json"
VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/kvndrsslr/sketchybar-app-font/releases/latest" | sed 's#.*/tag/v##')
echo "$VERSION" > VERSION
echo "Glyphs updated to $VERSION"
