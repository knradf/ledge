import AppKit
import SwiftUI

enum BarMetrics {
    /// Height of the transparent window strip at the top of each screen.
    static let windowHeight: CGFloat = 40
    static let pillHeight: CGFloat = 28
    static let topInset: CGFloat = 4
    /// Above normal and floating windows, below the (auto-hidden) macOS menu bar.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
}

/// Borderless panel that never becomes key or main, so clicking the bar
/// never steals focus from the app you're working in.
class FloatingPanel: NSPanel {
    init(contentRect: NSRect, level: NSWindow.Level, shadow: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        self.level = level
        // not .fullScreenAuxiliary: stay out of full-screen Spaces (games, videos)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the very first click, even though the
/// window is never key.
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class BarWindow: FloatingPanel {
    init(screen: NSScreen, content: AnyView) {
        let f = screen.frame
        let rect = NSRect(
            x: f.minX,
            y: f.maxY - BarMetrics.windowHeight,
            width: f.width,
            height: BarMetrics.windowHeight
        )
        super.init(contentRect: rect, level: BarMetrics.level, shadow: false)
        let host = FirstClickHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: rect.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
        setFrame(rect, display: true)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}
