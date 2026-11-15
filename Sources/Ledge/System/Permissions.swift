import AppKit
import EventKit

/// What Ledge is allowed to do, for Settings → Permissions.
/// Checks again whenever Ledge becomes active (e.g. coming back from
/// System Settings), so the rows are right without polling.
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false
    @Published private(set) var calendars = false

    private init() {
        check()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.check()
        }
    }

    func check() {
        let ax = WindowFocus.trusted
        let capture = WindowFocus.canCapture
        let status = EKEventStore.authorizationStatus(for: .event)
        let cal = status == .fullAccess || status == .authorized
        if accessibility != ax { accessibility = ax }
        if screenRecording != capture { screenRecording = capture }
        if calendars != cal { calendars = cal }
    }

    /// The first time, macOS's own alert asks (it has a button to System
    /// Settings, and adds Ledge to the list). After that the alert doesn't
    /// come back, so go straight to the list. Never both at once.
    func askAccessibility() {
        if Self.firstAsk("askedAccessibility") {
            WindowFocus.requestTrust()
        } else {
            Self.openPane("Privacy_Accessibility")
        }
    }

    /// Switching it on in System Settings makes macOS offer to quit and
    /// reopen Ledge, which it needs before it can use it.
    func askScreenRecording() {
        if Self.firstAsk("askedScreenRecording") {
            WindowFocus.requestCapture()
        } else {
            Self.openPane("Privacy_ScreenCapture")
        }
    }

    /// true once per permission, ever
    private static func firstAsk(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        return true
    }

    /// Opens a pane in System Settings → Privacy & Security
    /// (e.g. "Privacy_Accessibility").
    static func openPane(_ anchor: String) {
        let links = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ]
        for link in links {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
    }
}
