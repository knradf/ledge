import AppKit
import SwiftUI

/// Settings → Shortcuts: Paneru's keyboard shortcuts. One Super key on top,
/// then every command Paneru has, grouped.
struct ShortcutsTab: View {
    @ObservedObject var shortcuts = PaneruShortcuts.shared
    @ObservedObject var config = PaneruSettings.shared

    var body: some View {
        Form {
            superSection
                .disabled(!config.editable)
            Section("Ledge") {
                ShortcutRow(action: .overview, shortcuts: shortcuts)
            }
            if !config.configFound {
                Section {
                    Text("Paneru's config wasn't found at ~/.config/paneru/paneru.toml, so there's nothing to change here yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                if config.usesLua {
                    Section {
                        Label("Your Paneru config is in init.lua, which Paneru reads instead of paneru.toml. Ledge only edits paneru.toml, so these are shown but can't be changed here.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Group {
                    ForEach(ShortcutAction.groups, id: \.title) { group in
                        Section {
                            ForEach(group.actions) { action in
                                ShortcutRow(action: action, shortcuts: shortcuts)
                            }
                        } header: {
                            Text(group.title)
                        } footer: {
                            if let footer = group.footer { Footnote(footer) }
                        }
                    }
                    Section {
                        LabeledContent("Start over") {
                            Button("Use Ledge's Shortcuts…") { confirmRestore() }
                        }
                    }
                }
                .disabled(!config.editable)
            }
        }
        .formStyle(.grouped)
        .onDisappear { ShortcutRecorder.shared.stop() }
    }

    private var superSection: some View {
        Section {
            Picker("Super key", selection: Binding(get: { shortcuts.superKey }, set: { shortcuts.setSuper($0) })) {
                ForEach(SuperKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
        } footer: {
            Footnote("Most shortcuts start with the Super key. Change it and they all follow, along with Super + scroll wheel. Click a shortcut to type a new one; Delete removes it, Esc cancels.")
        }
    }

    private func confirmRestore() {
        let alert = NSAlert()
        alert.messageText = "Use Ledge's shortcuts?"
        alert.informativeText = "Every shortcut in this list goes back to Ledge's, with \(shortcuts.superKey.label) as the Super key."
        alert.addButton(withTitle: "Use Ledge's Shortcuts")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            shortcuts.restoreDefaults()
        }
    }
}

/// One command: its shortcuts, a + for another one, a warning on a clash.
struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var shortcuts: PaneruShortcuts
    @ObservedObject var recorder = ShortcutRecorder.shared
    /// the overview's shortcut lives here
    @ObservedObject var settings = LedgeSettings.shared

    private var combos: [KeyCombo] { shortcuts.combos(for: action) }
    private var newID: String { action.id + "#new" }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if !clashes.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .help("Also used for " + clashes.map(\.title).joined(separator: ", "))
                }
                ForEach(Array(combos.enumerated()), id: \.offset) { index, combo in
                    ShortcutField(id: action.id + "#\(index)", combo: combo, numbered: action.numbered) { new in
                        var list = combos
                        if let new { list[index] = new } else { list.remove(at: index) }
                        shortcuts.set(action, list)
                    }
                }
                if combos.isEmpty || recorder.recording == newID {
                    ShortcutField(id: newID, combo: nil, numbered: action.numbered) { new in
                        guard let new else { return }
                        shortcuts.set(action, combos + [new])
                    }
                } else if !action.single, combos.count < 3 {
                    Button {
                        recorder.start(newID)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add another shortcut")
                }
            }
        } label: {
            Text(action.title)
        }
    }

    private var clashes: [ShortcutAction] {
        var found: [ShortcutAction] = []
        for combo in combos {
            for other in shortcuts.conflicts(combo, besides: action) where !found.contains(other) {
                found.append(other)
            }
        }
        return found
    }
}

/// A shortcut you click and then type, like the fields in System Settings.
struct ShortcutField: View {
    let id: String
    let combo: KeyCombo?
    let numbered: Bool
    let onChange: (KeyCombo?) -> Void
    @ObservedObject var recorder = ShortcutRecorder.shared

    private var recording: Bool { recorder.recording == id }

    var body: some View {
        Button {
            if recording { recorder.stop() } else { recorder.start(id) }
        } label: {
            Text(text)
                .foregroundStyle(combo == nil || recording ? .secondary : .primary)
                .monospacedDigit()
                .frame(minWidth: 64)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.1),
                                      lineWidth: recording ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: recorder.recording) { _, now in
            guard now == id else { return }
            recorder.onKey = { event in handle(event) }
        }
        .onAppear {
            if recording { recorder.onKey = { event in handle(event) } }
        }
    }

    private var text: String {
        if recording {
            return recorder.held.isEmpty ? "Type Shortcut" : recorder.held
        }
        return combo?.display(numbered: numbered) ?? "None"
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty, event.keyCode == 0x35 {  // Esc
            recorder.stop()
            return
        }
        if mods.isEmpty, event.keyCode == 0x33 || event.keyCode == 0x75 {  // Delete
            recorder.stop()
            if combo != nil { onChange(nil) }
            return
        }
        guard var new = KeyCombo(event: event, superKey: PaneruShortcuts.shared.superKey),
              !new.tokens.isEmpty || new.key.range(of: "^f[0-9]+$", options: .regularExpression) != nil
        else {
            NSSound.beep()
            return
        }
        if numbered {
            // the modifiers count; the number key is 1 to 9
            new.key = "1"
        }
        recorder.stop()
        onChange(new)
    }
}

/// The one field taking keys right now. A local monitor sees key presses
/// in Ledge's own windows only, and only while a field is recording.
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    @Published private(set) var recording: String?
    /// the modifiers held so far, as glyphs
    @Published private(set) var held = ""
    var onKey: ((NSEvent) -> Void)?

    private var monitor: Any?
    private var resignObserver: Any?

    func start(_ id: String) {
        onKey = nil
        held = ""
        recording = id
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, self.recording != nil else { return event }
                if event.type == .flagsChanged {
                    self.held = Self.glyphs(event.modifierFlags)
                } else {
                    self.onKey?(event)
                }
                return nil
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        guard recording != nil || monitor != nil else { return }
        recording = nil
        held = ""
        onKey = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private static func glyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }
}
