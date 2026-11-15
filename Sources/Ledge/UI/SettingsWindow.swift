import AppKit
import EventKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings window with toolbar tabs, like the system's own settings.
/// Opened from the clock.
///
/// General: how the bar looks. Behavior: the overview, swipes, slide (Paneru
/// only). Rules: where apps open, which apps count as playing. Paneru: the
/// window manager's own settings, written to its config. Permissions: what
/// Ledge may do, media-control, reset.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let settings = LedgeSettings.shared
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            // keep the window called "Ledge" instead of renaming it per tab
            tabs.canPropagateSelectedChildViewControllerTitle = false
            tabs.preferredContentSize = Self.size
            let paneru = PaneruStore.findBinary() != nil
            add(to: tabs, title: "General", symbol: "gearshape", view: GeneralTab(settings: settings))
            // the overview and workspace switching need Paneru's workspaces
            if paneru {
                add(to: tabs, title: "Behavior", symbol: "hand.tap", view: BehaviorTab(settings: settings))
            }
            add(to: tabs, title: "Rules", symbol: "list.bullet.rectangle", view: RulesTab(settings: settings, paneru: paneru))
            add(to: tabs, title: "Paneru", symbol: "rectangle.split.3x1", view: PaneruTab(settings: settings))
            add(to: tabs, title: "Permissions", symbol: "hand.raised", view: PermissionsTab(settings: settings))

            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.title = "Ledge"
            // the window must be exactly as big as the content, or SwiftUI
            // centers the oversized form and every edge gets clipped
            window.setContentSize(Self.size)
            window.contentMinSize = Self.size
            window.contentMaxSize = Self.size
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func add<V: View>(to tabs: NSTabViewController, title: String, symbol: String, view: V) {
        let host = NSHostingController(rootView: AnyView(view.frame(width: Self.size.width, height: Self.size.height)))
        host.sizingOptions = [.preferredContentSize]
        host.preferredContentSize = Self.size
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    static let size = CGSize(width: 560, height: 640)
}

// MARK: Permissions

struct PermissionsTab: View {
    @ObservedObject var settings: LedgeSettings
    @ObservedObject var permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Focusing a window from the bar or overview, the ⌥O shortcut, three-finger swipes",
                    granted: permissions.accessibility,
                    pane: "Privacy_Accessibility"
                ) {
                    permissions.askAccessibility()
                }
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Window previews, the workspace slide, matching the wallpaper",
                    granted: permissions.screenRecording,
                    pane: "Privacy_ScreenCapture"
                ) {
                    permissions.askScreenRecording()
                }
                PermissionRow(
                    title: "Calendars",
                    detail: "Your events in the island",
                    granted: permissions.calendars,
                    pane: "Privacy_Calendars"
                ) {
                    // macOS asks right here the first time; after a no, only
                    // System Settings can change it
                    if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                        CalendarStore.shared.prepare()
                    } else {
                        Permissions.openPane("Privacy_Calendars")
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Footnote("Shows as not allowed although it's on? If you chose Later when macOS offered to reopen Ledge, quit and open it again. If that doesn't do it, remove Ledge from the list in System Settings with − and add it back with +.")
            }

            TrackInfoSection()

            LoginSection(login: LoginItem.shared)

            Section {
                HStack {
                    Button("Show Welcome Again") { Onboarding.shared.show() }
                    Spacer()
                    Button("Reset Everything…") { confirmReset() }
                    Button("Quit Ledge") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// asks first, like the system does before throwing settings away
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all of Ledge's settings?"
        alert.informativeText = "Your status items, rules and everything else go back to how they were at first. Paneru's own settings stay as they are."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { settings.reset() }
    }
}

/// Open at login, or a note when install.sh's LaunchAgent starts Ledge.
struct LoginSection: View {
    @ObservedObject var login: LoginItem

