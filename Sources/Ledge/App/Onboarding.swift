import AppKit
import ServiceManagement
import SwiftUI

/// The welcome window on first launch: Paneru, room for the bar, macOS's own
/// trackpad gestures, permissions (each explained before macOS asks), track
/// info, open at login. Every step can be skipped.
///
/// To see it again: Settings → Permissions → Show Welcome Again, or
/// `defaults write io.github.knradf.ledge onboardingDone -bool false` and restart.
final class Onboarding: NSObject, NSWindowDelegate {
    static let shared = Onboarding()

    static let doneKey = "onboardingDone"
    /// the step it was on, so a relaunch (for Screen Recording or Paneru)
    /// comes back to the same place
    static let stepKey = "onboardingStep"

    private var window: NSWindow?
    private var model: OnboardingModel?
    private var paneru: PaneruStore?

    /// Shows the welcome if it hasn't been seen. Installs from before the
    /// welcome existed count as having seen it.
    func showIfNeeded(paneru: PaneruStore) {
        self.paneru = paneru
        let defaults = UserDefaults.standard
        // only what was saved: object(forKey:) also returns registered defaults
        let saved = Bundle.main.bundleIdentifier.flatMap(defaults.persistentDomain(forName:)) ?? [:]
        if saved[Self.doneKey] == nil, saved["statusLayout"] != nil {
            defaults.set(true, forKey: Self.doneKey)
            // they had it on before it became a choice here
            if saved["paneruTopFollowsBar"] == nil {
                LedgeSettings.shared.paneruTopFollowsBar = true
            }
        }
        guard !defaults.bool(forKey: Self.doneKey) else { return }
        show(resume: true)
    }

    func show(resume: Bool = false) {
        guard let paneru else { return }
        let model = self.model ?? OnboardingModel(store: paneru)
        self.model = model
        let saved = UserDefaults.standard.string(forKey: Self.stepKey).flatMap(OnboardingStep.init)
        model.step = resume ? (saved ?? .welcome) : .welcome
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView(model: model) { [weak self] in self?.finish() })
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.setContentSize(OnboardingView.size)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.close()
    }

    /// Closing it at any step counts as done: it never nags.
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
    }

    /// Quits and opens Ledge again, coming back to this step.
    static func relaunch(at step: OnboardingStep) {
        UserDefaults.standard.set(step.rawValue, forKey: stepKey)
        Relaunch.now()
    }
}

enum Relaunch {
    /// Started by install.sh's LaunchAgent: launchd restarts it (and keeps
    /// its log). Otherwise a tiny shell waits for Ledge to quit, then opens
    /// it again.
    static func now() {
        if LoginItem.shared.launchAgent, let label = Bundle.main.bundleIdentifier {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
            try? task.run()
            return
        }
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

enum OnboardingStep: String, CaseIterable {
    case welcome, paneru, barRoom, gestures, accessibility, screenRecording, calendars, trackInfo, login, done
}

final class OnboardingModel: ObservableObject {
    @Published var step = OnboardingStep.welcome
    /// Paneru is installed now but this Ledge started without it
    @Published private(set) var paneruAppeared = false
    @Published private(set) var startingPaneru = false
    @Published private(set) var gestureConflicts: [String] = []

    let store: PaneruStore

    init(store: PaneruStore) {
        self.store = store
        recheck()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.recheck()
        }
    }

    /// coming back from Terminal or System Settings
    func recheck() {
        let appeared = store.appsOnly && PaneruStore.findBinary() != nil
        if paneruAppeared != appeared { paneruAppeared = appeared }
        let conflicts = TrackpadGestures.conflicts()
        if gestureConflicts != conflicts { gestureConflicts = conflicts }
        PaneruSettings.shared.reload()
    }

    var hasPaneru: Bool { !store.appsOnly }

    /// the steps that apply right now, in order
    var steps: [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            switch step {
            case .barRoom: return hasPaneru && PaneruSettings.shared.editable
            case .gestures: return hasPaneru
            default: return true
            }
        }
    }

