import AppKit
import Combine
import QuartzCore
import ScreenCaptureKit

/// A vertical slide between workspaces (Settings → Behavior,
/// experimental). Paneru can't animate this: it hides other workspaces by
/// parking their windows in a corner, so its own animation is windows flying
/// into that corner.
///
/// So Ledge fakes it with pictures: the screen as it is, and the workspace
/// you're going to, both captured the moment you switch (windows on hidden
/// workspaces can still be captured while Paneru has them parked). Its
/// windows go where they were when you last saw that workspace, or where
/// Paneru will lay them out (strip order, real sizes, the edges and gap of
/// the workspace you're on). Core Animation moves the pictures, so the slide
/// runs in the system's render server, not in Ledge. Paneru switches behind,
/// and the real screen shows once it has.
///
/// A jump past other workspaces (clicking a pill) slides through them, so
/// you see how far you went. Those flash by, so they're drawn from the
/// overview's saved previews on the wallpaper (just the wallpaper when
/// there are none), with nothing new to capture.
///
/// Clicks pass through. If anything can't be captured in time, it doesn't
/// slide; the switch just happens.
final class WorkspaceSlide {
    static let shared = WorkspaceSlide()

    static let duration: CFTimeInterval = 0.36
    /// added for each workspace passed on the way, up to `longest`
    static let perExtraStep: CFTimeInterval = 0.06
    static let longest: CFTimeInterval = 0.5

