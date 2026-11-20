import AppKit
import Carbon

/// Paneru's keyboard shortcuts (its [bindings]) as Ledge shows them in
/// Settings → Shortcuts. Most shortcuts start with one Super key; change it
/// and every shortcut that uses it follows. Read from paneru.toml like
/// PaneruSettings, written at once (no sliders here). Paneru has no default
/// shortcuts at all, so Ledge brings its own (niri's layout).
final class PaneruShortcuts: ObservableObject {
    static let shared = PaneruShortcuts()
    static let section = "bindings"

    /// what's in [bindings]: the command, then its shortcuts
    @Published private(set) var bindings: [String: [KeyCombo]] = [:]
    @Published private(set) var superKey = SuperKey.leftOption

    private init() {
        reload()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    // MARK: reading

    func reload() {
        guard let text = try? String(contentsOf: PaneruConfig.url, encoding: .utf8) else {
            if !bindings.isEmpty { bindings = [:] }
            return
        }
        var found: [String: [KeyCombo]] = [:]
        for entry in PaneruConfig.entries(in: Self.section, text: text) {
            found[entry.key] = Self.parseValue(entry.value).compactMap(KeyCombo.init(raw:))
        }
        if found != bindings { bindings = found }
        let key = UserDefaults.standard.string(forKey: "shortcutSuper").flatMap(SuperKey.init) ?? Self.guessSuper(found)
        if key != superKey { superKey = key }
    }

    /// "a" or ["a", "b"] -> [a, b]
    static func parseValue(_ raw: String) -> [String] {
        raw.components(separatedBy: "\"").enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { $0.element }
    }

    static func formatValue(_ combos: [KeyCombo]) -> String {
        let quoted = combos.map { "\"" + $0.raw + "\"" }
        return quoted.count == 1 ? quoted[0] : "[" + quoted.joined(separator: ", ") + "]"
    }

    /// Before you pick one: the Super key most shortcuts already use.
    static func guessSuper(_ bindings: [String: [KeyCombo]]) -> SuperKey {
        let combos = bindings.values.flatMap { $0 }
        let best = SuperKey.allCases.max { a, b in
            combos.filter { $0.uses(a) }.count < combos.filter { $0.uses(b) }.count
        }
        guard let best, combos.contains(where: { $0.uses(best) }) else { return .leftOption }
        return best
    }

    /// Numbered actions answer with workspace 1's, standing for all nine.
    func combos(for action: ShortcutAction) -> [KeyCombo] {
        if action == .overview { return KeyCombo(raw: LedgeSettings.shared.overviewKey).map { [$0] } ?? [] }
        if action.numbered { return bindings[action.command(1)] ?? [] }
        return action.commands.flatMap { bindings[$0] ?? [] }
    }

    /// Other actions with the same shortcut, for a warning.
    func conflicts(_ combo: KeyCombo, besides action: ShortcutAction) -> [ShortcutAction] {
        ShortcutAction.all.filter { other in
            other != action && combos(for: other).contains { $0.sameKeys(as: combo) }
        }
    }

    // MARK: changing

    /// The action's shortcuts, all of them; an empty list takes it out.
    func set(_ action: ShortcutAction, _ combos: [KeyCombo]) {
        if action == .overview {
            LedgeSettings.shared.overviewKey = combos.first?.raw ?? ""
            return
        }
        var changes: [(key: String, section: String, value: String?)] = []
        if action.numbered {
            for n in 1...9 {
                let numbered = combos.map { KeyCombo(tokens: $0.tokens, key: String(n)) }
                let key = action.command(n)
                bindings[key] = numbered.isEmpty ? nil : numbered
                changes.append((key, Self.section, numbered.isEmpty ? nil : Self.formatValue(numbered)))
            }
        } else {
            // the first command is the one Ledge writes; aliases go
            for (i, key) in action.commands.enumerated() {
                let value = i == 0 && !combos.isEmpty ? combos : nil
                guard value != nil || bindings[key] != nil else { continue }
                bindings[key] = value
                changes.append((key, Self.section, value.map(Self.formatValue)))
            }
        }
        PaneruConfig.edit(changes)
    }

    func setSuper(_ key: SuperKey) {
        let old = superKey
        guard key != old else { return }
        superKey = key
        UserDefaults.standard.set(key.rawValue, forKey: "shortcutSuper")
        var changes: [(key: String, section: String, value: String?)] = []
        for (command, combos) in bindings where combos.contains(where: { $0.uses(old) }) {
            let moved = combos.map { $0.replacingSuper(old, with: key) }
            bindings[command] = moved
            changes.append((command, Self.section, Self.formatValue(moved)))
        }
        if let overview = KeyCombo(raw: LedgeSettings.shared.overviewKey), overview.uses(old) {
            LedgeSettings.shared.overviewKey = overview.replacingSuper(old, with: key).raw
        }
        // Super + scroll wheel slides the strip
        if let scroll = PaneruConfig.value("modifier", in: "swipe.scroll"),
           Self.parseValue(scroll).first == old.rawValue {
            changes.append(("modifier", "swipe.scroll", "\"" + key.rawValue + "\""))
        }
        PaneruConfig.edit(changes)
    }

    /// Ledge's shortcuts for every action, replacing what's there for them.
    /// Commands Ledge doesn't know stay as they are.
    func restoreDefaults() {
        var changes: [(key: String, section: String, value: String?)] = []
        LedgeSettings.shared.overviewKey = KeyCombo(tokens: superKey.tokens, key: "o").raw
        let defaults = Self.defaults(superKey: superKey)
        for action in ShortcutAction.all where action != .overview {
            for key in action.allCommands {
                let value = defaults[key]
                guard value != nil || bindings[key] != nil else { continue }
                bindings[key] = value
                changes.append((key, Self.section, value.map(Self.formatValue)))
            }
        }
        PaneruConfig.edit(changes)
    }

    /// On a first run: a config without a single shortcut gets Ledge's.
    func fillDefaultsIfEmpty() {
        reload()
        guard PaneruSettings.shared.editable, bindings.isEmpty else { return }
        NSLog("Ledge: Paneru has no shortcuts, adding Ledge's")
        restoreDefaults()
    }

    // MARK: Ledge's defaults (niri's layout, Super = Mod)

    /// extra modifiers and keys, per command; Super comes first in each
    private static let defaultSpec: [(String, [(String, String)])] = {
        var spec: [(String, [(String, String)])] = [
            ("window_focus_west", [("", "h")]),
            ("window_focus_east", [("", "l")]),
            ("window_focus_south", [("", "j")]),
            ("window_focus_north", [("", "k")]),
            ("window_focus_first", [("", "home")]),
            ("window_focus_last", [("", "end")]),
            ("window_swap_west", [("ctrl", "h"), ("ctrl", "leftarrow")]),
            ("window_swap_east", [("ctrl", "l"), ("ctrl", "rightarrow")]),
            ("window_swap_south", [("ctrl", "j"), ("ctrl", "downarrow")]),
            ("window_swap_north", [("ctrl", "k"), ("ctrl", "uparrow")]),
            ("window_swap_first", [("ctrl", "home")]),
            ("window_swap_last", [("ctrl", "end")]),
            ("window_stack", [("", "leftbracket"), ("", "comma")]),
            ("window_unstack", [("", "rightbracket"), ("", "period")]),
            ("window_resize", [("", "r"), ("", "equal")]),
            ("window_shrink", [("", "minus")]),
            ("window_vertical_resize", [("shift", "r"), ("shift", "equal")]),
            ("window_vertical_shrink", [("shift", "minus")]),
            ("window_equalize", [("ctrl", "r")]),
            ("window_fullwidth", [("", "f")]),
            ("window_center", [("", "c")]),
            ("window_manage", [("", "v")]),
            ("window_focus_unmanaged", [("shift", "v")]),
            ("window_virtual_south", [("", "u"), ("", "pagedown")]),
            ("window_virtual_north", [("", "i"), ("", "pageup")]),
            ("window_virtualmove_south", [("ctrl", "u"), ("ctrl", "pagedown")]),
            ("window_virtualmove_north", [("ctrl", "i"), ("ctrl", "pageup")]),
            ("window_nextdisplay", [("shift + ctrl", "h"), ("shift + ctrl", "l")]),
            ("restart", [("shift", "e")]),
        ]
        for n in 1...9 {
            spec.append(("window_virtualnum_\(n)", [("", "\(n)")]))
            spec.append(("window_virtualmovenum_\(n)", [("ctrl", "\(n)")]))
        }
        return spec
    }()

    static func defaults(superKey: SuperKey) -> [String: [KeyCombo]] {
        var result: [String: [KeyCombo]] = [:]
        for (command, combos) in defaultSpec {
            result[command] = combos.map { extras, key in
                // an extra that's part of Super already (Control with Control + Option) goes
                let more = extras.isEmpty ? [] : extras.components(separatedBy: " + ")
                    .filter { token in !superKey.families.contains { $0 == ModifierFamily(token: token) } }
                return KeyCombo(tokens: superKey.tokens + more, key: key)
            }
        }
        return result
    }

    /// "command = value" lines for a new paneru.toml
    static func defaultLines(superKey: SuperKey) -> [String] {
        let defaults = defaults(superKey: superKey)
        return defaultSpec.map { command, _ in command + " = " + formatValue(defaults[command] ?? []) }
    }
}

// MARK: the Super key

enum SuperKey: String, CaseIterable, Identifiable {
    case leftOption = "lalt"
    case rightOption = "ralt"
    case option = "alt"
    case leftCommand = "lcmd"
    case rightCommand = "rcmd"
    case command = "cmd"
    case control = "ctrl"
    case controlOption = "ctrl + alt"