    func next() { move(by: 1) }
    func back() { move(by: -1) }

    private func move(by offset: Int) {
        // the current step may have dropped out of the list (Paneru went
        // away): go by the full order then
        let all = OnboardingStep.allCases
        guard let position = all.firstIndex(of: step) else { return }
        let candidates = offset > 0 ? Array(all[(position + 1)...]) : all[..<position].reversed()
        guard let target = candidates.first(where: steps.contains) else { return }
        step = target
        UserDefaults.standard.set(step.rawValue, forKey: Onboarding.stepKey)
    }

    /// Paneru's own service commands: install the LaunchAgent, then start it.
    /// Paneru asks for Accessibility itself the first time.
    func startPaneru() {
        guard let binary = PaneruStore.findBinary(), !startingPaneru else { return }
        startingPaneru = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for command in ["install", "start"] {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: binary)
                task.arguments = [command]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try? task.run()
                task.waitUntilExit()
            }
            DispatchQueue.main.async {
                self?.startingPaneru = false
                self?.store.reconnectNow()
            }
        }
    }
}

/// macOS's own three- and four-finger swipes take the gesture before Paneru
/// and Ledge see it.
enum TrackpadGestures {
    private static let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]

    private static func value(_ key: String) -> Int {
        for domain in domains {
            if let number = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int, number != 0 {
                return number
            }
        }
        return 0
    }

    /// What's switched on in Trackpad settings that clashes with the swipe
    /// Paneru is set up for.
    static func conflicts() -> [String] {
        let fingers = PaneruConfig.value("fingers_count", in: "swipe.gesture").flatMap { Int($0) } ?? 3
        let word = fingers == 4 ? "Four" : "Three"
        var found: [String] = []
        // 2 means that gesture uses this many fingers
        if value("Trackpad\(word)FingerHorizSwipeGesture") == 2 {
            found.append("Swipe between full-screen apps (\(word.lowercased()) fingers)")
        }
        if value("Trackpad\(word)FingerVertSwipeGesture") == 2 {
            found.append("Mission Control and App Exposé (\(word.lowercased()) fingers)")
        }
        if fingers == 3, value("TrackpadThreeFingerDrag") == 1 {
            found.append("Three-finger drag (Accessibility → Pointer Control)")
        }
        return found
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Open at login, through macOS's Login Items. A Ledge installed with
/// install.sh starts from its own LaunchAgent instead.
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false

    /// started by install.sh's LaunchAgent (launchd names the job)
    let launchAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "io.github.knradf.ledge"

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        let on = status == .enabled
        let approval = status == .requiresApproval
        if enabled != on { enabled = on }
        if needsApproval != approval { needsApproval = approval }
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Ledge: login item: \(error.localizedDescription)")
        }
        refresh()
    }
}

// MARK: the window

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let finish: () -> Void

    static let size = CGSize(width: 560, height: 520)

    var body: some View {
        VStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            HStack {
                if model.step != .welcome && model.step != .done {
                    Button("Back") { model.back() }
                }
                Spacer()
                pageDots
                Spacer()
                if model.step == .done {
                    Button("Done") { finish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.step == .welcome ? "Get Started" : "Continue") { model.next() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var pageDots: some View {
        let steps = model.steps
        return HStack(spacing: 6) {
            ForEach(steps, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome: WelcomePage()
        case .paneru: PaneruPage(model: model)
        case .barRoom: BarRoomPage(settings: LedgeSettings.shared, config: PaneruSettings.shared)
        case .gestures: GesturesPage(model: model)
        case .accessibility: AccessibilityPage(permissions: Permissions.shared)
        case .screenRecording: ScreenRecordingPage(permissions: Permissions.shared)
        case .calendars: CalendarsPage(permissions: Permissions.shared)
        case .trackInfo: TrackInfoPage()
        case .login: LoginPage(login: LoginItem.shared)
        case .done: DonePage()
        }
    }
}

/// Big symbol, title and a few lines, then whatever the step needs.
struct OnboardingPage<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    let content: Content

    init(symbol: String, tint: Color, title: String, text: String, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.text = text
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.gradient)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 64, height: 64)
            .padding(.top, 44)
            Text(title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 8)
            content
                .padding(.top, 8)
        }
        .padding(.horizontal, 24)
    }
}

