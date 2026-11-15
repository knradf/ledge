import AppKit
import SwiftUI

/// Transparent overlay that gives a view left click, right click and
/// scroll-wheel handling (SwiftUI has no scroll-wheel hook on macOS).
struct MouseCatcher: NSViewRepresentable {
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    /// +1 = up / louder, -1 = down / quieter, regardless of natural scrolling
    var onScroll: (Int) -> Void = { _ in }
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
            var dy = event.scrollingDeltaY
            if event.isDirectionInvertedFromDevice { dy = -dy }
            // trackpads send lots of tiny deltas, wheels send whole notches
            accumulated += event.hasPreciseScrollingDeltas ? dy / 12 : dy
            while abs(accumulated) >= 1 {
                let step = accumulated > 0 ? 1 : -1
                owner?.onScroll(step)
                accumulated -= CGFloat(step)
            }
            if event.phase == .ended || event.momentumPhase == .ended {
                accumulated = 0
            }
        }
    }
}
