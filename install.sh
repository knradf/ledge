#!/bin/bash
# Builds Ledge, puts it in /Applications, starts it now and at every login,
# and turns SketchyBar off if it was running (uninstall.sh turns it back on).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

LABEL="io.github.knradf.ledge"
APP="/Applications/Ledge.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x Ledge 2>/dev/null || true
# bootout returns early; wait until launchd has really let go
for _ in $(seq 1 50); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.1
done

mkdir -p "$HOME/Library/LaunchAgents"
# older installs went to ~/Applications
rm -rf "$HOME/Applications/Ledge.app"
rm -rf "$APP"
cp -R build/Ledge.app "$APP"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>Program</key>
    <string>$APP/Contents/MacOS/Ledge</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ledge_$(id -u).log</string>
</dict>
</plist>
PLIST

# two bars at once is one too many: stop SketchyBar if it runs, and remember
# that we did, so uninstall.sh only restarts it in that case
if command -v brew >/dev/null 2>&1 && brew services list 2>/dev/null | grep -q '^sketchybar .*started'; then
  echo "Turning SketchyBar off"
  brew services stop sketchybar
  mkdir -p "$HOME/Library/Application Support/Ledge"
  touch "$HOME/Library/Application Support/Ledge/stopped-sketchybar"
fi

launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl kickstart -k "$DOMAIN/$LABEL"
echo "Ledge is running. Log: /tmp/ledge_$(id -u).log"