/// Native grouped rows under a page's text.
struct OnboardingForm<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 480)
    }
}

/// "Allowed" with a check, for a step that's already taken care of.
struct OnboardingDone: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }
}

struct WelcomePage: View {
    var body: some View {
        OnboardingPage(
            symbol: "menubar.rectangle", tint: .blue,
            title: "Welcome to Ledge",
            text: "A status bar, workspace overview and clock island for macOS, made to sit on top of the Paneru window manager. A few steps to set it up; you can skip any of them."
        ) {
            EmptyView()
        }
    }
}

struct PaneruPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var store: PaneruStore

    init(model: OnboardingModel) {
        self.model = model
        self.store = model.store
    }

    var body: some View {
        OnboardingPage(
            symbol: "rectangle.split.3x1", tint: .indigo,
            title: "Paneru",
            text: "Paneru arranges your windows in scrolling strips across workspaces. With it, Ledge shows your workspaces, an overview of all of them and switches with swipes. Ledge works without it too: the bar then shows your open apps."
        ) {
            OnboardingForm {
                Section {
                    if model.hasPaneru {
                        if store.connected {
                            OnboardingDone(text: "Paneru is running")
                        } else {
                            LabeledContent {
                                if model.startingPaneru {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Start Paneru") { model.startPaneru() }
                                }
                            } label: {
                                Text("Paneru is installed but not running")
                                Text("It asks for Accessibility the first time, so it can move windows.")
                            }
                        }
                    } else if model.paneruAppeared {
                        LabeledContent {
                            Button("Restart Ledge") { Onboarding.relaunch(at: .paneru) }
                        } label: {
                            Text("Paneru is installed")
                            Text("Ledge needs a restart to start using it. This window comes back after.")
                        }
                    } else {
                        CommandRow(
                            intro: MediaControlInstaller.brew == nil
                                ? "Paneru installs with Homebrew (brew.sh). With Homebrew installed, paste this into Terminal:"
                                : "To install it, paste this into Terminal:",
                            command: "brew install paneru && paneru install && paneru start"
                        )
                        if MediaControlInstaller.brew == nil {
                            Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                        }
                    }
                } footer: {
                    if !model.hasPaneru && !model.paneruAppeared {
                        Footnote("Ledge notices when you come back here. Or continue without it; you can install it any time.")
                    }
                }
            }
        }
    }
}

/// A Terminal command with Copy and Open Terminal.
struct CommandRow: View {
    let intro: String
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(intro)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Button("Open Terminal") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
            }
        }
    }
}

struct BarRoomPage: View {
    @ObservedObject var settings: LedgeSettings
    @ObservedObject var config: PaneruSettings

    var body: some View {
        OnboardingPage(
            symbol: "rectangle.topthird.inset.filled", tint: .teal,
            title: "Room for the Bar",
            text: "Paneru can keep windows below Ledge's bar, so the bar never covers them. Ledge then sets Paneru's top padding and keeps it matched when you move the bar."
        ) {
            OnboardingForm {
                Section {
                    Toggle(isOn: $settings.paneruTopFollowsBar) {
                        Text("Leave room for Ledge's bar")
                        Text(settings.paneruTopFollowsBar
                             ? "Windows start \(config.topForBar()) pt from the top."
                             : "Paneru keeps its own top padding (\(config.padding.top) pt).")
                    }
                } footer: {
                    Footnote("Changes one line in paneru.toml and keeps your comments; the first change saves a backup next to it. Settings → Paneru has the rest.")
                }
            }
        }
    }
}

