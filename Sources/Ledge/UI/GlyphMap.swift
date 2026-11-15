import AppKit
import CoreText
import Foundation

/// App name -> sketchybar-app-font ligature (e.g. "Zen" -> ":zen_browser:").
///
/// The font and its map ship inside Ledge (the font is CC0), so glyphs work
/// without installing anything. macOS loads the font from
/// Contents/Resources/Fonts (ATSApplicationFontsPath in Info.plist); the map
/// is the icon_map.json from the same release. To update both:
/// scripts/update-glyphs.sh
final class GlyphMap {
    static let shared = GlyphMap()
    static let fontName = "sketchybar-app-font"

    private var exact: [String: String] = [:]
    private var prefixes: [(prefix: String, glyph: String)] = []
    private var fontLoaded = false

    var available: Bool { fontLoaded && !(exact.isEmpty && prefixes.isEmpty) }

    var missingReason: String {
        "The glyph font didn't load (build Ledge with build.sh so it's inside the app). Showing app icons instead."
    }

    /// the bundled font's version, e.g. "3.0.15"
    let version: String?

    init() {
        let resources = Bundle.main.resourceURL
        version = resources
            .flatMap { try? String(contentsOf: $0.appendingPathComponent("VERSION"), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        fontLoaded = NSFont(name: Self.fontName, size: 12) != nil
        // normally macOS has already loaded it; register it ourselves if not
        if !fontLoaded, let url = resources?.appendingPathComponent("Fonts/sketchybar-app-font.ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            fontLoaded = NSFont(name: Self.fontName, size: 12) != nil
        }

        if let url = resources?.appendingPathComponent("icon_map.json"),
           let data = try? Data(contentsOf: url) {
            load(data)
        }
    }

    func glyph(for appName: String) -> String {
        if let glyph = exact[appName] { return glyph }
        if let match = prefixes.first(where: { appName.hasPrefix($0.prefix) }) { return match.glyph }
        return ":default:"
    }

    private struct Entry: Decodable {
        let iconName: String
        let appNames: [String]
    }

    /// [{ "iconName": ":zen_browser:", "appNames": ["Zen", "Zen Browser"] }, ...]
    /// A trailing * on a name means "starts with".
    func load(_ data: Data) {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for entry in entries {
            for raw in entry.appNames {
                let name = raw.trimmingCharacters(in: .whitespaces)
                if name.hasSuffix("*") {
                    prefixes.append((String(name.dropLast()), entry.iconName))
                } else if exact[name] == nil {
                    exact[name] = entry.iconName
                }
            }
        }
    }
}
