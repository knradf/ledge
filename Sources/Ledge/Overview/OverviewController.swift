import AppKit
import Combine
import SwiftUI

/// A window being dragged to another workspace.
struct OverviewDrag: Equatable {
    let id: CGWindowID
    let fromRow: Int
    /// where it was drawn when the drag started, in world points
    let origin: CGRect
    /// in world points
    var offset: CGSize
    /// row under the pointer
    var target: Int?
    /// position in that row's strip it would take
    var index: Int?
}

/// Camera state the view renders from.
final class OverviewModel: ObservableObject {
    @Published var isOpen = false
    /// 0 = the real screen at 1:1, 1 = zoomed out
    @Published var progress: CGFloat = 0
    /// which workspace the camera centers on (fractional while moving)
    @Published var focusRow: CGFloat = 0
    @Published var world = OverviewWorld()
    @Published var wallpaper: NSImage?
    @Published var hovered: CGWindowID?
    @Published var drag: OverviewDrag?
    /// the world as it would be if the dragged window were dropped now: the
    /// other windows make room, and a ghost shows where it lands
    @Published var preview: OverviewWorld?
}

/// Panel that can take keyboard focus (Esc, arrows, digits) without
/// activating Ledge, so the app you were in stays the active one.
final class OverviewPanel: FloatingPanel {
    override var canBecomeKey: Bool { true }
}

/// niri-style overview: all workspaces stacked vertically, current one in the
/// middle. Opens instantly (fade + settle), closes by gliding to your pick.
///
/// It covers the whole screen and takes the keyboard, so it must never be
/// able to linger: Esc always gets out (even if the panel lost focus),
/// switching apps closes it, and a watchdog closes it if it's ever open but
/// not actually showing.
final class OverviewController {
    static let shared = OverviewController()

    let model = OverviewModel()
    weak var paneru: PaneruStore?
    /// told when the overview opens and closes (arms Esc in the shortcut tap)
    var onOpenChanged: (Bool) -> Void = { _ in }

    private var panel: OverviewPanel?
    private var monitors: [Any] = []
    private var busy = false
    private var busyGeneration = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var lastActive: OverviewRow?
    private var watchdog: Timer?
    /// workspace on screen when the overview opened; moves come back to it
    private var homeNumber: Int?
    private var pendingMoves = 0
    /// moving windows activates their apps; don't take that as you switching away
    private var ignoreActivationUntil = Date.distantPast
    private var dragPan: DispatchWorkItem?
    // scrolling and swiping move the camera directly, then settle on a row
    private var scrollRaw: CGFloat?
    private var scrollSamples: [(time: TimeInterval, row: CGFloat)] = []
    private var wheelReadyAt = Date.distantPast

    func toggle() {
        model.isOpen ? cancel() : open()
    }

