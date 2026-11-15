import AppKit
import CoreText
import SwiftUI

/// Every look-and-feel knob in one place.
enum Theme {
    /// Try .menu, .popover, .hudWindow (always dark), .sidebar, .underWindowBackground
    static let pillMaterial: NSVisualEffectView.Material = .menu
    static let dropdownMaterial: NSVisualEffectView.Material = .menu

    static let stroke: Double = 0.10
    static let strokeActive: Double = 0.22
    static let activeHighlight: Double = 0.14

    static let iconSize: CGFloat = 18

    /// The exact font macOS uses in the menu bar, at its size, on this system.
    static var menuFont: Font { Font(NSFont.menuBarFont(ofSize: 0) as CTFont) }
    static var menuFontSize: CGFloat { NSFont.menuBarFont(ofSize: 0).pointSize }
    /// Smaller companion for network speeds and counts.
    static var smallFont: Font { .system(size: max(10, menuFontSize - 2)) }

    /// Glyphs (sketchybar-app-font) size; their alignment is in Settings.
    static let glyphFontSize: CGFloat = 15
    /// sketchybar-app-font's glyphs sit left in their box with extra room on
    /// the right: trim that, then nudge them back to center
    static let glyphTrim: CGFloat = 2
    static let glyphNudge: CGFloat = 2

    /// Workspace pills with numbers and apps turned off.
    static let simplePillWidth: CGFloat = 26
    static let simplePillActiveWidth: CGFloat = 44
    /// Dot for a workspace with nothing to show when the style is Minimal.
    static let bareDotSize: CGFloat = 6
    /// the "playing" pill left of the clock: glyph plus the pill's padding
    static let playingGlyphWidth: CGFloat = 16
    static let playingPillWidth: CGFloat = playingGlyphWidth + 20
    /// Minimal style: the workspace highlight slides instead of fading
    static let highlightSlide: Animation = .spring(response: 0.32, dampingFraction: 0.86)

    static let animation: Animation = .snappy(duration: 0.28)

    /// overview: how far the camera pulls back (Settings → Behavior → Zoom;
    /// niri's default is 0.5)
    static var overviewScale: CGFloat { CGFloat(min(max(LedgeSettings.shared.overviewZoom, 0.2), 0.8)) }
    static let overviewZoomChoices: [ZoomChoice] = [
        ZoomChoice(label: "Close", value: 0.5),
        ZoomChoice(label: "Medium", value: 0.42),
        ZoomChoice(label: "Far", value: 0.34),
    ]
    /// it settles in from this much closer, and leans back in when closing
    static let overviewEnterScale: CGFloat = 1.12
    static let overviewIn: Animation = .smooth(duration: 0.28)
    static let overviewOut: Animation = .smooth(duration: 0.24)
    /// windows sliding apart to make room for a dragged one
    static let overviewMakeRoom: Animation = .spring(response: 0.3, dampingFraction: 0.85)
    static let overviewPan: Animation = .spring(response: 0.35, dampingFraction: 0.9)
    /// time until open/close has visually finished
    static let overviewDuration: Double = 0.3
    static let overviewDesktopCorner: CGFloat = 40
    /// window corners as macOS draws them
    static let windowCorner: CGFloat = 16

    /// Preview resolution, pixels per window point: exactly what the
    /// overview draws at your zoom on this screen (zoom x Retina), so they're
    /// sharp without holding more pixels than ever shown. Close on a Retina
    /// screen is 1.0, Far about 0.68 (half the memory).
    static var previewScale: CGFloat {
        overviewScale * (NSScreen.main?.backingScaleFactor ?? 2)
    }
    /// how long the pointer has to stay in the hot corner
    static let hotCornerDelay: Double = 0.15

    /// active-workspace highlight crossfade
    static let highlightFade: Animation = .easeInOut(duration: 0.22)
}

struct ZoomChoice: Identifiable {
    let label: String
    let value: Double
    var id: Double { value }
}
