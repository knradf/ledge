import CoreGraphics
import Foundation

/// `paneru query state --json`, decoded with snake_case conversion.
struct PaneruState: Decodable {
    struct Active: Decodable {
        let nativeWorkspaceId: Int?
        let virtualWorkspaceNumber: Int?
    }

    struct Window: Decodable {
        let windowId: Int
        let bundleId: String?
        let appName: String?
        let title: String?
        let focused: Bool?
        let floating: Bool?
    }

    struct VirtualWorkspace: Decodable {
        let number: Int
        let nativeWorkspaceId: Int?
        let active: Bool
        let windows: [Window]
    }

    let active: Active?
    let virtualWorkspaces: [VirtualWorkspace]
}

/// One app inside a workspace; several windows of the same app are merged.
struct WorkspaceApp: Identifiable, Equatable {
    let id: String
    let bundleID: String?
    let name: String
    var count: Int
    var focused: Bool
}

struct Workspace: Identifiable, Equatable {
    let number: Int
    let active: Bool
    let apps: [WorkspaceApp]

    var id: Int { number }
}

extension PaneruState {
    /// Workspaces of the visible macOS Space: the non-empty ones plus the active one.
    var workspaces: [Workspace] {
        let nativeID = active?.nativeWorkspaceId
        return virtualWorkspaces
            .filter { nativeID == nil || $0.nativeWorkspaceId == nativeID }
            .filter { !$0.windows.isEmpty || $0.active }
            .map { vw in
                var apps: [WorkspaceApp] = []
                for w in vw.windows {
                    let bundle = (w.bundleId?.isEmpty == false) ? w.bundleId : nil
                    let name = w.appName ?? ""
                    let key = bundle ?? (name.isEmpty ? "?" : name)
                    if let i = apps.firstIndex(where: { $0.id == key }) {
                        apps[i].count += 1
                        apps[i].focused = apps[i].focused || (w.focused ?? false)
                    } else {
                        apps.append(WorkspaceApp(id: key, bundleID: bundle, name: name, count: 1, focused: w.focused ?? false))
                    }
                }
                return Workspace(number: vw.number, active: vw.active, apps: apps)
            }
    }
}

/// One window as the overview shows it.
struct OverviewWindow: Identifiable, Equatable {
    let id: CGWindowID
    let bundleID: String?
    let appName: String
    let title: String
    let focused: Bool
}

/// One workspace row in the overview, windows in strip order.
struct OverviewRow: Identifiable, Equatable {
    let number: Int
    let active: Bool
    let windows: [OverviewWindow]
    var id: Int { number }
}

extension PaneruState {
    /// Same workspaces as the bar (visible Space; non-empty plus the active one),
    /// but every window kept separately.
    var overviewRows: [OverviewRow] {
        let nativeID = active?.nativeWorkspaceId
        return virtualWorkspaces
            .filter { nativeID == nil || $0.nativeWorkspaceId == nativeID }
            .filter { !$0.windows.isEmpty || $0.active }
            .map { vw in
                OverviewRow(
                    number: vw.number,
                    active: vw.active,
                    windows: vw.windows.map { w in
                        OverviewWindow(
                            id: CGWindowID(truncatingIfNeeded: w.windowId),
                            bundleID: (w.bundleId?.isEmpty == false) ? w.bundleId : nil,
                            appName: w.appName ?? "",
                            title: w.title ?? "",
                            focused: w.focused ?? false
                        )
                    }
                )
            }
    }
}

extension PaneruState {
    /// The window Paneru considers focused, if any.
    /// Looks at the workspace on screen first, in case Paneru remembers a
    /// focused window per workspace.
    var focusedWindowID: CGWindowID? {
        for vw in virtualWorkspaces.sorted(by: { $0.active && !$1.active }) {
            if let w = vw.windows.first(where: { $0.focused == true }) {
                return CGWindowID(truncatingIfNeeded: w.windowId)
            }
        }
        return nil
    }

    /// The workspace holding a window, and whether it's the one on screen.
    func workspace(containing id: CGWindowID) -> (number: Int, active: Bool)? {
        for vw in virtualWorkspaces where vw.windows.contains(where: { CGWindowID(truncatingIfNeeded: $0.windowId) == id }) {
            return (vw.number, vw.active)
        }
        return nil
    }

    /// The workspace on screen (on the visible macOS Space).
    var activeNumber: Int? {
        if let number = active?.virtualWorkspaceNumber { return number }
        let nativeID = active?.nativeWorkspaceId
        return virtualWorkspaces.first { $0.active && (nativeID == nil || $0.nativeWorkspaceId == nativeID) }?.number
    }
}

/// Workspace numbers to show when empty ones are included: every number from
/// 1 up to the last one with windows, plus one empty after it (like niri),
/// and always the one on screen.
func workspaceNumbersWithEmpty(used: [Int], active: Int?) -> ClosedRange<Int> {
    let last = used.max() ?? 0
    let upper = max(last + 1, active ?? 1, 1)
    return 1...upper
}

extension Array where Element == Workspace {
    /// Fills in the empty workspaces between and after the used ones.
    func withEmpty() -> [Workspace] {
        let used = filter { !$0.apps.isEmpty }.map { $0.number }
        let active = first(where: { $0.active })?.number
        let byNumber = Dictionary(map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        return workspaceNumbersWithEmpty(used: used, active: active).map { number in
            byNumber[number] ?? Workspace(number: number, active: false, apps: [])
        }
    }
}

extension Array where Element == OverviewRow {
    /// Fills in the empty workspaces between and after the used ones.
    func withEmpty() -> [OverviewRow] {
        let used = filter { !$0.windows.isEmpty }.map { $0.number }
        let active = first(where: { $0.active })?.number
        let byNumber = Dictionary(map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        return workspaceNumbersWithEmpty(used: used, active: active).map { number in
            byNumber[number] ?? OverviewRow(number: number, active: false, windows: [])
        }
    }
}

/// Every window Paneru knows, on every macOS Space (full-screen apps
/// included), plus which Space is on screen. For the window rules, which
/// mustn't mistake a window coming back from another Space for a new one.
struct PaneruSnapshot: Equatable {
    var rows: [OverviewRow] = []
    var space: Int?
}

extension PaneruState {
    var snapshot: PaneruSnapshot {
        PaneruSnapshot(
            rows: virtualWorkspaces.map { vw in
                OverviewRow(
                    number: vw.number,
                    active: vw.active,
                    windows: vw.windows.map { w in
                        OverviewWindow(
                            id: CGWindowID(truncatingIfNeeded: w.windowId),
                            bundleID: (w.bundleId?.isEmpty == false) ? w.bundleId : nil,
                            appName: w.appName ?? "",
                            title: w.title ?? "",
                            focused: w.focused ?? false
                        )
                    }
                )
            },
            space: active?.nativeWorkspaceId
        )
    }
}
