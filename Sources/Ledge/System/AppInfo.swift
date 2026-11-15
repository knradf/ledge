import AppKit

/// App names and icons by bundle id, cached.
enum AppInfo {
    private static var names: [String: String] = [:]

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        var name = bundleID.components(separatedBy: ".").last ?? bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        }
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String) -> NSImage {
        IconCache.shared.icon(for: WorkspaceApp(id: bundleID, bundleID: bundleID, name: name(for: bundleID), count: 1, focused: false))
    }
}