    var id: String { rawValue }
    var tokens: [String] { rawValue.components(separatedBy: " + ") }
    var families: Set<ModifierFamily> { Set(tokens.compactMap(ModifierFamily.init(token:))) }

    var label: String {
        switch self {
        case .leftOption: return "Left Option (⌥)"
        case .rightOption: return "Right Option (⌥)"
        case .option: return "Either Option (⌥)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightCommand: return "Right Command (⌘)"
        case .command: return "Either Command (⌘)"
        case .control: return "Control (⌃)"
        case .controlOption: return "Control + Option (⌃⌥)"
        }
    }
}

/// a modifier, whichever side
enum ModifierFamily: Int, Comparable {
    // Apple's order: ⌃⌥⇧⌘
    case control, option, shift, command, function

    init?(token: String) {
        switch token {
        case "ctrl", "lctrl", "rctrl": self = .control
        case "alt", "lalt", "ralt": self = .option
        case "shift", "lshift", "rshift": self = .shift
        case "cmd", "lcmd", "rcmd": self = .command
        case "fn": self = .function
        default: return nil
        }
    }

    var token: String {
        switch self {
        case .control: return "ctrl"
        case .option: return "alt"
        case .shift: return "shift"
        case .command: return "cmd"
        case .function: return "fn"
        }
    }