    static func duration(steps: Int) -> CFTimeInterval {
        min(longest, duration + perExtraStep * CFTimeInterval(max(0, steps - 1)))
    }
    /// quick to start, long soft landing
    static let timing = CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.1, 1)
    static let fadeOut: TimeInterval = 0.1
    /// captures taking longer than this: switch without the slide
    static let captureBudget: TimeInterval = 0.25
    /// when Paneru never confirms the switch, show the real screen anyway
    static let giveUp: TimeInterval = 1.2

    private var panel: FloatingPanel?
    private var view: SlideView?
    private var running = false
    private var generation = 0
    /// where each workspace's windows were when it was last on screen
    private var lastFrames: [Int: [CGWindowID: CGRect]] = [:]
    /// what ScreenCaptureKit can capture, kept warm so a switch only has to
    /// take pictures (looking windows up is the slow part)
    private var content: SCShareableContent?
    private var contentRefreshPending = false
    private var subscriptions: Set<AnyCancellable> = []

    func watch(_ paneru: PaneruStore) {
        paneru.$rows
            .sink { [weak self] rows in
                self?.remember(rows)
                self?.refreshContentSoon()
            }
            .store(in: &subscriptions)
        LedgeSettings.shared.$workspaceSlide
            .sink { [weak self] on in
                if on { self?.refreshContentSoon() } else { self?.content = nil }
            }
            .store(in: &subscriptions)
    }

    private func remember(_ rows: [OverviewRow]) {
        guard LedgeSettings.shared.workspaceSlide, !running,
              let active = rows.first(where: { $0.active }), let screen = NSScreen.main
        else { return }
        let frames = Self.onScreenFrames(active.windows, screen: screen)
        if !frames.isEmpty { lastFrames[active.number] = frames }
    }

    private func refreshContentSoon() {
        guard LedgeSettings.shared.workspaceSlide, CGPreflightScreenCaptureAccess(), !contentRefreshPending
        else { return }
        contentRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task {
                let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                await MainActor.run {
                    self?.contentRefreshPending = false
                    if let fresh { self?.content = fresh }
                }
            }
        }
    }

    // MARK: sliding

    /// Slides to workspace `number` if it can. `switching` tells Paneru to
    /// switch and calls back once it has. `landed` runs once the real screen
    /// shows again (anything run before that happens out of sight). Returns
    /// false when it won't slide (then the caller switches on its own).
    func slide(to number: Int, rows: [OverviewRow],
               switching: @escaping (@escaping () -> Void) -> Void,
               landed: @escaping () -> Void) -> Bool {
        guard LedgeSettings.shared.workspaceSlide, !running,
              !OverviewController.shared.model.isOpen,
              CGPreflightScreenCaptureAccess(),
              let content,
              let current = rows.first(where: { $0.active }), current.number != number,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main,
              let display = content.displays.first(where: { $0.displayID == screen.displayID })
        else { return false }

        let targetWindows = rows.first(where: { $0.number == number })?.windows ?? []
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        // a window opened since the list was refreshed: can't capture it
        guard targetWindows.allSatisfy({ byID[$0.id] != nil }) else {
            refreshContentSoon()
            return false
        }

        running = true
        generation += 1
        let token = generation

        let leaving = Self.onScreenFrames(current.windows, screen: screen)
        if !leaving.isEmpty { lastFrames[current.number] = leaving }
        let placement = lastFrames[number]
            ?? Self.predictedFrames(targetWindows, sizes: Self.allFrames(targetWindows, screen: screen),
                                    like: leaving, screen: screen)
        let ledge = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let wallpaper = WallpaperImage.image(for: screen)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let down = number > current.number
        let scale = screen.backingScaleFactor
        let windows = targetWindows.compactMap { window in
            placement[window.id].flatMap { frame in byID[window.id].map { (window: $0, frame: frame) } }
        }
        let passing = Self.passingPages(
            Array(stride(from: current.number + (down ? 1 : -1), to: number, by: down ? 1 : -1)),
            rows: rows, remembered: lastFrames, like: leaving, screen: screen)

        // too slow to capture: switch without the slide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureBudget) { [weak self] in
            guard let self, self.running, self.generation == token, self.panel?.isVisible != true else { return }
            self.generation += 1
            self.running = false
            switching(landed)
        }

        Task {
            async let screenImage = Self.capture(display: display, excluding: ledge, scale: scale)
            let cards = await Self.capture(windows, scale: scale)
            let snapshot = await screenImage
            await MainActor.run {
                guard self.generation == token else { return }  // gave up already
                guard let snapshot, cards.count == windows.count else {
                    self.generation += 1
                    self.running = false
                    switching(landed)
                    return
                }
                self.run(on: screen, snapshot: snapshot, wallpaper: wallpaper, passing: passing, cards: cards,
                         down: down, switching: switching, landed: landed)
            }
        }
        return true
    }

    private func run(on screen: NSScreen, snapshot: CGImage, wallpaper: CGImage?, passing: [[SlideCard]],
                     cards: [SlideCard], down: Bool, switching: @escaping (@escaping () -> Void) -> Void,
                     landed: @escaping () -> Void) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: false)
        guard let view else { return }
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.prepare(snapshot: snapshot, wallpaper: wallpaper, passing: passing, cards: cards, down: down,
                     scale: screen.backingScaleFactor)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        var slid = false
        var switched = false
        var finished = false
        let finish = { [weak self] in
            guard let self, !finished, slid, switched else { return }
            finished = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeOut
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                view.clear()
                self.running = false
                landed()
            })
        }

        view.slide { slid = true; finish() }
        switching {
            // with smooth window movement Paneru eases windows back from its
            // corner after switching; let them land before showing them
            let settle: TimeInterval = PaneruSettings.shared.movement == .instant ? 0.03 : 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { switched = true; finish() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.giveUp) {
            slid = true
            switched = true
            finish()
        }
    }

    private func makePanel() -> FloatingPanel {
        // just under the bar, so the bar stays live on top during the slide
        let panel = FloatingPanel(
            contentRect: .zero,
            level: NSWindow.Level(rawValue: BarMetrics.level.rawValue - 1),
            shadow: false
        )
        panel.ignoresMouseEvents = true
        let view = SlideView()
        panel.contentView = view
        self.view = view
        return panel
    }

    // MARK: where windows go

    /// Frames of these windows that are actually on screen (display points,
    /// top-left origin). Parked ones are left out.
    private static func onScreenFrames(_ windows: [OverviewWindow], screen: NSScreen) -> [CGWindowID: CGRect] {
        let display = CGDisplayBounds(screen.displayID)
        let bounds = CGRect(origin: .zero, size: display.size)
        return allFrames(windows, screen: screen).filter { $0.value.intersection(bounds).width >= 40 }
    }

    private static func allFrames(_ windows: [OverviewWindow], screen: NSScreen) -> [CGWindowID: CGRect] {
        let display = CGDisplayBounds(screen.displayID)
        return WindowGeometry.frames(Set(windows.map { $0.id }), displayOrigin: display.origin)
    }

    /// A workspace not seen yet: its strip in order, real sizes, starting at
    /// the left edge and top Paneru uses on the workspace you're on, with the
    /// same gap between windows.
    static func predictedFrames(_ windows: [OverviewWindow], sizes: [CGWindowID: CGRect],
                                like current: [CGWindowID: CGRect], screen: NSScreen) -> [CGWindowID: CGRect] {
        let here = current.values.sorted { $0.minX < $1.minX }
        let left = max(0, here.first?.minX ?? 0)
        let top = here.map { $0.minY }.min() ?? OverviewWorld.desktopTop
        let gap = zip(here, here.dropFirst()).map { $1.minX - $0.maxX }.filter { $0 >= 0 }.min() ?? 0
        var result: [CGWindowID: CGRect] = [:]
        var x = left
        for window in windows {
            guard let size = sizes[window.id]?.size else { continue }
            result[window.id] = CGRect(origin: CGPoint(x: x, y: top), size: size)
            x += size.width + gap
        }
        return result
    }

    /// The workspaces flown past, in order: their saved previews where their
    /// windows were (or would be laid out). No preview, no card.
    private static func passingPages(_ numbers: [Int], rows: [OverviewRow], remembered: [Int: [CGWindowID: CGRect]],
                                     like current: [CGWindowID: CGRect], screen: NSScreen) -> [[SlideCard]] {
        let previews = PreviewStore.shared.images
        return numbers.map { number in
            let windows = (rows.first(where: { $0.number == number })?.windows ?? [])
                .filter { previews[$0.id] != nil }
            guard !windows.isEmpty else { return [] }
            let frames = remembered[number]
                ?? predictedFrames(windows, sizes: allFrames(windows, screen: screen), like: current, screen: screen)
            return windows.compactMap { window in
                guard let frame = frames[window.id],
                      let image = previews[window.id]?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return nil }
                return SlideCard(frame: frame, image: image)
            }
        }
    }

    // MARK: capturing

    private static func capture(display: SCDisplay, excluding: [SCRunningApplication], scale: CGFloat) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingApplications: excluding, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// All at once; the ones that fail are left out.
    private static func capture(_ windows: [(window: SCWindow, frame: CGRect)], scale: CGFloat) async -> [SlideCard] {
        await withTaskGroup(of: SlideCard?.self) { group in
            for item in windows {
                group.addTask {
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(item.frame.width * scale))
                    config.height = max(1, Int(item.frame.height * scale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: item.window)
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    else { return nil }
                    return SlideCard(frame: item.frame, image: image)
                }
            }
            var cards: [SlideCard] = []
            for await card in group { if let card { cards.append(card) } }
            return cards
        }
    }
}