    var body: some View {
        Section {
            if login.launchAgent {
                LabeledContent {
                    Text("On").foregroundStyle(.secondary)
                } label: {
                    Text("Open at login")
                    Text("Set up by install.sh, which starts Ledge at every login.")
                }
            } else {
                Toggle("Open at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if login.needsApproval {
                    LabeledContent {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("macOS wants you to confirm it")
                        Text("Switch Ledge on under Allow in the Background.")
                    }
                }
            }
        }
    }
}

// MARK: General

struct GeneralTab: View {
    @ObservedObject var settings: LedgeSettings
    @ObservedObject var permissions = Permissions.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker(selection: $settings.barStyle) {
                    ForEach(BarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                } label: {
                    Text("Style")
                    Text(styleNote)
                }
                .pickerStyle(.segmented)
                Picker(selection: $settings.barAppearance) {
                    Text(BarAppearance.wallpaper.label).tag(BarAppearance.wallpaper)
                    Text(BarAppearance.system.label).tag(BarAppearance.system)
                    Divider()
                    Text(BarAppearance.light.label).tag(BarAppearance.light)
                    Text(BarAppearance.dark.label).tag(BarAppearance.dark)
                } label: {
                    Text("Light or dark")
                    if let note = appearanceNote { Text(note) }
                }
                .pickerStyle(.menu)
            }

            Section("Bar") {
                SliderRow(title: "Distance from screen edge", value: $settings.edgeMargin, range: 0...48)
                SliderRow(title: "Distance from top", value: $settings.topOffset, range: 0...10)
                SliderRow(title: "Space between pills", value: $settings.pillGap, range: 2...20)
            }

            Section("Clock") {
                Picker("Position", selection: $settings.clockPosition) {
                    ForEach(ClockPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("24-hour time", isOn: $settings.clock24h)
                Toggle("Show date", isOn: $settings.clockShowDate)
                Toggle("Show seconds", isOn: $settings.clockShowSeconds)
            }

            if PaneruStore.findBinary() == nil {
                Section {
                    appStylePicker
                } header: {
                    Text("Open Apps")
                } footer: {
                    Footnote("Without a window manager the bar shows your open apps. Click one to bring it forward.")
                }
            } else {
                Section("Workspaces") {
                    Toggle(isOn: $settings.showEmptyWorkspaces) {
                        Text("Show empty workspaces")
                        Text("Every workspace up to the last one you use, plus one empty one after it.")
                    }
                    Toggle("Workspace number", isOn: $settings.showNumbers)
                    Toggle("Apps", isOn: $settings.showApps)
                    appStylePicker
                        .disabled(!settings.showApps)
                    Toggle("Window count", isOn: $settings.showWindowCount)
                        .disabled(!settings.showApps)
                }
            }

            StatusSections(settings: settings)
        }
        .formStyle(.grouped)
    }

    private var appStylePicker: some View {
        Picker(selection: $settings.appStyle) {
            ForEach(AppStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        } label: {
            Text("App style")
            if settings.showApps && settings.appStyle == .glyphs {
                Text(GlyphMap.shared.available
                     ? "Glyphs from sketchybar-app-font \(GlyphMap.shared.version ?? ""), built in. Apps without one get a generic glyph."
                     : GlyphMap.shared.missingReason)
            }
        }
        .pickerStyle(.segmented)
    }

    private var appearanceNote: String? {
        switch settings.barAppearance {
        case .wallpaper:
            return permissions.screenRecording
                ? "White text over a dark wallpaper, dark text over a light one, like the menu bar."
                : "Needs Screen Recording (Permissions tab) to see what's behind the bar. Until then it follows the system."
        case .system: return "Light or dark with the rest of macOS."
        case .light, .dark: return nil
        }
    }

    private var styleNote: String {
        switch settings.barStyle {
        case .glass:
            return "Liquid Glass, like the rest of the system."
        case .frosted:
            return "The blur macOS uses for menus."
        case .none:
            return "No backgrounds, just text and icons over your wallpaper. The workspace highlight slides between workspaces."
        }
    }
}

// MARK: Behavior

struct BehaviorTab: View {
    @ObservedObject var settings: LedgeSettings

