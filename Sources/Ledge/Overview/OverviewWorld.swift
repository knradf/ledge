import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO

/// One window placed in the world, in screen points.
struct WorldCard: Identifiable, Equatable {
    let window: OverviewWindow
    var frame: CGRect
    var id: CGWindowID { window.id }
}

/// A card as drawn: its row, and its frame on that row's desktop after the
/// strip has been fitted to the desktop's width.
struct PlacedCard: Identifiable, Equatable {
    let card: WorldCard
    let row: Int
    let frame: CGRect
    var id: CGWindowID { card.id }
}

/// One workspace: a screen-sized desktop with its strip of windows.
struct WorldRow: Identifiable, Equatable {
    let number: Int
    let active: Bool
    var cards: [WorldCard]
    var id: Int { number }
}

/// All workspaces stacked vertically like niri. Coordinates are screen points
/// with the current workspace at (0, 0, screen size), so at zoom 1 the world
/// looks exactly like the screen does.
struct OverviewWorld: Equatable {
    var screen: CGSize = .zero
    var rows: [WorldRow] = []
    var activeIndex: Int = 0

    static let rowGapRatio: CGFloat = 0.12
    static let windowGap: CGFloat = 12

    var rowGap: CGFloat { screen.height * Self.rowGapRatio }

    /// Top edge of a row (fractional index allowed, for the camera).
    func rowTop(_ index: CGFloat) -> CGFloat {
        (index - CGFloat(activeIndex)) * (screen.height + rowGap)
    }

    /// Which row a point in the world is over. Each row owns its desktop plus
    /// half the gap on either side; below the last row still counts as the
    /// last (the empty one). nil is above the first row.
    func rowIndex(atY y: CGFloat) -> Int? {
        guard screen.height > 0, !rows.isEmpty else { return nil }
        let pitch = screen.height + rowGap
        let index = Int(((y + rowGap / 2) / pitch).rounded(.down)) + activeIndex
        if index < 0 { return nil }
        return min(index, rows.count - 1)
    }

    /// Every card with the row it's in, so all windows can be drawn in one
    /// layer and a window moving between rows simply slides.
    var placedCards: [PlacedCard] {
        rows.enumerated().flatMap { index, row in
            let frames = Self.fitted(row.cards.map { $0.frame }, screen: screen)
            return zip(row.cards, frames).map { PlacedCard(card: $0, row: index, frame: $1) }
        }
    }

