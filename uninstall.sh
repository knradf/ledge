#!/bin/bash
# Removes Ledge. Starts SketchyBar again if install.sh had stopped it.
LABEL="io.github.knradf.ledge"
MARKER="$HOME/Library/Application Support/Ledge/stopped-sketchybar"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Ledge 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf /Applications/Ledge.app "$HOME/Applications/Ledge.app"
if [ -f "$MARKER" ] && command -v brew >/dev/null 2>&1; then
  brew services start sketchybar
  echo "SketchyBar is back on"
fi
rm -rf "$HOME/Library/Application Support/Ledge"
echo "Ledge removed. Its settings stay in: defaults read io.github.knradf.ledge (delete with: defaults delete io.github.knradf.ledge)"
