import AppKit
import Foundation

/// Live view of Paneru's workspaces.
///
/// Keeps one `paneru subscribe --json` child process open and re-queries the
/// full state whenever it reports a change. Waits for Paneru to answer before
/// subscribing (it may still be starting at login) and reconnects if it restarts.
final class PaneruStore: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var connected = false
    /// Paneru is running but hasn't been able to report its state for a few
    /// seconds (e.g. stuck after a full-screen game): the bar says so
    @Published private(set) var notAnswering = false
    private var failingSince: Date?
    /// goes up every time Ledge (re)connects to Paneru, e.g. after it restarts
    @Published private(set) var sessions = 0
    /// Every window per workspace, for the overview.
    @Published private(set) var rows: [OverviewRow] = []
    /// every window on every Space, for the window rules
    @Published private(set) var snapshot = PaneruSnapshot()

    private let binary: String? = PaneruStore.findBinary()
    private let queue = DispatchQueue(label: "ledge.paneru")
    /// Moving and focusing windows: steps that wait on Paneru's events, so
    /// they can't run on `queue`, which is where those events arrive.
    /// Serial, so two moves never interleave.
    private let moveQueue = DispatchQueue(label: "ledge.paneru.move")
    private var subscriber: Process?
    private var buffer = Data()
    private var refreshPending = false
    private var lastQuery: TimeInterval = 0
    /// at most this often while Paneru fires events in bursts (each query
    /// starts a process, so a burst of them costs real CPU)
    static let minQueryInterval: TimeInterval = 0.12

    static func findBinary() -> String? {
        // for testing the no-Paneru bar: defaults write io.github.knradf.ledge ignorePaneru -bool true
        if UserDefaults.standard.bool(forKey: "ignorePaneru") { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/paneru",
            "/usr/local/bin/paneru",
            "\(home)/.cargo/bin/paneru",
            "\(home)/.nix-profile/bin/paneru",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// No Paneru: the bar shows one "workspace" with the running apps.
    var appsOnly: Bool { binary == nil }

    func start() {
        guard binary != nil else {
            NSLog("Ledge: paneru binary not found, showing running apps")
            startAppsOnly()
            return
        }
        // Safety net: waking up and Space changes also refresh, so the bar
        // repairs itself even if Paneru's event stream goes quiet. (Not app
        // switches: Paneru reports those itself as window_focused.)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
            self?.reconnectNow()
        }
        queue.async { self.connect() }
    }

    // MARK: commands

    func go(to workspace: Int) {
        switchTo(workspace)
    }

    /// Main thread. Switches workspace, with Ledge's slide when it's on and
    /// can (it switches Paneru behind it), then runs `then` once Paneru has
    /// switched.
    private func switchTo(_ workspace: Int, then: (() -> Void)? = nil) {
        guard let binary else { return }
        let switching: (@escaping () -> Void) -> Void = { done in
            self.moveQueue.async {
                self.run(["send-cmd", "window", "virtualnum", "\(workspace)"], binary: binary) {
                    $0.event == "virtual_workspace_changed" && $0.workspace == workspace
                }
                DispatchQueue.main.async(execute: done)
            }
        }
        let wrapped: (@escaping () -> Void) -> Void = { done in
            switching {
                done()
                then?()
            }
        }
        if WorkspaceSlide.shared.slide(to: workspace, rows: rows, switching: wrapped) { return }
        wrapped {}
    }

    /// Focuses the app's window in that workspace, not just the app: an app
    /// with windows on several workspaces would otherwise raise whichever
    /// window it likes and Paneru would follow it somewhere else.
    func focus(_ app: WorkspaceApp, in workspace: Int) {
        if appsOnly {
            Self.activate(app)
            return
        }
        let windows = self.windows(of: app, in: workspace)
        // already on one of its windows: go to the next (like ⌘`), so every
        // window is reachable, including floating ones stacked behind a tile
        let next = windows.firstIndex(where: { $0.focused }).map { (($0 + 1) % windows.count) } ?? 0
        if !windows.isEmpty {
            focusWindow(windows[next], in: workspace)
            return
        }
        guard let binary else { return }
        queue.async {
            _ = Shell.run(binary, ["send-cmd", "window", "virtualnum", "\(workspace)"])
            DispatchQueue.main.async { Self.activate(app) }
        }
    }

    /// The app's windows in a workspace, in strip order (floating ones last).
    func windows(of app: WorkspaceApp, in workspace: Int) -> [OverviewWindow] {
        rows.first(where: { $0.number == workspace })?.windows
            .filter { ($0.bundleID ?? $0.appName) == app.id } ?? []
    }

    /// One workspace up or down from the one on screen. Down stops at the
    /// empty one after the last used workspace.
    func step(above: Bool) {
        guard !appsOnly else { return }
        let all = workspaces.withEmpty()
        guard let current = all.first(where: { $0.active })?.number else { return }
        let target = above ? current - 1 : current + 1
        guard all.contains(where: { $0.number == target }) else { return }
        go(to: target)
    }

    func refresh() {
        queue.async { self.scheduleRefresh() }
    }

    /// Switches to the workspace, then focuses that exact window (needs
    /// Accessibility; falls back to activating its app). Waits for the
    /// switch to land first, so Paneru's own focus on arrival can't win.
    func focusWindow(_ window: OverviewWindow, in workspace: Int) {
        guard binary != nil else { return }
        let focus = {
            self.moveQueue.async { self.focusNow(window) }
        }
        if rows.first(where: { $0.active })?.number == workspace {
            focus()
        } else {
            switchTo(workspace, then: focus)
        }
    }

    /// Runs on `moveQueue`.
    private func focusNow(_ window: OverviewWindow) {
        if WindowFocus.focus(windowID: window.id) { return }
        DispatchQueue.main.async {
            Self.activate(WorkspaceApp(
                id: window.bundleID ?? window.appName,
                bundleID: window.bundleID,
                name: window.appName,
                count: 1,
                focused: false
            ))
        }
    }

    /// Where in a workspace's strip a moved window should end up.
    enum StripPlace: Equatable {
        /// wherever Paneru puts it
        case any
        case first
        /// right after this window
        case after(CGWindowID)
    }

    /// Moves one window to a workspace (and a place in its strip), then shows
    /// `show`, the workspace you were on. Paneru only moves the focused
    /// window, so this focuses it first and checks that it really is focused:
    /// if anything else has focus, nothing is moved. Every step waits for
    /// Paneru to report it done, not for a fixed time.
    func moveWindow(_ id: CGWindowID, to target: Int, place: StripPlace = .any, thenShow show: Int?,
                    completion: ((Bool) -> Void)? = nil) {
        guard let binary else {
            completion?(false)
            return
        }
        moveQueue.async {
            var ok = self.focusForMove(id, binary: binary)
            if ok, self.queryState()?.workspace(containing: id)?.number != target {
                ok = self.run(["send-cmd", "window", "virtualsendnum", "\(target)"], binary: binary) {
                    $0.event == "windows_changed"
                } || self.queryState()?.workspace(containing: id)?.number == target
            }
            if ok, place != .any {
                ok = self.reorder(id, to: place, binary: binary)
            }
            if let show {
                self.run(["send-cmd", "window", "virtualnum", "\(show)"], binary: binary) {
                    $0.event == "virtual_workspace_changed" && $0.workspace == show
                }
            }
            let state = self.queryState()
            self.queue.async { self.publish(state) }
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// Runs on `moveQueue`. Swaps the window along its strip (Paneru's
    /// ⌥⌃H / ⌥⌃L / ⌥⌃Home / ⌥⌃End) until it sits where it should.
    private func reorder(_ id: CGWindowID, to place: StripPlace, binary: String) -> Bool {
        guard focusForMove(id, binary: binary) else { return false }
        var lastIndex: Int?
        var stuck = 0
        for _ in 0..<24 {
            guard let state = queryState(),
                  let workspace = state.virtualWorkspaces.first(where: { vw in
                      vw.windows.contains { CGWindowID(truncatingIfNeeded: $0.windowId) == id }
                  })
            else { return false }
            let ids = workspace.windows.map { CGWindowID(truncatingIfNeeded: $0.windowId) }
            guard let i = ids.firstIndex(of: id) else { return false }

            let desired: Int
            switch place {
            case .any:
                return true
            case .first:
                desired = 0
            case .after(let neighbor):
                // neighbor gone meanwhile: leave it where it is
                guard let j = ids.firstIndex(of: neighbor) else { return true }
                desired = i < j ? j : j + 1
            }
            if i == desired { return true }

            // a swap that changes nothing means Paneru can't do it: stop
            if i == lastIndex {
                stuck += 1
                if stuck >= 2 { return false }
            }
            lastIndex = i

            let direction: String
            if desired == 0 {
                direction = "first"
            } else if desired == ids.count - 1 {
                direction = "last"
            } else {
                direction = desired < i ? "west" : "east"
            }
            run(["send-cmd", "window", "swap", direction], binary: binary) { $0.event == "windows_changed" }
        }
        return false
    }

    /// Runs on `moveQueue`. Focuses the window (switching to its workspace if
    /// it's parked) and waits until Paneru reports it focused.
    private func focusForMove(_ id: CGWindowID, binary: String) -> Bool {
        for _ in 0..<2 {
            guard let state = queryState(), let home = state.workspace(containing: id) else { return false }
            if home.active && state.focusedWindowID == id { return true }
            if !home.active {
                run(["send-cmd", "window", "virtualnum", "\(home.number)"], binary: binary) {
                    $0.event == "virtual_workspace_changed" && $0.workspace == home.number
                }
            }
            let focused = expect { $0.event == "window_focused" && $0.windowId == Int(id) }
            guard WindowFocus.focus(windowID: id) else {
                _ = wait(for: focused, timeout: 0)
                return false
            }
            if wait(for: focused, timeout: Self.stepTimeout) { return true }
            // no word from Paneru: the second round looks at its state again
        }
        return false
    }

    /// The workspace on screen right now, straight from Paneru (off main).
    func activeWorkspace(_ completion: @escaping (Int?) -> Void) {
        queue.async {
            let number = self.queryState()?.activeNumber
            DispatchQueue.main.async { completion(number) }
        }
    }

    /// Brings an app forward: jumps to the workspace holding its window first
    /// if it has one, otherwise just activates it (which opens a window).
    func open(bundleID: String) {
        for workspace in workspaces {
            if let app = workspace.apps.first(where: { $0.bundleID == bundleID }) {
                focus(app, in: workspace.number)
                return
            }
        }
        Self.activate(WorkspaceApp(id: bundleID, bundleID: bundleID, name: "", count: 1, focused: false))
    }

    // MARK: without Paneru

    /// Follows app launches, quits and switches; no timer.
    private func startAppsOnly() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.publishRunningApps()
            }
        }
        publishRunningApps()
    }

    /// The apps in the Dock's running section, in launch order.
    private func publishRunningApps() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { app in
                WorkspaceApp(
                    id: app.bundleIdentifier ?? app.localizedName ?? "?",
                    bundleID: app.bundleIdentifier,
                    name: app.localizedName ?? "",
                    count: 1,
                    focused: app.processIdentifier == front
                )
            }
        let next = [Workspace(number: 1, active: true, apps: apps)]
        if workspaces != next { workspaces = next }
    }

    // MARK: connection (runs on `queue`)

    /// while Paneru isn't there: 1 s, 2 s, 4 s... up to this, so a stopped
    /// Paneru doesn't cost a process launch every second forever
    static let maxRetryDelay: TimeInterval = 30
    private var retryDelay: TimeInterval = 1
    private var pendingConnect: DispatchWorkItem?

    private func connectLater(_ delay: TimeInterval) {
        pendingConnect?.cancel()
        let work = DispatchWorkItem { self.connect() }
        pendingConnect = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Wake, or Paneru restarted from Ledge: don't wait out the back-off.
    func reconnectNow() {
        queue.async {
            guard self.subscriber == nil else { return }
            self.retryDelay = 1
            self.connectLater(0)
        }
    }

    private func connect() {
        guard let binary, subscriber == nil else { return }
        guard let state = queryState() else {
            publish(nil)
            connectLater(retryDelay)
            retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
            return
        }
        retryDelay = 1
        publish(state)
        DispatchQueue.main.async { self.sessions += 1 }
        // give Paneru a moment to finish restoring the layout, then follow its events
        queue.asyncAfter(deadline: .now() + 2) {
            self.scheduleRefresh()
            self.startSubscriber(binary)
        }
    }

    private func startSubscriber(_ binary: String) {
        guard subscriber == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["subscribe", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }

        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                self.subscriber = nil
                self.buffer.removeAll()
                self.publish(self.queryState())
                self.connectLater(2)
            }
        }

        do {
            try process.run()
            subscriber = process
        } catch {
            connectLater(2)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = Self.decodeEvent(line) {
                deliver(event)
                if Self.ignoredEvents.contains(event.event) { continue }
            }
            scheduleRefresh()
        }
    }

    /// One line of `paneru subscribe --json`, the fields the move flow needs.
    struct StreamEvent: Decodable {
        let event: String
        let windowId: Int?
        let virtualWorkspaceNumber: Int?
        let active: Active?

        struct Active: Decodable {
            let virtualWorkspaceNumber: Int?
        }

        /// the workspace it's about (the one now on screen, for a switch)
        var workspace: Int? { active?.virtualWorkspaceNumber ?? virtualWorkspaceNumber }
    }

    private static func decodeEvent(_ line: Data) -> StreamEvent? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(StreamEvent.self, from: line)
    }

    // MARK: waiting for Paneru

    /// A step waiting for Paneru to report something (focus landed, window
    /// moved, workspace switched) instead of sleeping and hoping.
    private final class EventWait {
        let matches: (StreamEvent) -> Bool
        let done = DispatchSemaphore(value: 0)
        init(_ matches: @escaping (StreamEvent) -> Bool) { self.matches = matches }
    }

    private let waitLock = NSLock()
    private var waits: [EventWait] = []

    /// Register before sending the command, so even an instant answer is caught.
    private func expect(_ matches: @escaping (StreamEvent) -> Bool) -> EventWait {
        let wait = EventWait(matches)
        waitLock.lock()
        waits.append(wait)
        waitLock.unlock()
        return wait
    }

    /// Blocks (on `moveQueue`) until it happened, or the timeout passed.
    private func wait(for wait: EventWait, timeout: TimeInterval) -> Bool {
        let happened = wait.done.wait(timeout: .now() + timeout) == .success
        waitLock.lock()
        waits.removeAll { $0 === wait }
        waitLock.unlock()
        return happened
    }

    /// Runs on `queue`, for every event.
    private func deliver(_ event: StreamEvent) {
        waitLock.lock()
        let matched = waits.filter { $0.matches(event) }
        waits.removeAll { wait in matched.contains { $0 === wait } }
        waitLock.unlock()
        matched.forEach { $0.done.signal() }
    }

    /// Sends a command and waits for the event saying it took effect.
    @discardableResult
    private func run(_ arguments: [String], binary: String, until matches: @escaping (StreamEvent) -> Bool,
                     timeout: TimeInterval = PaneruStore.stepTimeout) -> Bool {
        let wait = expect(matches)
        _ = Shell.run(binary, arguments)
        return self.wait(for: wait, timeout: timeout)
    }

    /// Paneru answers within a few ms; this long only if something is off,
    /// and then the step checks Paneru's state instead.
    static let stepTimeout: TimeInterval = 0.6

    /// Events that can't change anything Ledge shows. on_screen_changed alone
    /// means windows moved or resized (every frame of a strip scroll) or a
    /// title changed (a terminal spinner changes it several times a second);
    /// anything that rearranges workspaces also sends windows_changed or
    /// virtual_workspace_changed. Window frames come from macOS, not Paneru.
    private static let ignoredEvents: Set<String> = ["on_screen_changed", "window_title_changed"]

    /// Coalesces bursts of events (scrolling the strip fires many) into one query.
    /// A lone event is answered right away (after a few ms, to let a
    /// burst gather); a burst (scrolling the strip) at most every 120 ms.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        let now = ProcessInfo.processInfo.systemUptime
        let wait = max(0.015, lastQuery + Self.minQueryInterval - now)
        queue.asyncAfter(deadline: .now() + wait) {
            self.refreshPending = false
            self.lastQuery = ProcessInfo.processInfo.systemUptime
            self.publish(self.queryState())
        }
    }

    private func queryState() -> PaneruState? {
        guard let binary, let data = Shell.run(binary, ["query", "state", "--json"]) else {
            report("paneru query state didn't answer")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let state = try decoder.decode(PaneruState.self, from: data)
            problemLock.lock()
            lastProblem = nil
            problemLock.unlock()
            return state
        } catch {
            // most likely a Paneru update changed its JSON
            let start = String(decoding: data.prefix(300), as: UTF8.self)
            report("can't read paneru's state: \(error) | starts with: \(start)")
            return nil
        }
    }

    /// Logs each distinct problem once (runs on `queue`).
    private var lastProblem: String?
    private let problemLock = NSLock()
    private func report(_ problem: String) {
        problemLock.lock()
        defer { problemLock.unlock() }
        guard problem != lastProblem else { return }
        lastProblem = problem
        NSLog("Ledge: %@", problem)
    }

    private func publish(_ state: PaneruState?) {
        let next = state?.workspaces ?? []
        let nextRows = state?.overviewRows ?? []
        let nextSnapshot = state?.snapshot ?? PaneruSnapshot()
        let isConnected = state != nil
        trackFailure(answered: isConnected)
        DispatchQueue.main.async {
            // A failed query keeps the last workspaces on screen (the bar dims
            // them) instead of blanking the bar. The rules engine still gets
            // the empty snapshot, so it starts over when Paneru is back.
            if isConnected || self.binary == nil {
                if self.workspaces != next { self.workspaces = next }
                if self.rows != nextRows { self.rows = nextRows }
            }
            if self.snapshot != nextSnapshot { self.snapshot = nextSnapshot }
            if self.connected != isConnected { self.connected = isConnected }
        }
    }

    /// Runs on `queue`. A few seconds of failed queries in a row counts as
    /// "not answering"; one good answer clears it.
    private func trackFailure(answered: Bool) {
        if answered {
            failingSince = nil
            DispatchQueue.main.async { if self.notAnswering { self.notAnswering = false } }
            return
        }
        guard failingSince == nil else { return }
        let since = Date()
        failingSince = since
        queue.asyncAfter(deadline: .now() + 3) {
            guard self.failingSince == since else { return }
            // still failing: check once more, then tell
            if self.queryState() == nil {
                DispatchQueue.main.async { if !self.notAnswering { self.notAnswering = true } }
            } else {
                self.scheduleRefresh()
            }
        }
    }

    /// Paneru's own restart (what ⌥⇧E does).
    func restartPaneru() {
        guard let binary else { return }
        queue.async {
            _ = Shell.run(binary, ["stop"])
            usleep(500_000)
            _ = Shell.run(binary, ["start"])
            self.queue.asyncAfter(deadline: .now() + 2) { self.scheduleRefresh() }
            self.reconnectNow()
        }
    }

    var binaryFound: Bool { binary != nil }

    private static func activate(_ app: WorkspaceApp) {
        let url: URL?
        if let bundle = app.bundleID {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        } else {
            url = NSWorkspace.shared.runningApplications
                .first { $0.localizedName == app.name }?
                .bundleURL
        }
        guard let url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }
}