    /// A strip wider than its desktop (lots of windows, or two full-screen
    /// ones) is scaled down until all of it fits, so every window can be seen
    /// and reached. A strip that already fits is left exactly as it is.
    static func fitted(_ frames: [CGRect], screen: CGSize) -> [CGRect] {
        guard let first = frames.first, screen.width > 0 else { return frames }
        let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
        if bounds.minX >= 0 && bounds.maxX <= screen.width { return frames }

        let pad = screen.width * fitPadding
        let available = screen.width - pad * 2
        let scale = min(1, available / max(bounds.width, 1))
        let left = pad + (available - bounds.width * scale) / 2
        let midY = bounds.midY
        return frames.map { frame in
            CGRect(
                x: left + (frame.minX - bounds.minX) * scale,
                y: midY + (frame.minY - midY) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }
    }

    static let fitPadding: CGFloat = 0.03

    /// Where a dragged window would land in a row: the number of other
    /// windows whose middle is left of the pointer. Measured with the dragged
    /// window already taken out, so the answer doesn't flicker as the row
    /// makes room for it.
    func insertionIndex(of id: CGWindowID, inRow target: Int, atX x: CGFloat) -> Int {
        let world = removing(id)?.world ?? self
        guard world.rows.indices.contains(target) else { return 0 }
        let frames = Self.fitted(world.rows[target].cards.map { $0.frame }, screen: screen)
        return frames.filter { $0.midX < x }.count
    }

    /// The world with a window taken out and its gap closed.
    func removing(_ id: CGWindowID) -> (world: OverviewWorld, card: WorldCard, row: Int, index: Int)? {
        guard let from = rows.firstIndex(where: { $0.cards.contains { $0.id == id } }),
              let k = rows[from].cards.firstIndex(where: { $0.id == id })
        else { return nil }
        var world = self
        let card = world.rows[from].cards.remove(at: k)
        if from == activeIndex {
            // the workspace on screen keeps its windows where they are
            for i in k..<world.rows[from].cards.count {
                world.rows[from].cards[i].frame.origin.x -= card.frame.width + Self.windowGap
            }
        } else {
            Self.center(&world.rows[from].cards, screen: screen)
        }
        return (world, card, from, k)
    }

    /// The world after a window moves to position `index` of a row. Filling
    /// the empty last row adds a new empty one after it, like niri.
    /// nil when it would end up where it already is.
    func moving(_ id: CGWindowID, to targetIndex: Int, at index: Int) -> OverviewWorld? {
        guard let removed = removing(id), rows.indices.contains(targetIndex) else { return nil }
        if targetIndex == removed.row && index == removed.index { return nil }
        var world = removed.world
        var card = removed.card

        if targetIndex == world.rows.count - 1, world.rows[targetIndex].cards.isEmpty {
            world.rows.append(WorldRow(number: world.rows[targetIndex].number + 1, active: false, cards: []))
        }
        var cards = world.rows[targetIndex].cards
        let at = min(max(index, 0), cards.count)
        card.frame.origin.y = cards.map { $0.frame.minY }.min() ?? Self.desktopTop

        if targetIndex == activeIndex && !cards.isEmpty {
            // on the workspace on screen: slot in and push the rest right
            card.frame.origin.x = at < cards.count ? cards[at].frame.minX : cards[cards.count - 1].frame.maxX + Self.windowGap
            for i in at..<cards.count {
                cards[i].frame.origin.x += card.frame.width + Self.windowGap
            }
            cards.insert(card, at: at)
        } else {
            cards.insert(card, at: at)
            Self.center(&cards, screen: screen)
        }
        world.rows[targetIndex].cards = cards
        return world
    }

    /// Lays a strip out left to right, centered when it fits.
    static func center(_ cards: inout [WorldCard], screen: CGSize) {
        let total = cards.reduce(0) { $0 + $1.frame.width } + windowGap * CGFloat(max(0, cards.count - 1))
        var x = total < screen.width ? (screen.width - total) / 2 : windowGap
        for i in cards.indices {
            cards[i].frame.origin.x = x
            x += cards[i].frame.width + windowGap
        }
    }

    /// where a workspace's windows start below the bar
    static let desktopTop: CGFloat = 44

    static func build(rows: [OverviewRow], frames: [CGWindowID: CGRect], screen: CGSize) -> OverviewWorld {
        var world = OverviewWorld()
        world.screen = screen
        world.activeIndex = rows.firstIndex(where: { $0.active }) ?? 0
        world.rows = rows.enumerated().map { index, row in
            WorldRow(
                number: row.number,
                active: row.active,
                cards: layout(row.windows, frames: frames, screen: screen, anchored: index == world.activeIndex)
            )
        }
        return world
    }

    /// Anchored (the workspace on screen): visible windows stay exactly where
    /// they are, the rest of the strip continues off the edges in order.
    /// Not anchored: the strip is laid out in order, centered when it fits.
    static func layout(_ windows: [OverviewWindow], frames: [CGWindowID: CGRect],
                       screen: CGSize, anchored: Bool) -> [WorldCard] {
        let gap = windowGap
        let top = desktopTop
        let screenRect = CGRect(origin: .zero, size: screen)

        func base(_ window: OverviewWindow) -> CGRect {
            if var frame = frames[window.id], frame.width > 1, frame.height > 1 {
                // Paneru parks other workspaces off-screen vertically (like niri);
                // bring a parked window back onto its desktop
                if frame.minY >= screen.height || frame.maxY <= 0 { frame.origin.y = top }
                return frame
            }
            return CGRect(x: 0, y: top, width: screen.width * 0.5, height: max(1, screen.height - top - 8))
        }

        var placed = [CGRect?](repeating: nil, count: windows.count)
        if anchored {
            for (i, window) in windows.enumerated() {
                if let frame = frames[window.id], frame.intersection(screenRect).width >= 40 {
                    placed[i] = frame
                }
            }
        }

        if let first = placed.firstIndex(where: { $0 != nil }), let anchor = placed[first] {
            var left = anchor.minX
            for i in stride(from: first - 1, through: 0, by: -1) {
                var frame = base(windows[i])
                frame.origin.x = left - gap - frame.width
                placed[i] = frame
                left = frame.minX
            }
            var right = anchor.maxX
            for i in (first + 1)..<windows.count {
                if let frame = placed[i] {
                    right = max(right, frame.maxX)
                    continue
                }
                var frame = base(windows[i])
                frame.origin.x = right + gap
                placed[i] = frame
                right = frame.maxX
            }
        } else {
            // real frames only, so windows without one can't skew the shift below
            let known: [CGRect?] = windows.map { window in
                guard let frame = frames[window.id], frame.width > 1, frame.height > 1 else { return nil }
                return frame
            }
            // keep the workspace's own vertical arrangement, but start it at the
            // top of the desktop wherever Paneru has parked it
            let shift = known.compactMap { $0?.minY }.min().map { top - $0 } ?? 0
            let sizes: [CGRect] = windows.indices.map { i in
                guard let frame = known[i] else { return base(windows[i]) }
                return frame.offsetBy(dx: 0, dy: shift)
            }
            let total = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, windows.count - 1))
            var x = total < screen.width ? (screen.width - total) / 2 : gap
            for i in windows.indices {
                var frame = sizes[i]
                frame.origin.x = x
                placed[i] = frame
                x += frame.width + gap
            }
        }