    /// snaps any stored value to the nearest choice
    private var zoomBinding: Binding<Double> {
        Binding(
            get: {
                let current = settings.overviewZoom
                return Theme.overviewZoomChoices.map { $0.value }
                    .min(by: { abs($0 - current) < abs($1 - current) }) ?? 0.42
            },
            set: { settings.overviewZoom = $0 }
        )
    }

    var body: some View {
        Form {
            if PaneruStore.findBinary() != nil {
                Section("Overview") {
                    Toggle("Open with Left Option + O", isOn: $settings.overviewShortcut)
                    Picker("Hot corner", selection: $settings.hotCorner) {
                        ForEach(HotCornerPosition.allCases) { corner in
                            Text(corner.label).tag(corner)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Zoom", selection: zoomBinding) {
                        ForEach(Theme.overviewZoomChoices) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Two-finger scroll", selection: $settings.overviewReverseScroll) {
                        Text("Like a Page").tag(false)
                        Text("Reversed").tag(true)
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Picker("Three-finger swipe up/down", selection: $settings.desktopSwipe) {
                        Text("Handled by Paneru").tag(SwipeDirection.off)
                        Text("Up Goes to the Workspace Above").tag(SwipeDirection.upGoesAbove)
                        Text("Up Goes to the Workspace Below").tag(SwipeDirection.upGoesBelow)
                    }
                    .pickerStyle(.menu)
                    PaneruSwipeHint(settings: settings)
                    Toggle(isOn: $settings.workspaceSlide) {
                        Text("Slide between workspaces (experimental)")
                        Text("Ledge slides pictures of your workspaces, then shows the real one; windows are still for a moment. Best with Paneru's window movement set to Instant. Works when you switch from the bar or with Ledge's swipes; Paneru's own shortcuts still switch at once.")
                    }
                } header: {
                    Text("Switching Workspaces")
                } footer: {
                    Footnote("Sideways swipes stay with Paneru (Paneru tab). Paneru's own direction setting flips sideways swipes too, which is why Ledge can do up/down on its own.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Ledge and Paneru shouldn't both act on the same swipe: points out a
/// mismatch and fixes it in Paneru's config on request.
struct PaneruSwipeHint: View {
    @ObservedObject var settings: LedgeSettings
    @ObservedObject var config = PaneruSettings.shared

    var body: some View {
        let ledgeHandles = settings.desktopSwipe != .off
        let paneruHandles = config.verticalSwipes
        if ledgeHandles && paneruHandles != false {
            hint("Paneru switches workspaces on up/down swipes too, so you'd move twice.",
                 button: "Turn Off in Paneru", on: false)
        } else if !ledgeHandles && paneruHandles == false {
            hint("Paneru's up/down swipes are turned off, so nothing will switch.",
                 button: "Turn On in Paneru", on: true)
        }
    }

    private func hint(_ text: String, button: String, on: Bool) -> some View {
        LabeledContent {
            Button(button) { config.setVerticalSwipes(on) }
                .disabled(!config.editable)
        } label: {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Paneru

/// Paneru's own settings, written to its config (it reloads on save).
struct PaneruTab: View {
    @ObservedObject var settings: LedgeSettings
    @ObservedObject var config = PaneruSettings.shared

    var body: some View {
        Form {
            if PaneruStore.findBinary() == nil {
                Section {
                    LabeledContent {
                        Link("Paneru on GitHub", destination: URL(string: "https://github.com/karinushka/paneru")!)
                    } label: {
                        Text("Paneru isn't installed")
                        Text("A scrolling tiling window manager. With it the bar shows workspaces, and you get the overview (⌥O), workspace swipes and rules for where apps open.")
                    }
                }
            } else if !config.configFound {
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
                    edgesSection
                    windowsSection
                    focusSection
                    swipeSection
                    movementSection
                }
                .disabled(!config.editable)
            }
        }
        .formStyle(.grouped)
    }

    private func padding(_ side: WritableKeyPath<PaneruSettings.EdgePadding, Int>) -> Binding<Double> {
        Binding(get: { Double(config.padding[keyPath: side]) },
                set: { config.setPadding(side, Int($0.rounded())) })
    }

    private var edgesSection: some View {
        Section {
            Toggle(isOn: $settings.paneruTopFollowsBar) {
                Text("Leave room for Ledge's bar")
                Text("Windows start \(config.topForBar()) pt from the top: below the bar, with the same space as at the sides. It follows the bar when you change it.")
            }
            if !settings.paneruTopFollowsBar {
                SliderRow(title: "Top", value: padding(\.top), range: 0...80)
            }
            SliderRow(title: "Left", value: padding(\.left), range: 0...48)
            SliderRow(title: "Right", value: padding(\.right), range: 0...48)
            SliderRow(title: "Bottom", value: padding(\.bottom), range: 0...48)
        } header: {
            Text("Screen Edges")
        } footer: {
            Footnote("Space Paneru keeps free at each edge of the screen, on top of the space between windows.")
        }
    }

    private var widthChoices: [Double] {
        let extra = config.columnWidths.filter { width in
            !PaneruSettings.widthChoices.contains { abs($0 - width) < 0.005 }
        }
        return (PaneruSettings.widthChoices + extra).sorted()
    }

    private var windowsSection: some View {
        Section {
            SliderRow(title: "Space between windows",
                      value: Binding(get: { Double(config.gap) }, set: { config.setGap(Int($0.rounded())) }),
                      range: 0...32, step: 2)
            VStack(alignment: .leading, spacing: 8) {
                Text("Column widths")
                Text("The widths resizing steps through, as a share of the screen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(widthChoices, id: \.self) { width in
                        Toggle(isOn: Binding(get: { config.hasWidth(width) }, set: { _ in config.toggleWidth(width) })) {
                            Text("\(Int((width * 100).rounded()))%")
                                .monospacedDigit()
                        }
                        .toggleStyle(.button)
                    }
                }
            }
            Toggle(isOn: Binding(get: { config.resizeCycle }, set: { config.setResizeCycle($0) })) {
                Text("Start over after the widest")
                Text("Off: resizing stops at the narrowest and widest instead of wrapping around.")
            }
        } header: {
            Text("Windows")
        }
    }

    private var focusSection: some View {
        Section {
            Toggle(isOn: Binding(get: { config.focusFollowsMouse }, set: { config.setFocusFollowsMouse($0) })) {
                Text("Focus follows mouse")
                Text("Moving the pointer over a window focuses it.")
            }
            Toggle(isOn: Binding(get: { config.mouseFollowsFocus }, set: { config.setMouseFollowsFocus($0) })) {
                Text("Mouse follows focus")
                Text("The pointer jumps to a window when you focus it with the keyboard.")
            }
            Picker(selection: Binding(get: { config.bringIntoView }, set: { config.setBringIntoView($0) })) {
                ForEach(BringIntoView.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            } label: {
                Text("Scroll a focused window into view")
                Text("How much of a window may be off screen before focusing it scrolls the strip.")
            }
            .pickerStyle(.menu)
        } header: {
            Text("Focus and Mouse")
        }
    }

    private var swipeSection: some View {
        Section {
            Picker(selection: Binding(get: { config.stripSwipe }, set: { config.setStripSwipe($0) })) {
                ForEach(StripSwipe.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                Text("Three-finger sideways swipe")
                Text(config.stripSwipe.explanation)
            }
            .pickerStyle(.menu)
            if config.stripSwipe == .page {
                SliderRow(title: "Finger travel per window",
                          value: Binding(get: { config.pageDistance }, set: { config.setPageDistance($0) }),
                          range: 1...4, unit: "cm", step: 0.5)
                Toggle("Tap for each window", isOn: Binding(get: { config.haptics }, set: { config.setHaptics($0) }))
            } else {
                EndsSlider(title: "Speed", low: "Slow", high: "Fast",
                           value: Binding(get: { config.swipeSpeed }, set: { config.setSwipeSpeed($0) }),
                           range: 0.15...1, step: 0.05)
                // shown as how far it glides: the reverse of Paneru's deceleration
                EndsSlider(title: "Glide after lifting", low: "Short", high: "Long",
                           value: Binding(get: { 11 - config.swipeDeceleration },
                                          set: { config.setSwipeDeceleration(11 - $0) }),
                           range: 1...10, step: 0.5)
            }
        } header: {
            Text("Moving Between Windows")
        } footer: {
            Footnote("Glide and Settle and One Window at a Time also center a window when you move focus with the keyboard. Glide and Settle can't quite reach the first and last window: it pulls them toward the middle of the screen, which they can't reach, so they bounce back. That's Paneru.")
        }
    }

    private var movementSection: some View {
        Section {
            Picker(selection: Binding(get: { config.movement }, set: { config.setMovement($0) })) {
                ForEach(WindowMovement.allCases) { movement in
                    Text(movement.label).tag(movement)
                }
            } label: {
                Text("Window movement")
                Text("How windows travel when they move, scroll or resize.")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Animation")
        } footer: {
            Footnote("Paneru moves real windows, and macOS makes every app redraw as it's moved or resized, so some apps stutter, most of all while resizing. That's macOS, nothing Paneru or Ledge can smooth out. Ledge edits paneru.toml one line at a time and keeps your comments; the first change saves a backup next to it.")
        }
    }
}

/// The three ways Paneru's strip can follow a sideways swipe.
enum StripSwipe: String, CaseIterable, Identifiable {
    case free, settle, page

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Free Scroll"
        case .settle: return "Glide and Settle"
        case .page: return "One Window at a Time"
        }
    }

    var explanation: String {
        switch self {
        case .free: return "The strip slides with your fingers and stops wherever it stops."
        case .settle: return "The strip glides, then settles with the nearest window centered."
        case .page: return "Each stretch of the swipe moves to the next window and centers it."
        }
    }

    /// Paneru's two settings behind it: paging, auto_center
    var paging: Bool { self == .page }
    var autoCenter: Bool { self != .free }

    init(paging: Bool, autoCenter: Bool) {
        self = paging ? .page : (autoCenter ? .settle : .free)
    }
}

enum WindowMovement: String, CaseIterable, Identifiable {
    case instant, smooth, relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instant: return "Instant"
        case .smooth: return "Smooth"
        case .relaxed: return "Relaxed"
        }
    }

    /// Paneru's animation_speed: an ease-out rate, 8-20 feels fluid, very large snaps
    var speed: Double {
        switch self {
        case .instant: return 1000
        case .smooth: return 14
        case .relaxed: return 9
        }
    }

    init(speed: Double?) {
        guard let speed, speed < 100 else { self = .instant; return }
        self = speed >= 12 ? .smooth : .relaxed
    }
}

// MARK: Island sections

/// Which apps make the playing indicator appear (Behavior tab).
struct PlayingIndicatorSection: View {
    @ObservedObject var settings: LedgeSettings

    var body: some View {
        Section {
            Picker("Show it for", selection: $settings.soundFilterMode) {
                Text("All Apps Except These").tag(SoundFilterMode.allExcept)
                Text("Only These Apps").tag(SoundFilterMode.only)
            }
            .pickerStyle(.menu)
            if settings.soundFilterApps.isEmpty {
                Text(settings.soundFilterMode == .allExcept
                     ? "No exceptions: any app making sound counts."
                     : "Nothing will show until you add an app.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(settings.soundFilterApps) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: AppIcons.icon(for: app.bundleID))
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Button {
                            settings.soundFilterApps.removeAll { $0.bundleID == app.bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Spacer()
                AddAppMenu(taken: Set(settings.soundFilterApps.map { $0.bundleID })) { id, name in
                    settings.soundFilterApps.append(FilterApp(bundleID: id, name: name))
                }
            }
        } header: {
            Text("Playing Indicator")
        } footer: {
            Footnote("Which apps make the bars appear next to the clock and show up in the island.")
        }
    }
}

/// media-control, for the song, artwork and controls in the island (Permissions tab).
struct TrackInfoSection: View {
    @ObservedObject var nowPlaying = NowPlayingStore.shared
    @ObservedObject var installer = MediaControlInstaller.shared

    var body: some View {
        Section {
            LabeledContent {
                if nowPlaying.available {
                    Text("Installed").foregroundStyle(.secondary)
                } else if installer.state == .installing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Installing…").foregroundStyle(.secondary)
                    }
                } else if MediaControlInstaller.brew != nil {
                    Button("Install") { installer.install() }
                }
            } label: {
                Text("media-control")
                Text(nowPlaying.available
                     ? "The island shows the track, artwork and controls."
                     : "Not installed. The island only says which app is playing.")
            }
            if !nowPlaying.available && installer.state != .installing
                && (MediaControlInstaller.brew == nil || installer.state != .idle) {
                ManualInstallRow(problem: {
                    if case .failed(let output) = installer.state { return output }
                    return nil
                }())
            }
        } header: {
            Text("Track Info and Controls")
        } footer: {
            Footnote("macOS no longer lets apps read what's playing. media-control is a small free, open-source tool that can, installed with Homebrew.")
        }
    }
}

/// The command to paste into Terminal, for when Ledge can't install
/// media-control itself (no Homebrew, or brew failed).
struct ManualInstallRow: View {
    /// what brew said when it failed
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem {
                Text("Homebrew couldn't install it:\n\(problem)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(MediaControlInstaller.brew == nil
                 ? "Needs Homebrew (brew.sh). With it installed, paste this into Terminal:"
                 : "Paste this into Terminal instead:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(MediaControlInstaller.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { MediaControlInstaller.copyCommand() }
                Button("Open Terminal") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
            }
            if MediaControlInstaller.brew == nil {
                Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
            }
        }
    }
}

// MARK: Rules

/// Apps that always open on a given workspace.
struct RulesTab: View {
    @ObservedObject var settings: LedgeSettings
    /// rules that move windows need Paneru's workspaces
    let paneru: Bool

    var body: some View {
        Form {
            if paneru {
                OpenOnWorkspaceSection(settings: settings)
            }
            PlayingIndicatorSection(settings: settings)
        }
        .formStyle(.grouped)
    }
}

/// Apps that always open on a given workspace.
struct OpenOnWorkspaceSection: View {
    @ObservedObject var settings: LedgeSettings

    var body: some View {
        Group {
            Section {
                if settings.workspaceRules.isEmpty {
                    Text("No apps yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(settings.workspaceRules) { rule in
                        RuleRow(rule: rule, settings: settings)
                    }
                }
                HStack {
                    Spacer()
                    AddRuleMenu(settings: settings)
                }
            } header: {
                Text("Open on Workspace")
            } footer: {
                Footnote("When one of these apps opens, its window goes to that workspace and you stay where you are. Windows that are already open aren't moved.")
            }
        }
    }
}

struct RuleRow: View {
    let rule: WorkspaceRule
    @ObservedObject var settings: LedgeSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(for: rule.bundleID))
                .resizable()
                .frame(width: 24, height: 24)
            Text(rule.name)
                .lineLimit(1)
            Spacer()
            Picker("Workspace", selection: Binding(
                get: { rule.workspace },
                set: { value in settings.updateRule(rule.id) { $0.workspace = value } }
            )) {
                ForEach(1...9, id: \.self) { number in
                    Text("Workspace \(number)").tag(number)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Button {
                settings.removeRule(rule.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.vertical, 2)
    }
}

/// Running apps to pick from, or any app on disk.
struct AddRuleMenu: View {
    @ObservedObject var settings: LedgeSettings

    var body: some View {
        AddAppMenu(taken: Set(settings.workspaceRules.map { $0.bundleID })) { id, name in
            settings.addRule(bundleID: id, name: name)
        }
    }
}

/// "Add App" pop-up: open apps (with a Dock icon) not in the list yet, or any
/// app on disk.
struct AddAppMenu: View {
    let taken: Set<String>
    let add: (String, String) -> Void

    var body: some View {
        // built when clicked, not on every redraw of the tab
        Button("Add App…") { showMenu() }
    }

    private func showMenu() {
        let menu = NSMenu()
        for app in candidates {
            let item = NSMenuItem.action(app.name) { add(app.bundleID, app.name) }
            item.image = AppIcons.icon(for: app.bundleID, size: 16)
            menu.addItem(item)
        }
        if !candidates.isEmpty { menu.addItem(.separator()) }
        menu.addItem(.action("Choose App…") { chooseApp() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private var candidates: [AppChoice] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppChoice? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      !taken.contains(id), seen.insert(id).inserted
                else { return nil }
                return AppChoice(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            add(id, name)
        }
    }
}

struct AppChoice: Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// App icons by bundle id, cached.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String, size: CGFloat = 32) -> NSImage {
        let key = "\(bundleID)@\(size)"
        if let cached = cache[key] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: size, height: size)
        cache[key] = sized
        return sized
    }
}

// MARK: Status bar

/// Laid out like System Settings → Control Center: a checkbox, a colored
/// tile and the item's options per row; ordering in its own section.
struct StatusSections: View {
    @ObservedObject var settings: LedgeSettings
    @ObservedObject var drag = ArrangementDrag()

    var body: some View {
        Group {
            Section {
                ForEach(StatusEntry.allCases) { entry in
                    StatusItemRow(entry: entry, settings: settings)
                }
            } header: {
                Text("Status Items")
            }

            Section {
                // .onMove only works in a List, not in a grouped Form like
                // this one, so the rows do their own drag and drop
                ForEach(settings.statusLayout) { slot in
                    ArrangementRow(slot: slot, settings: settings, drag: drag)
                }
                HStack {
                    Spacer()
                    Button("Reset Order") { settings.resetStatusItems() }
                    Button("Add Divider") { settings.addDivider() }
                }
            } header: {
                Text("Arrangement")
            } footer: {
                Footnote("Drag to reorder, or right-click a row. A divider starts a new pill.")
            }
        }
    }
}

struct StatusItemRow: View {
    let entry: StatusEntry
    @ObservedObject var settings: LedgeSettings

    private var enabled: Binding<Bool> {
        Binding(get: { settings.isEnabled(entry) }, set: { settings.setEnabled(entry, $0) })
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(entry.label, isOn: enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
            IconTile(entry: entry)
            Text(entry.label)
            Spacer()
            options
                .disabled(!settings.isEnabled(entry))
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var options: some View {
        switch entry {
        case .sound:
            ShowPicker(selection: Binding(get: { settings.soundShowPercent }, set: { settings.soundShowPercent = $0 }))
        case .battery:
            ShowPicker(selection: Binding(get: { settings.batteryShowPercent }, set: { settings.batteryShowPercent = $0 }))
        case .network:
            Picker("Hide speeds", selection: thresholdBinding) {
                ForEach(Self.thresholds, id: \.self) { value in
                    Text(value == 0 ? "Always Show" : "Hide Below \(Int(value)) KB/s").tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        default:
            EmptyView()
        }
    }

    private static let thresholds: [Double] = [0, 5, 10, 25, 50]

    /// Snaps older free-slider values to the nearest menu choice.
    private var thresholdBinding: Binding<Double> {
        Binding(
            get: {
                let current = settings.networkThresholdKB
                return Self.thresholds.min(by: { abs($0 - current) < abs($1 - current) }) ?? 10
            },
            set: { settings.networkThresholdKB = $0 }
        )
    }
}

/// "Icon Only" / "Icon and Percentage" pop-up, like the system's.
struct ShowPicker: View {
    let selection: Binding<Bool>

    var body: some View {
        Picker("Show", selection: selection) {
            Text("Icon Only").tag(false)
            Text("Icon and Percentage").tag(true)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// Which Arrangement row is being dragged and which one it's over.
final class ArrangementDrag: ObservableObject {
    @Published var dragging: String?
    @Published var target: String?
}

struct ArrangementRow: View {
    let slot: LayoutSlot
    @ObservedObject var settings: LedgeSettings
    @ObservedObject var drag: ArrangementDrag

    /// a line below (dragging down) or above (dragging up) the row it'll
    /// land on; nil when nothing is being dropped here
    private var dropBelow: Bool? {
        guard drag.target == slot.id, let dragging = drag.dragging, dragging != slot.id,
              let from = settings.statusLayout.firstIndex(where: { $0.id == dragging }),
              let to = settings.statusLayout.firstIndex(of: slot)
        else { return nil }
        return from < to
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            if let item = slot.item {
                IconTile(entry: item)
                Text(item.label)
                Spacer()
            } else {
                VStack { Divider() }
                    .frame(width: 22)
                Text("Divider")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    settings.remove(slot)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove divider")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .overlay(alignment: dropBelow == true ? .bottom : .top) {
            if let below = dropBelow {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: below ? 5 : -5)
            }
        }
        .onDrag {
            drag.dragging = slot.id
            return NSItemProvider(object: slot.id as NSString)
        }
        .onDrop(of: [.plainText], isTargeted: Binding(
            get: { drag.target == slot.id },
            set: { inside in
                if inside {
                    drag.target = slot.id
                } else if drag.target == slot.id {
                    drag.target = nil
                }
            }
        )) { _ in
            if let dragging = drag.dragging {
                withAnimation(Theme.animation) { settings.move(id: dragging, to: slot) }
            }
            drag.dragging = nil
            drag.target = nil
            return true
        }
        .contextMenu {
            Button("Move Up") { settings.move(slot, by: -1) }
            Button("Move Down") { settings.move(slot, by: 1) }
            if slot.isDivider {
                Divider()
                Button("Remove Divider") { settings.remove(slot) }
            } else if let item = slot.item {
                Divider()
                Button("Hide \(item.label)") { settings.setEnabled(item, false) }
            }
        }
    }
}

/// A permission with its state, and a way to its pane in System Settings
/// either way (after a rebuild macOS can need it granted again).
struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    /// anchor of its Privacy & Security pane, e.g. "Privacy_Accessibility"
    let pane: String
    /// asks macOS, or opens the pane when macOS won't ask again
    let request: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                HStack(spacing: 8) {
                    Text("Allowed").foregroundStyle(.secondary)
                    Button("Open…") { Permissions.openPane(pane) }
                }
            } else {
                Button("Allow…") { request() }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// Explanation under a section, the size and color System Settings uses.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Colored rounded tile with a white symbol, like System Settings uses.
struct IconTile: View {
    let entry: StatusEntry

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.gradient)
            if entry == .bluetooth {
                BluetoothRune()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 7, height: 12)
            } else {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 24, height: 24)
    }

    private var tint: Color {
        switch entry {
        case .wifi, .bluetooth, .airdrop: return .blue
        case .network: return .teal
        case .sound: return .pink
        case .battery: return .green
        case .textInput: return .gray
        case .siri: return .purple
        }
    }
}

/// Slider with words at its ends instead of a number, for settings that are
/// a feel rather than a measurement.
struct EndsSlider: View {
    let title: String
    let low: String
    let high: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double = 0.1

    var body: some View {
        LabeledContent(title) {
            Slider(value: value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                Text(low).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .frame(width: 216)
        }
    }
}

/// Slider with its value shown. Takes a plain Binding (no @Binding wrapper,
/// which is a macro in the macOS 27 SDK).
struct SliderRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var unit: String = "pt"
    var step: Double = 1

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step)
                    .labelsHidden()
                    .frame(width: 160)
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private var valueText: String {
        let v = value.wrappedValue
        let number = step < 1 ? String(format: "%.1f", v) : "\(Int(v.rounded()))"
        return "\(number) \(unit)"
    }
}