struct SlideCard {
    let frame: CGRect
    let image: CGImage
}

/// Screen-sized layers on a track that Core Animation moves: where you are,
/// any workspaces passed on the way, where you're going.
final class SlideView: NSView {
    private let track = CALayer()
    private let current = CALayer()
    private let target = CALayer()
    private var passing: [CALayer] = []
    private var down = true
    private var done: () -> Void = {}

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        track.addSublayer(current)
        track.addSublayer(target)
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// y grows downward, like window frames. Declared on the view, not set
    /// on its layer: AppKit manages a view's layer and would undo that, which
    /// drew every window mirrored top to bottom.
    override var isFlipped: Bool { true }

    func prepare(snapshot: CGImage, wallpaper: CGImage?, passing pages: [[SlideCard]], cards: [SlideCard],
                 down: Bool, scale: CGFloat) {
        self.down = down
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.removeAllAnimations()
        track.frame = CGRect(origin: .zero, size: size)

        current.frame = track.bounds
        current.contents = snapshot
        current.contentsScale = scale

        // the n-th screen away from where you are
        func frame(_ n: Int) -> CGRect {
            CGRect(x: 0, y: CGFloat(n) * (down ? size.height : -size.height), width: size.width, height: size.height)
        }
        passing.forEach { $0.removeFromSuperlayer() }
        passing = pages.enumerated().map { index, cards in
            let page = CALayer()
            page.frame = frame(index + 1)
            fill(page, wallpaper: wallpaper, cards: cards, scale: scale)
            track.addSublayer(page)
            return page
        }
        target.frame = frame(pages.count + 1)
        fill(target, wallpaper: wallpaper, cards: cards, scale: scale)
        CATransaction.commit()
    }

    /// One workspace's picture: the wallpaper with its windows on top.
    private func fill(_ page: CALayer, wallpaper: CGImage?, cards: [SlideCard], scale: CGFloat) {
        page.sublayers?.forEach { $0.removeFromSuperlayer() }
        page.masksToBounds = true
        let backdrop = CALayer()
        backdrop.frame = page.bounds
        backdrop.backgroundColor = NSColor.black.cgColor
        backdrop.contents = wallpaper
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        page.addSublayer(backdrop)
        for card in cards {
            let layer = CALayer()
            layer.frame = card.frame
            layer.contents = card.image
            layer.contentsScale = scale
            layer.cornerRadius = Theme.windowCorner
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            page.addSublayer(layer)
        }
    }

    /// Moves the track to the last screen, in the render server.
    func slide(completion: @escaping () -> Void) {
        let steps = passing.count + 1
        let height = bounds.height * CGFloat(steps)
        let from = track.position.y
        let to = from + (down ? -height : height)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let animation = CABasicAnimation(keyPath: "position.y")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = WorkspaceSlide.duration(steps: steps)
        animation.timingFunction = WorkspaceSlide.timing
        CATransaction.setDisableActions(true)
        track.position.y = to
        track.add(animation, forKey: "slide")
        CATransaction.commit()
    }

    /// Drops the pictures once the slide is over.
    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        current.contents = nil
        target.sublayers?.forEach { $0.removeFromSuperlayer() }
        passing.forEach { $0.removeFromSuperlayer() }
        passing = []
        track.removeAllAnimations()
        track.position.y = bounds.height / 2
        CATransaction.commit()
    }
}
