import AppKit
import ApplicationServices

/// Window id behind an Accessibility element. Not in Apple's public headers,
/// but it's how every macOS window manager (Paneru, yabai, AeroSpace) does it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Focusing one specific window, and the permissions the overview needs.
enum WindowFocus {
    /// Accessibility permission (focus a specific window, the ⌥O shortcut)
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Screen Recording permission (live previews)
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    static func requestCapture() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openPrivacyPane(_ anchor: String) {
        Permissions.openPane(anchor)
    }

    /// The process that owns a window (no permission needed).
    static func owner(of windowID: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let pid = info[kCGWindowOwnerPID as String] as? Int32
        else { return nil }
        return pid
    }

    /// Raises and focuses exactly this window. Paneru sees the focus change and
    /// scrolls its strip to it. Safe to call off the main thread, and gives up
    /// after half a second if the app doesn't answer (a hung app used to be
    /// able to stall Ledge for six).
    @discardableResult
    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return false }

        for window in windows {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &id) == .success, id == windowID else { continue }
            AXUIElementSetMessagingTimeout(window, 0.5)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let activate = { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
            if Thread.isMainThread { activate() } else { DispatchQueue.main.async(execute: activate) }
            return true
        }
        return false
    }

    /// Owner lookup plus focus in one go.
    @discardableResult
    static func focus(windowID: CGWindowID) -> Bool {
        guard trusted, let pid = owner(of: windowID) else { return false }
        return focus(windowID: windowID, pid: pid)
    }
}