    var glyph: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        case .function: return "fn"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: one shortcut

/// One of Paneru's "lalt + ctrl - h" strings.
struct KeyCombo: Hashable {
    /// modifiers as Paneru spells them, Super's first
    var tokens: [String]
    /// Paneru's key name ("h", "leftarrow", "minus")
    var key: String

    init(tokens: [String], key: String) {
        self.tokens = tokens
        self.key = key
    }

    init?(raw: String) {
        let parts = raw.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty, parts.count <= 2 else { return nil }
        self.key = key
        tokens = parts.count == 2 ? parts[0].components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) } : []
    }

    var raw: String { tokens.isEmpty ? key : tokens.joined(separator: " + ") + " - " + key }

    func uses(_ superKey: SuperKey) -> Bool { Set(superKey.tokens).isSubset(of: Set(tokens)) }

    func replacingSuper(_ old: SuperKey, with new: SuperKey) -> KeyCombo {
        guard uses(old) else { return self }
        let rest = tokens.filter { !old.tokens.contains($0) }
        // a modifier that's now part of Super would be there twice
        let extras = rest.filter { token in !new.families.contains { $0 == ModifierFamily(token: token) } }
        return KeyCombo(tokens: new.tokens + extras, key: key)
    }

    func sameKeys(as other: KeyCombo) -> Bool { key == other.key && Set(tokens) == Set(other.tokens) }

    var families: [ModifierFamily] { Set(tokens.compactMap(ModifierFamily.init(token:))).sorted() }

    /// "⌃⌥H"; numbered actions show "1–9"
    func display(numbered: Bool = false) -> String {
        families.map(\.glyph).joined() + (numbered ? "1–9" : KeyNames.label(key))
    }

    /// From a key press in the recorder. Modifiers that make up Super count
    /// as Super, whichever side; the rest are written without a side.
    init?(event: NSEvent, superKey: SuperKey) {
        guard let key = KeyNames.name(keyCode: event.keyCode) else { return nil }
        let flags = event.modifierFlags
        var pressed = Set<ModifierFamily>()
        if flags.contains(.control) { pressed.insert(.control) }
        if flags.contains(.option) { pressed.insert(.option) }
        if flags.contains(.shift) { pressed.insert(.shift) }
        if flags.contains(.command) { pressed.insert(.command) }
        // .function comes with arrows and F keys on its own, so fn isn't offered
        var tokens: [String] = []
        if superKey.families.isSubset(of: pressed) {
            tokens = superKey.tokens
            pressed.subtract(superKey.families)
        }
        tokens += pressed.sorted().map(\.token)
        self.init(tokens: tokens, key: key)
    }
}

