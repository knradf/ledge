import AppKit
import Combine

/// Puts apps on their workspace when they open (Settings → Rules). You stay
/// on the workspace you're on.
///
/// Watches Paneru's windows. A window counts as "opening" when it's new and
/// its app either just launched or had no windows a moment ago, so an app
/// that's already open on workspace 1 can still open a second window there.
/// Windows that existed before Ledge (or Paneru) started are never moved.
final class WorkspaceRulesEngine {
    private weak var paneru: PaneruStore?
    private var subscriptions: Set<AnyCancellable> = []

    private var known: Set<CGWindowID> = []
    private var appsWithWindows: Set<String> = []
    private var lastSpace: Int??
    /// after (re)connecting, Paneru may report windows a few at a time
    private var settledAt: Date?

    static let settleTime: TimeInterval = 3
    static let launchWindow: TimeInterval = 30
    /// let the app finish putting its window up before moving it
    static let moveDelay: TimeInterval = 0.35

    func start(_ paneru: PaneruStore) {
        self.paneru = paneru
        paneru.$snapshot
            .sink { [weak self] snapshot in self?.update(snapshot) }
            .store(in: &subscriptions)
    }

    /// Looks at every window on every Space: a window coming back from a
    /// full-screen Space (or any other) is never mistaken for a new one.
    private func update(_ snapshot: PaneruSnapshot) {
        let rows = snapshot.rows
        // empty means Paneru is gone or restarting: start over once it's back
        guard !rows.isEmpty else {
            settledAt = nil
            return
        }
        let ids = Set(rows.flatMap { $0.windows.map { $0.id } })
        let apps = Set(rows.flatMap { $0.windows.compactMap { $0.bundleID } })
        let spaceChanged = lastSpace != nil && lastSpace! != snapshot.space
        defer {
            known = ids
            appsWithWindows = apps
            lastSpace = .some(snapshot.space)
        }
        // entering or leaving full screen (or switching Spaces) shuffles what
        // Paneru reports for a moment: never act on that
        if spaceChanged {
            settledAt = Date().addingTimeInterval(Self.settleTime)
            return
        }

        guard let settledAt else {
            self.settledAt = Date().addingTimeInterval(Self.settleTime)
            return
        }
        guard Date() >= settledAt else { return }

        let rules = LedgeSettings.shared.workspaceRules
        guard !rules.isEmpty else { return }

        let moves = Self.plan(
            rows: rows,
            known: known,
            appsWithWindows: appsWithWindows,
            rules: rules,
            launchedRecently: Self.launchedRecently
        )
        guard !moves.isEmpty else { return }
        let here = paneru?.rows.first(where: { $0.active })?.number

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moveDelay) { [weak self] in
            for move in moves {
                self?.paneru?.moveWindow(
                    move.window,
                    to: move.rule.workspace,
                    thenShow: here
                )
            }
        }
    }

    struct Move: Equatable {
        let window: CGWindowID
        let rule: WorkspaceRule
    }

    /// Which new windows go where. Pure, so it can be tested.
    static func plan(rows: [OverviewRow], known: Set<CGWindowID>, appsWithWindows: Set<String>,
                     rules: [WorkspaceRule], launchedRecently: (String) -> Bool) -> [Move] {
        var moves: [Move] = []
        for row in rows {
            for window in row.windows where !known.contains(window.id) {
                guard let bundle = window.bundleID,
                      let rule = rules.first(where: { $0.bundleID == bundle }),
                      rule.workspace != row.number,
                      launchedRecently(bundle) || !appsWithWindows.contains(bundle)
                else { continue }
                moves.append(Move(window: window.id, rule: rule))
            }
        }
        return moves
    }

    static func launchedRecently(_ bundleID: String) -> Bool {
        let cutoff = Date().addingTimeInterval(-launchWindow)
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { ($0.launchDate ?? .distantPast) > cutoff }
    }
}
