import AppKit
import SwiftUI

/// Transparent overlay that gives a view left click, right click and
/// scroll-wheel handling (SwiftUI has no scroll-wheel hook on macOS).
struct MouseCatcher: NSViewRepresentable {
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    /// +1 = up / louder, -1 = down / quieter, regardless of natural scrolling
    var onScroll: (Int) -> Void = { _ in }
    /// a trackpad swipe counts once, not once per bit of distance
    var onePerGesture = false
    /// only takes scroll-wheel events: clicks reach the views underneath
    var scrollOnly = false
    /// a click opens this menu right under the view, like a menu bar item
    var menu: (() -> NSMenu)? = nil
    /// true while pressed or while its menu is open, for the highlight
    var onPress: (Bool) -> Void = { _ in }
    /// tooltip (SwiftUI's .help doesn't reach through this view)
    var help: String? = nil

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.owner = self
        view.toolTip = help
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.owner = self
        if view.toolTip != help { view.toolTip = help }
    }

    final class CatcherView: NSView {
        var owner: MouseCatcher?
        private var accumulated: CGFloat = 0

        private var gestureStepped = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            if owner?.scrollOnly == true, NSApp.currentEvent?.type != .scrollWheel { return nil }
            return super.hitTest(point)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let owner else { return }
            if let makeMenu = owner.menu {
                owner.onPress(true)
                // next turn, so the highlight is drawn before the menu takes over
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // window coordinates start at the bar's bottom edge
                    let barBottom = self.convert(NSPoint.zero, from: nil).y
                    makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: barBottom + 4), in: self)
                    self.owner?.onPress(false)
                }
            } else {
                owner.onPress(true)
                owner.onLeft()
            }
        }

        override func mouseUp(with event: NSEvent) {
            if owner?.menu == nil { owner?.onPress(false) }
        }

        override func rightMouseDown(with event: NSEvent) {
            owner?.onRight()
        }

        override func scrollWheel(with event: NSEvent) {
            guard let owner else { return }
            // a flick's coasting would keep going after the fingers are off
            guard event.momentumPhase.isEmpty else { return }
            var dy = event.scrollingDeltaY
            if event.isDirectionInvertedFromDevice { dy = -dy }
            guard event.hasPreciseScrollingDeltas else {
                // A mouse wheel: one notch, one step. scrollingDeltaY has the
                // system's acceleration in it, so a slow notch is a fraction
                // of a line and a quick spin is many.
                if dy != 0 { owner.onScroll(dy > 0 ? 1 : -1) }
                return
            }
            if event.phase == .began {
                accumulated = 0
                gestureStepped = false
            }
            // trackpads send lots of tiny deltas
            accumulated += dy / 12
            while abs(accumulated) >= 1 {
                let step = accumulated > 0 ? 1 : -1
                accumulated -= CGFloat(step)
                if owner.onePerGesture {
                    if gestureStepped { continue }
                    gestureStepped = true
                }
                owner.onScroll(step)
            }
            if event.phase == .ended || event.phase == .cancelled {
                accumulated = 0
                gestureStepped = false
            }
        }
    }
}
