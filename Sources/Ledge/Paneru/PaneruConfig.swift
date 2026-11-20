import Foundation

/// Paneru's config file, edited the careful way: only the lines you change in
/// Ledge's Settings (see PaneruSettings), one at a time, comments kept, a
/// backup the first time. Paneru reloads the file on save.
enum PaneruConfig {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/paneru/paneru.toml")
    }

    // MARK: one line of the file

    /// A key's raw value in a [section]; nil when the file or line isn't there.
    static func value(_ key: String, in section: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return value(key, in: section, text: text)
    }

    static func value(_ key: String, in section: String, text: String) -> String? {
        var current = ""
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                current = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            if current == section, let value = assignment(key, in: trimmed) { return value }
        }
        return nil
    }

    /// Sets one line, keeping a backup of the file the first time. Paneru
    /// reloads its config on save.
    @discardableResult
    static func set(_ key: String, in section: String, to value: String) -> Bool {
        set([(key: key, section: section, value: value)])
    }

    /// Several lines in one save, so Paneru reloads once.
    @discardableResult
    static func set(_ changes: [(key: String, section: String, value: String)]) -> Bool {
        edit(changes.map { (key: $0.key, section: $0.section, value: Optional($0.value)) })
    }

    /// Like set, but a nil value takes the line out.
    @discardableResult
    static func edit(_ changes: [(key: String, section: String, value: String?)]) -> Bool {
        guard !changes.isEmpty, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let backup = url.appendingPathExtension("ledge-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? text.write(to: backup, atomically: true, encoding: .utf8)
        }
        let updated = changes.reduce(text) { text, change in
            guard let value = change.value else { return removing(change.key, in: change.section, text: text) }
            return setting(change.key, in: change.section, to: value, text: text)
        }
        guard updated != text else { return true }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// The text with that one line changed (or added), comments and the rest untouched.
    static func setting(_ key: String, in section: String, to value: String, text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var current = ""
        var headerIndex: Int?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                current = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                if current == section { headerIndex = i }
                continue
            }
            if current == section, assignment(key, in: trimmed) != nil, let equals = line.firstIndex(of: "=") {
                // only the value changes: alignment and comments stay
                let rest = line[line.index(after: equals)...]
                var comment = ""
                if let hash = rest.firstIndex(of: "#") {
                    let old = rest[..<hash]
                    let spacing = old.reversed().prefix { $0 == " " || $0 == "\t" }
                    comment = (spacing.isEmpty ? " " : String(spacing)) + String(rest[hash...])
                }
                lines[i] = String(line[...equals]) + " " + value + comment
                return lines.joined(separator: "\n")
            }
        }
        if let headerIndex {
            lines.insert(key + " = " + value, at: headerIndex + 1)
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("[" + section + "]")
            lines.append(key + " = " + value)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The text without that one line.
    static func removing(_ key: String, in section: String, text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var current = ""
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                current = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            if current == section, assignment(key, in: trimmed) != nil {
                lines.remove(at: i)
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Every "key = value" line in a [section], in file order.
    static func entries(in section: String, text: String) -> [(key: String, value: String)] {
        var current = ""
        var found: [(key: String, value: String)] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                current = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard current == section, !trimmed.hasPrefix("#"),
                  let key = trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces),
                  !key.isEmpty, let value = assignment(key, in: trimmed)
            else { continue }
            found.append((key, value))
        }
        return found
    }

    // MARK: Ledge's own windows

    /// Paneru only manages apps with a Dock icon, and Ledge has one only
    /// while Settings is open: Paneru doesn't reliably notice that. These
    /// rules make it manage Ledge (it then tiles Settings) and keep the
    /// welcome floating. The bar and the overview are panels Paneru ignores.
    /// Paneru reads them when an app launches, so they apply from Ledge's
    /// next start.
    static let settingsRule = "windows.ledge_settings"
    static let welcomeRule = "windows.ledge_welcome"
    static let welcomeTitle = "Welcome to Ledge"

    static func addLedgeRules() {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              value("bundle_id", in: settingsRule, text: text) == nil
                || value("bundle_id", in: welcomeRule, text: text) == nil
        else { return }
        let id = "\"" + (Bundle.main.bundleIdentifier ?? "io.github.knradf.ledge") + "\""
        NSLog("Ledge: adding window rules for Ledge to paneru.toml")
        // keys go in right after the header, so in reverse
        set([
            (key: "manage", section: settingsRule, value: "true"),
            (key: "bundle_id", section: settingsRule, value: id),
            (key: "title", section: settingsRule, value: "\"^Ledge$\""),
            (key: "floating", section: welcomeRule, value: "true"),
            (key: "bundle_id", section: welcomeRule, value: id),
            (key: "title", section: welcomeRule, value: "\"^" + welcomeTitle + "$\""),
        ])
    }

    // MARK: Paneru's first launch

    /// On its first launch Paneru writes an init.lua that's only comments, and
    /// any init.lua switches paneru.toml off: Ledge can't change a thing and
    /// three-finger swipes stay off (they need fingers_count). Swaps that
    /// stub for a paneru.toml. Paneru picks its config file at launch, so
    /// true means it needs a restart.
    static func replaceLuaStub(ledgeSwipesVertically: Bool) -> Bool {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let lua = url.deletingLastPathComponent().appendingPathComponent("init.lua")
        let others = [url, home.appendingPathComponent(".paneru.toml"), home.appendingPathComponent(".paneru"),
                      home.appendingPathComponent(".paneru.lua")]
        guard !others.contains(where: { files.fileExists(atPath: $0.path) }),
              let script = try? String(contentsOf: lua, encoding: .utf8),
              script.components(separatedBy: "\n").allSatisfy({ line in
                  let trimmed = line.trimmingCharacters(in: .whitespaces)
                  return trimmed.isEmpty || trimmed.hasPrefix("--")
              })
        else { return false }
        // Paneru's own default file, plus the swipes Ledge expects and
        // column widths that stay on screen
        let toml = """
        # Paneru configuration

        [options]
        preset_column_widths = [0.33, 0.5, 0.66, 1]

        [bindings]
        \(PaneruShortcuts.defaultLines(superKey: .leftOption).joined(separator: "\n"))

        [swipe]
        continuous = false

        [swipe.gesture]
        fingers_count = 3
        vertical = \(ledgeSwipesVertically ? "false" : "true")

        [swipe.scroll]
        modifier = "lalt"                # left Option + scroll wheel slides the strip
        vertical_modifier = "shift"      # left Option + Shift + scroll wheel switches workspaces

        """
        do {
            try toml.write(to: url, atomically: true, encoding: .utf8)
            try files.removeItem(at: lua)
            return true
        } catch {
            NSLog("Ledge: couldn't replace Paneru's init.lua: \(error.localizedDescription)")
            return false
        }
    }

    /// "key = value  # comment" -> value
    private static func assignment(_ key: String, in line: String) -> String? {
        let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = code.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0] == key else { return nil }
        return parts[1]
    }
}