    /// Keeps previews warm: whenever you leave a workspace, its windows are
    /// captured (they stay capturable while Paneru has them parked).
    func watch(_ paneru: PaneruStore) {
        self.paneru = paneru
        paneru.$rows
            .sink { [weak self] rows in self?.workspaceMaybeChanged(rows) }
            .store(in: &subscriptions)
        // capture the wallpapers now, not on first open
        WallpaperImage.start()
        // Cmd-Tab, a click in the Dock, anything that brings another app up
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.model.isOpen, !self.busy, self.pendingMoves == 0,
                  Date() > self.ignoreActivationUntil
            else { return }
            self.cancel()
        }
    }

    private func workspaceMaybeChanged(_ rows: [OverviewRow]) {
        // forget previews of closed windows and old ones (not while they're on screen)
        if !model.isOpen, let paneru {
            let open = Set(paneru.snapshot.rows.flatMap { $0.windows.map { $0.id } })
            if !open.isEmpty { PreviewStore.shared.prune(keeping: open) }
        }
        guard let active = rows.first(where: { $0.active }) else { return }
        defer { lastActive = active }
        guard let previous = lastActive, previous.number != active.number, !previous.windows.isEmpty else { return }
        let ids = previous.windows.map { $0.id }
        Task { await PreviewStore.shared.capture(ids, scale: Theme.previewScale) }
    }

    // MARK: opening

    /// Opens instantly with the previews already there; the current workspace
    /// refreshes in the background and crossfades in.
    func open() {
        guard let paneru, paneru.connected, !model.isOpen, !busy else { return }
        // every workspace up to the last used one, plus an empty one after it
        let rows = paneru.rows.withEmpty()
        let mouse = NSEvent.mouseLocation
        guard !rows.isEmpty,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }

        setBusy()
        Dropdown.shared.close()

        let display = CGDisplayBounds(screen.displayID)
        let ids = Set(rows.flatMap { $0.windows.map { $0.id } })
        let world = OverviewWorld.build(
            rows: rows,
            frames: WindowGeometry.frames(ids, displayOrigin: display.origin),
            screen: display.size
        )

        model.world = world
        model.focusRow = CGFloat(world.activeIndex)
        model.progress = 0
        model.hovered = nil
        model.drag = nil
        model.preview = nil
        model.wallpaper = WallpaperImage.image(for: screen)
        // an Aerial has moved on since: freshen it behind the overview
        WallpaperImage.refresh(screen.displayID) { [weak self] in
            guard let self, self.model.isOpen, let fresh = WallpaperImage.image(for: screen) else { return }
            self.model.wallpaper = fresh
        }
        homeNumber = world.rows.indices.contains(world.activeIndex) ? world.rows[world.activeIndex].number : nil

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: false)
        panel.makeKeyAndOrderFront(nil)
        model.isOpen = true
        onOpenChanged(true)
        installMonitors()
        startWatchdog()

        // one frame at progress 0 (invisible), then settle in
        DispatchQueue.main.async {
            withAnimation(Theme.overviewIn) { self.model.progress = 1 }
            self.clearBusy(after: Theme.overviewDuration)
        }

        // freshen what's on screen now (crossfades), then anything never captured
        let activeIDs = world.rows[world.activeIndex].cards.map { $0.id }
        let missing = ids.filter { PreviewStore.shared.images[$0] == nil && !activeIDs.contains($0) }
        Task {
            await PreviewStore.shared.capture(activeIDs, scale: Theme.previewScale)
            await PreviewStore.shared.capture(Array(missing), scale: Theme.previewScale)
        }
        paneru.refresh()
    }

    // MARK: choosing

    /// Back to where you were.
    func cancel() {
        // a swipe handled by Paneru may have switched workspaces behind us
        if let home = homeNumber, let paneru, paneru.rows.first(where: { $0.active })?.number != home {
            paneru.go(to: home)
        }
        close(towards: model.world.activeIndex)
    }

    /// Esc: back out, and if something is mid-animation, out right now.
    func escape() {
        guard model.isOpen else { return }
        if busy { forceClose() } else { cancel() }
    }

    func choose(rowIndex: Int) {
        guard model.world.rows.indices.contains(rowIndex), !busy, model.drag == nil else { return }
        paneru?.go(to: model.world.rows[rowIndex].number)
        close(towards: rowIndex)
    }

    func choose(_ window: OverviewWindow, rowIndex: Int) {
        guard model.world.rows.indices.contains(rowIndex), !busy, model.drag == nil else { return }
        paneru?.focusWindow(window, in: model.world.rows[rowIndex].number)
        close(towards: rowIndex)
    }

    private func chooseNumber(_ number: Int) {
        if let index = model.world.rows.firstIndex(where: { $0.number == number }) {
            choose(rowIndex: index)
        } else {
            paneru?.go(to: number)
            cancel()
        }
    }

    /// The switch happens right away behind the overview while the camera
    /// glides to the chosen workspace, leans in and fades out.
    private func close(towards index: Int) {
        guard model.isOpen, !busy else { return }
        setBusy()
        removeMonitors()
        dragPan?.cancel()
        withAnimation(Theme.overviewOut) {
            model.hovered = nil
            model.drag = nil
            model.preview = nil
            model.focusRow = CGFloat(min(max(index, 0), max(0, model.world.rows.count - 1)))
            model.progress = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.overviewDuration) {
            self.finishClosing()
        }
    }

    /// Gone this instant, no animation. The way out when something's stuck.
    func forceClose() {
        removeMonitors()
        dragPan?.cancel()
        model.hovered = nil
        model.drag = nil
        model.preview = nil
        model.progress = 0
        finishClosing()
    }

    private func finishClosing() {
        panel?.orderOut(nil)
        stopWatchdog()
        if model.isOpen { model.isOpen = false }
        onOpenChanged(false)
        busyGeneration += 1
        busy = false
    }

    private func moveFocus(by step: Int) {
        let target = min(max(model.focusRow.rounded() + CGFloat(step), 0), maxRow)
        guard target != model.focusRow else { return }
        withAnimation(Theme.overviewPan) { model.focusRow = target }
    }

    // MARK: scrolling and swiping

    private var maxRow: CGFloat { CGFloat(max(0, model.world.rows.count - 1)) }

    /// Puts the camera exactly here, no animation: it follows your fingers.
    /// Past the first and last row it gives way less and less.
    private func follow(_ raw: CGFloat) {
        var row = raw
        if row < 0 { row = -Self.rubberBand(-row) }
        if row > maxRow { row = maxRow + Self.rubberBand(row - maxRow) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.focusRow = row }
    }

    static func rubberBand(_ overshoot: CGFloat) -> CGFloat {
        0.35 * overshoot / (1 + overshoot)
    }

    /// Fingers lifted: glide to the nearest row. A quick flick carries on to
    /// the next one, but never further, so a swipe can't fly across them all.
    private func settle(from raw: CGFloat, velocity: CGFloat) {
        let target = Self.settleTarget(raw: raw, velocity: velocity, maxRow: maxRow)
        withAnimation(Theme.overviewPan) { model.focusRow = target }
    }

    static func settleTarget(raw: CGFloat, velocity: CGFloat, maxRow: CGFloat) -> CGFloat {
        let nearest = min(max(raw.rounded(), 0), maxRow)
        let carry = min(max(velocity * 0.2, -0.7), 0.7)
        let projected = min(max((raw + carry).rounded(), 0), maxRow)
        // at most one row past the nearest
        return min(max(projected, nearest - 1), nearest + 1)
    }

    /// Two-finger scrolling. Trackpads move the stack 1:1 with your fingers
    /// and settle when you let go (momentum is ignored); a mouse wheel steps
    /// one workspace per notch.
    private func scrolled(_ event: NSEvent) {
        let reverse = LedgeSettings.shared.overviewReverseScroll
        // scrollingDeltaY already follows the system's scroll direction:
        // positive moves content down, showing the workspace above
        var dy = event.scrollingDeltaY
        if reverse { dy = -dy }

        guard event.hasPreciseScrollingDeltas else {
            guard dy != 0, Date() >= wheelReadyAt else { return }
            wheelReadyAt = Date().addingTimeInterval(0.18)
            moveFocus(by: dy > 0 ? -1 : 1)
            return
        }
        guard event.momentumPhase.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if event.phase.contains(.began) || scrollRaw == nil {
            scrollRaw = model.focusRow
            scrollSamples = []
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if let raw = scrollRaw { settle(from: raw, velocity: Self.velocity(scrollSamples)) }
            scrollRaw = nil
            return
        }
        let pitch = (model.world.screen.height + model.world.rowGap) * Theme.overviewScale
        guard pitch > 0, var raw = scrollRaw else { return }
        raw -= dy / pitch
        scrollRaw = raw
        scrollSamples.append((now, raw))
        scrollSamples.removeAll { now - $0.time > 0.1 }
        follow(raw)
    }

    static func velocity(_ samples: [(time: TimeInterval, row: CGFloat)]) -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.008 else { return 0 }
        return (last.row - first.row) / CGFloat(last.time - first.time)
    }

    // MARK: dragging windows (between workspaces and within one)

    func dragChanged(_ placed: PlacedCard, translation: CGSize, location: CGPoint) {
        guard model.isOpen, !busy else { return }
        let world = model.world
        var drag = model.drag ?? OverviewDrag(
            id: placed.id,
            fromRow: placed.row,
            origin: placed.frame.offsetBy(dx: 0, dy: world.rowTop(CGFloat(placed.row))),
            offset: .zero
        )
        guard drag.id == placed.id else { return }
        drag.offset = translation

        let target = world.rowIndex(atY: location.y)
        let index = target.map { world.insertionIndex(of: placed.id, inRow: $0, atX: location.x) }
        if target != drag.target {
            panWhileDragging(to: target)
        }
        if target != drag.target || index != drag.index || model.drag == nil {
            drag.target = target
            drag.index = index
            let preview = target.flatMap { t in
                index.flatMap { world.moving(placed.id, to: t, at: $0) }
            }
            withAnimation(Theme.overviewMakeRoom) { model.preview = preview }
        }
        model.hovered = nil
        model.drag = drag
    }

    func dragEnded(_ placed: PlacedCard) {
        dragPan?.cancel()
        guard let drag = model.drag, drag.id == placed.id else { return }
        let world = model.world

        guard model.isOpen, !busy, let paneru, let target = drag.target,
              let moved = model.preview, moved.rows.indices.contains(target),
              let at = moved.rows[target].cards.firstIndex(where: { $0.id == placed.id })
        else {
            // back where it came from
            withAnimation(Theme.overviewPan) {
                model.drag = nil
                model.preview = nil
                model.focusRow = min(model.focusRow, CGFloat(max(0, world.rows.count - 1)))
            }
            return
        }

        let number = moved.rows[target].number
        let place: PaneruStore.StripPlace = at == 0 ? .first : .after(moved.rows[target].cards[at - 1].id)
        withAnimation(Theme.overviewPan) {
            model.world = moved
            model.preview = nil
            model.drag = nil
        }

        pendingMoves += 1
        ignoreActivationUntil = .distantFuture
        paneru.moveWindow(placed.id, to: number, place: place, thenShow: homeNumber) { [weak self] ok in
            guard let self else { return }
            self.pendingMoves -= 1
            if self.pendingMoves == 0 { self.ignoreActivationUntil = Date().addingTimeInterval(0.6) }
            guard self.model.isOpen, !self.busy else { return }
            // focusing the window to move it took the keyboard away from us
            self.panel?.makeKeyAndOrderFront(nil)
            if !ok { self.showRealLayout() }
        }
    }

    /// Hovering over another workspace for a moment brings it into view,
    /// like spring-loaded folders.
    private func panWhileDragging(to target: Int?) {
        dragPan?.cancel()
        guard let target, target != Int(model.focusRow.rounded()) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.drag?.target == target else { return }
            withAnimation(Theme.overviewPan) { self.model.focusRow = CGFloat(target) }
        }
        dragPan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// A move didn't happen: redraw from what Paneru actually has.
    private func showRealLayout() {
        guard let paneru, let panel, let screen = panel.screen else { return }
        let rows = paneru.rows.withEmpty()
        guard !rows.isEmpty else { return }
        let display = CGDisplayBounds(screen.displayID)
        let ids = Set(rows.flatMap { $0.windows.map { $0.id } })
        let world = OverviewWorld.build(
            rows: rows,
            frames: WindowGeometry.frames(ids, displayOrigin: display.origin),
            screen: display.size
        )
        withAnimation(Theme.overviewPan) {
            model.world = world
            model.focusRow = min(model.focusRow, CGFloat(max(0, world.rows.count - 1)))
        }
    }

    // MARK: safety

    private func setBusy() {
        busy = true
        busyGeneration += 1
        // whatever happens, never stay busy for long
        clearBusy(after: Theme.overviewDuration + 1.0)
    }

    private func clearBusy(after delay: Double) {
        let generation = busyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.busyGeneration == generation { self.busy = false }
        }
    }

    /// Open but not showing (ordered out, faded to nothing, off its display)
    /// means it would only be swallowing clicks and keys: close it for real.
    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.model.isOpen else { return }
            let visible = self.panel?.isVisible ?? false
            let faded = !self.busy && self.model.progress < 0.5
            if !visible || faded { self.forceClose() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: setup

    private func makePanel() -> OverviewPanel {
        // just below the bar, so the bar stays on top like in niri
        let panel = OverviewPanel(
            contentRect: .zero,
            level: NSWindow.Level(rawValue: BarMetrics.level.rawValue - 1),
            shadow: false
        )
        let root = OverviewView(model: model)
            .environmentObject(PreviewStore.shared)
        let host = FirstClickHostingView(rootView: AnyView(root))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Esc: back. ↑/↓ or scroll: move between workspaces. Return: enter the
    /// centered one. 1–9: jump to that workspace.
    private func installMonitors() {
        removeMonitors()
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.model.isOpen else { return event }
            switch event.keyCode {
            case 53: self.escape()                                        // Esc
            case 126: self.moveFocus(by: -1)                              // ↑
            case 125: self.moveFocus(by: 1)                               // ↓
            case 36, 76: self.choose(rowIndex: Int(self.model.focusRow.rounded()))  // Return
            default:
                if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
                    self.chooseNumber(digit)
                } else {
                    return event
                }
            }
            return nil
        }) {
            monitors.append(keys)
        }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, self.model.isOpen else { return event }
            self.scrolled(event)
            return nil
        }) {
            monitors.append(scroll)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        scrollRaw = nil
    }
}