// MARK: key names

/// Paneru's key names. Letters and digits follow the keyboard layout (Paneru
/// reads them from it first); everything else is a named physical key.
enum KeyNames {
    /// keyCode -> Paneru's name, on a US layout
    static let byCode: [UInt16: String] = [
        0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x04: "h", 0x05: "g", 0x06: "z", 0x07: "x",
        0x08: "c", 0x09: "v", 0x0a: "section", 0x0b: "b", 0x0c: "q", 0x0d: "w", 0x0e: "e", 0x0f: "r",
        0x10: "y", 0x11: "t", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "equal", 0x19: "9", 0x1a: "7", 0x1b: "minus", 0x1c: "8", 0x1d: "0", 0x1e: "rightbracket",
        0x1f: "o", 0x20: "u", 0x21: "leftbracket", 0x22: "i", 0x23: "p", 0x25: "l", 0x26: "j",
        0x27: "quote", 0x28: "k", 0x29: "semicolon", 0x2a: "backslash", 0x2b: "comma", 0x2c: "slash",
        0x2d: "n", 0x2e: "m", 0x2f: "period", 0x32: "grave",
        0x41: "keypaddecimal", 0x43: "keypadmultiply", 0x45: "keypadplus", 0x47: "keypadclear",
        0x4b: "keypaddivide", 0x4c: "keypadenter", 0x4e: "keypadminus", 0x51: "keypadequals",
        0x52: "keypad0", 0x53: "keypad1", 0x54: "keypad2", 0x55: "keypad3", 0x56: "keypad4",
        0x57: "keypad5", 0x58: "keypad6", 0x59: "keypad7", 0x5b: "keypad8", 0x5c: "keypad9",
        0x24: "return", 0x30: "tab", 0x31: "space", 0x33: "delete", 0x35: "escape",
        0x40: "f17", 0x4f: "f18", 0x50: "f19", 0x5a: "f20", 0x60: "f5", 0x61: "f6", 0x62: "f7",
        0x63: "f3", 0x64: "f8", 0x65: "f9", 0x67: "f11", 0x69: "f13", 0x6a: "f16", 0x6b: "f14",
        0x6d: "f10", 0x6f: "f12", 0x71: "f15", 0x72: "help", 0x73: "home", 0x74: "pageup",
        0x75: "forwarddelete", 0x76: "f4", 0x77: "end", 0x78: "f2", 0x79: "pagedown", 0x7a: "f1",
        0x7b: "leftarrow", 0x7c: "rightarrow", 0x7d: "downarrow", 0x7e: "uparrow",
    ]

    static let labels: [String: String] = [
        "leftarrow": "←", "rightarrow": "→", "uparrow": "↑", "downarrow": "↓",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        "return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "forwarddelete": "⌦",
        "escape": "⎋", "help": "Help", "minus": "-", "equal": "=", "leftbracket": "[",
        "rightbracket": "]", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "grave": "`", "section": "§",
        "keypaddecimal": "Keypad .", "keypadmultiply": "Keypad *", "keypadplus": "Keypad +",
        "keypadclear": "Keypad Clear", "keypaddivide": "Keypad /", "keypadenter": "Keypad ↩",
        "keypadminus": "Keypad -", "keypadequals": "Keypad =",
    ]

    static func label(_ name: String) -> String {
        if let label = labels[name] { return label }
        if name.hasPrefix("keypad") { return "Keypad " + name.dropFirst(6) }
        return name.uppercased()
    }

