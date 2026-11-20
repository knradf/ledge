# Changelog

## 0.28

- Settings → Shortcuts: every Paneru keyboard shortcut, plus the overview's, built around one Super
  key; change it and they all follow. Click a shortcut to type a new one
- New installs get niri-style shortcuts (Paneru has none of its own) and keep windows below the bar
  from the start
- Settings is a regular window while open: it's in the Dock and ⌘Tab, and Paneru tiles it. Opening
  Ledge again while it runs shows Settings. Fewer captions, sentence-case headings
- An app icon
- The mouse wheel over the workspaces switches workspaces, one notch at a time
- Scrolling over the sound item steps the volume by 5%
- Three-finger swipes ignore touches that only hover, so a hand near the trackpad doesn't switch
  workspaces
- Installs to /Applications (moved from ~/Applications), logs to /tmp/ledge_<uid>.log

## 0.27 (first public release)

- Bar: Paneru workspaces (pills, numbers, app icons or built-in glyphs, optional empty workspaces),
  clock (center or right), Wi-Fi, network speed, Bluetooth, sound, battery, keyboard layout, AirDrop,
  Siri. Status items open native menus
- Styles: Liquid Glass, Frosted, Minimal; light or dark from the wallpaper (per display), the system,
  or fixed
- Works without Paneru: the bar shows your open apps
- Overview: niri-style stack of workspaces with live previews; drag windows between and within
  workspaces; Option + O and hot corner
- Island: playing indicator, track info and controls (with media-control, installable from
  Settings), calendar and upcoming events
- Settings for Paneru: screen edges, gaps, column widths, focus and mouse, sideways swipe mode,
  speed and glide, window movement
- Window rules: apps that open on a given workspace
- Three-finger up/down swipes with a configurable direction, and an experimental workspace slide
  (jumping several workspaces slides through the ones in between)
- Welcome on first launch: Paneru, room for the bar, trackpad gesture conflicts, permissions,
  media-control, open at login
- Needs macOS 26 or later
