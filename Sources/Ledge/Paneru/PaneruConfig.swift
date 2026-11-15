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
        guard !changes.isEmpty, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let backup = url.appendingPathExtension("ledge-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? text.write(to: backup, atomically: true, encoding: .utf8)
        }
        let updated = changes.reduce(text) { text, change in
            setting(change.key, in: change.section, to: change.value, text: text)
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
            if current == section, assignment(key, in: trimmed) != nil {
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                let comment = line.range(of: "#").map { "   " + String(line[$0.lowerBound...]) } ?? ""
                lines[i] = indent + key + " = " + value + comment
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

    /// "key = value  # comment" -> value
    private static func assignment(_ key: String, in line: String) -> String? {
        let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = code.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0] == key else { return nil }
        return parts[1]
    }
}