struct GesturesPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingPage(
            symbol: "hand.draw", tint: .orange,
            title: "Trackpad Gestures",
            text: "Paneru moves between windows with a sideways swipe, and Ledge or Paneru switch workspaces with an up or down swipe. macOS takes a gesture first when one of its own uses the same number of fingers."
        ) {
            OnboardingForm {
                Section {
                    if model.gestureConflicts.isEmpty {
                        OnboardingDone(text: "Nothing in macOS gets in the way")
                    } else {
                        ForEach(model.gestureConflicts, id: \.self) { conflict in
                            Label(conflict, systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        }
                        LabeledContent {
                            Button("Open Trackpad Settings") { TrackpadGestures.openSettings() }
                        } label: {
                            Text("Switch these off or to a different number of fingers")
                            Text("Under More Gestures. Ledge checks again when you come back.")
                        }
                    }
                }
            }
        }
    }
}

struct AccessibilityPage: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        OnboardingPage(
            symbol: "accessibility", tint: .blue,
            title: "Accessibility",
            text: "Lets Ledge bring a window forward when you click it in the bar or the overview, and listen for Left Option + O and three-finger swipes. Ledge never reads what you type."
        ) {
            OnboardingForm {
                Section {
                    if permissions.accessibility {
                        OnboardingDone(text: "Allowed")
                    } else {
                        LabeledContent {
                            Button("Allow…") { permissions.askAccessibility() }
                        } label: {
                            Text("Switch Ledge on in Privacy & Security")
                            Text("macOS asks first. Come back here when it's on.")
                        }
                    }
                }
            }
        }
    }
}

struct ScreenRecordingPage: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        OnboardingPage(
            symbol: "rectangle.dashed.badge.record", tint: .red,
            title: "Screen Recording",
            text: "For pictures of your windows in the overview and the workspace slide, and to see if the wallpaper behind the bar is light or dark. Nothing is saved or leaves your Mac."
        ) {
            OnboardingForm {
                Section {
                    if permissions.screenRecording {
                        OnboardingDone(text: "Allowed")
                    } else {
                        LabeledContent {
                            Button("Allow…") { permissions.askScreenRecording() }
                        } label: {
                            Text("Switch Ledge on in Privacy & Security")
                            Text("macOS asks first. When it offers to quit and reopen Ledge, say yes: this window comes back.")
                        }

                    }
                }
            }
        }
    }
}

struct CalendarsPage: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        OnboardingPage(
            symbol: "calendar", tint: .red,
            title: "Calendars",
            text: "Your upcoming events in the clock island. Ledge only reads them."
        ) {
            OnboardingForm {
                Section {
                    if permissions.calendars {
                        OnboardingDone(text: "Allowed")
                    } else {
                        LabeledContent {
                            Button("Allow…") { CalendarStore.shared.prepare() }
                        } label: {
                            Text("macOS asks right here")
                            Text("If you said no before, Privacy & Security → Calendars.")
                        }
                    }
                }
            }
        }
    }
}

struct TrackInfoPage: View {
    var body: some View {
        OnboardingPage(
            symbol: "music.note", tint: .pink,
            title: "Track Info",
            text: "The island can show what's playing, with artwork and controls. macOS no longer lets apps read that, so it takes media-control, a small free tool. Optional: without it the island still says which app is playing."
        ) {
            OnboardingForm {
                TrackInfoSection()
            }
        }
    }
}

struct LoginPage: View {
    @ObservedObject var login: LoginItem

    var body: some View {
        OnboardingPage(
            symbol: "power", tint: .green,
            title: "Open at Login",
            text: "Have Ledge ready every time you log in."
        ) {
            OnboardingForm {
                Section {
                    if login.launchAgent {
                        OnboardingDone(text: "Already on: install.sh set Ledge up to start at login")
                    } else {
                        Toggle("Open Ledge at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
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
    }
}

struct DonePage: View {
    var body: some View {
        OnboardingPage(
            symbol: "checkmark", tint: .green,
            title: "You're Set",
            text: "Click the clock for the island; Ledge Settings is at the bottom of it. Everything here is in Settings too, and Settings → Permissions can show this welcome again."
        ) {
            EmptyView()
        }
    }
}