    static func name(keyCode: UInt16) -> String? {
        if let typed = layoutCharacter(keyCode), typed.count == 1,
           typed.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) {
            return typed.lowercased()
        }
        return byCode[keyCode]
    }

    /// what the key types on the current layout, the way Paneru asks for it
    private static func layoutCharacter(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: what Paneru can do

struct ShortcutAction: Hashable, Identifiable {
    let title: String
    /// Paneru's command; more than one when Paneru has aliases. Numbered
    /// ones are a prefix ("window_virtualnum_") for 1 to 9.
    let commands: [String]
    var numbered = false
    /// one shortcut, no +
    var single: Bool { numbered || self == .overview }

    var id: String { commands[0] }

    func command(_ n: Int) -> String { commands[0] + String(n) }

    var allCommands: [String] { numbered ? (1...9).map(command) : commands }

    init(_ title: String, _ commands: String..., numbered: Bool = false) {
        self.title = title
        self.commands = commands
        self.numbered = numbered
    }

    static let groups: [(title: String, footer: String?, actions: [ShortcutAction])] = [
        ("Focus", nil, [
            ShortcutAction("Window on the left", "window_focus_west"),
            ShortcutAction("Window on the right", "window_focus_east"),
            ShortcutAction("Window above", "window_focus_north"),
            ShortcutAction("Window below", "window_focus_south"),
            ShortcutAction("First window", "window_focus_first"),
            ShortcutAction("Last window", "window_focus_last"),
            ShortcutAction("Previous tiled window", "window_focus_managed"),
            ShortcutAction("Previous floating window", "window_focus_unmanaged"),
        ]),
        ("Move window", nil, [
            ShortcutAction("Left", "window_swap_west"),
            ShortcutAction("Right", "window_swap_east"),
            ShortcutAction("Up", "window_swap_north"),
            ShortcutAction("Down", "window_swap_south"),
            ShortcutAction("To the start", "window_swap_first"),
            ShortcutAction("To the end", "window_swap_last"),
            ShortcutAction("Center on screen", "window_center"),
            ShortcutAction("Snap into view", "window_snap"),
        ]),
        ("Size", nil, [
            ShortcutAction("Wider", "window_resize", "window_grow"),
            ShortcutAction("Narrower", "window_shrink"),
            ShortcutAction("Taller", "window_vertical_resize", "window_vertical_grow"),
            ShortcutAction("Shorter", "window_vertical_shrink"),
            ShortcutAction("Full width", "window_fullwidth"),
            ShortcutAction("Same width for all columns", "window_balance"),
            ShortcutAction("Same height in a stack", "window_equalize"),
        ]),
        ("Stacks", nil, [
            ShortcutAction("Stack into the column on the left", "window_stack"),
            ShortcutAction("Take out of the stack", "window_unstack"),
            ShortcutAction("Show stack as tabs", "window_tabbeddisplay"),
        ]),
        ("Workspaces", nil, [
            ShortcutAction("Go to workspace above", "window_virtual_north"),
            ShortcutAction("Go to workspace below", "window_virtual_south"),
            ShortcutAction("Go to first workspace", "window_virtual_first"),
            ShortcutAction("Go to last workspace", "window_virtual_last"),
            ShortcutAction("Go to workspace", "window_virtualnum_", numbered: true),
            ShortcutAction("Move window up and follow", "window_virtualmove_north"),
            ShortcutAction("Move window down and follow", "window_virtualmove_south"),
            ShortcutAction("Move window to workspace and follow", "window_virtualmovenum_", numbered: true),
            ShortcutAction("Send window up", "window_virtualsend_north"),
            ShortcutAction("Send window down", "window_virtualsend_south"),
            ShortcutAction("Send window to workspace", "window_virtualsendnum_", numbered: true),
            ShortcutAction("Focus up, then go to workspace above", "window_virtualfocus_north"),
            ShortcutAction("Focus down, then go to workspace below", "window_virtualfocus_south"),
        ]),
        ("Floating windows", nil, [
            ShortcutAction("Float or tile window", "window_manage"),
            ShortcutAction("Bring floating windows forward", "window_raise_floating"),
            ShortcutAction("Floating windows in front or behind", "window_togglefloatlayer"),
        ]),
        ("Displays", nil, [
            ShortcutAction("Move window to next display", "window_nextdisplay"),
            ShortcutAction("Send window to next display", "window_nextdisplaysend"),
            ShortcutAction("Pointer to next display", "mouse_nextdisplay"),
        ]),
        ("Paneru", nil, [
            ShortcutAction("Copy window rule", "window_copyrule"),
            ShortcutAction("Show menu bar item", "showmenu"),
            ShortcutAction("Hide menu bar item", "hidemenu"),
            ShortcutAction("Restart Paneru", "restart"),
            ShortcutAction("Quit Paneru", "quit"),
        ]),
    ]

    /// Ledge's own, kept in Ledge's settings rather than Paneru's file
    static let overview = ShortcutAction("Open overview", "ledge_overview")

    static let all: [ShortcutAction] = [overview] + groups.flatMap(\.actions)
}