        return windows.enumerated().map { index, window in
            WorldCard(window: window, frame: placed[index] ?? .zero)
        }
    }
}

/// Where windows really are, in a display's own points (top-left origin).
enum WindowGeometry {
    static func frames(_ ids: Set<CGWindowID>, displayOrigin: CGPoint) -> [CGWindowID: CGRect] {
        guard !ids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var result: [CGWindowID: CGRect] = [:]
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? UInt32, ids.contains(number),
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
            else { continue }
            result[number] = bounds.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
        }
        return result
    }
}

/// The wallpaper behind the overview's workspaces: a capture of macOS's own
/// wallpaper window (owned by WindowManager, below the desktop icons), so it
/// is the real one, Aerials included. Since Sonoma macOS no longer says which
/// picture file is the wallpaper. Needs Screen Recording; without it the
/// overview draws plain desktops.
///
/// Kept per display and refreshed when the wallpaper changes, the Space
/// changes or the overview opens, so it opens with the last one instantly.
enum WallpaperImage {
    private static var cache: [CGDirectDisplayID: NSImage] = [:]
    private static var observing = false

    static func image(for screen: NSScreen) -> NSImage? {
        cache[screen.displayID]
    }

    static func start() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: .ledgeWallpaperChanged, object: nil, queue: .main) { _ in
            refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            refresh()
        }
        refresh()
    }

    /// Captures the wallpaper of every display (or one), then calls back on main.
    static func refresh(_ only: CGDirectDisplayID? = nil, then done: @escaping () -> Void = {}) {
        guard CGPreflightScreenCaptureAccess() else { return done() }
        Task {
            var captured: [CGDirectDisplayID: NSImage] = [:]
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                for display in content.displays where only == nil || display.displayID == only {
                    guard let window = wallpaperWindow(on: display, in: content) else { continue }
                    let filter = SCContentFilter(display: display, including: [window])
                    let config = SCStreamConfiguration()
                    config.width = display.width
                    config.height = display.height
                    config.showsCursor = false
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    else { continue }
                    captured[display.displayID] = NSImage(cgImage: image, size: NSSize(width: display.width, height: display.height))
                }
            }
            let result = captured
            await MainActor.run {
                cache.merge(result) { $1 }
                done()
            }
        }
    }

    /// macOS draws the wallpaper in a window called "Wallpaper", below the
    /// desktop icons. Falls back to any non-Finder window at that level.
    private static func wallpaperWindow(on display: SCDisplay, in content: SCShareableContent) -> SCWindow? {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let candidates = content.windows.filter { window in
            window.windowLayer < iconLevel && window.frame.intersects(display.frame)
                && window.owningApplication?.bundleIdentifier != "com.apple.finder"
        }
        return candidates.first { $0.title == "Wallpaper" }
            ?? candidates.first { $0.owningApplication?.bundleIdentifier == "com.apple.WindowManager" }
    }
}

extension Notification.Name {
    /// you picked another wallpaper (from WallpaperTone's watch on the store)
    static let ledgeWallpaperChanged = Notification.Name("LedgeWallpaperChanged")
}
