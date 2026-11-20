#!/bin/bash
# Rebuilds and restarts Ledge after you change something (e.g. Theme.swift).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

LABEL="io.github.knradf.ledge"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# stop the running copy and wait until launchd has really let go of it
# (bootout returns early; starting again too soon fails with "error 5")
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.1
done

APP="/Applications/Ledge.app"
rm -rf "$APP"
cp -R build/Ledge.app "$APP"
# older installs went to ~/Applications and logged to /tmp/ledge.log: move
# the LaunchAgent over
if [ "$(/usr/libexec/PlistBuddy -c 'Print Program' "$PLIST" 2>/dev/null)" != "$APP/Contents/MacOS/Ledge" ]; then
  /usr/libexec/PlistBuddy -c "Set Program $APP/Contents/MacOS/Ledge" "$PLIST"
  rm -rf "$HOME/Applications/Ledge.app"
fi
LOG="/tmp/ledge_$(id -u).log"
if [ "$(/usr/libexec/PlistBuddy -c 'Print StandardErrorPath' "$PLIST" 2>/dev/null)" != "$LOG" ]; then
  /usr/libexec/PlistBuddy -c "Set StandardErrorPath $LOG" "$PLIST"
fi

if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
  # still registered after all: just restart it in place
  launchctl kickstart -k "$DOMAIN/$LABEL"
fi
echo "Restarted"
