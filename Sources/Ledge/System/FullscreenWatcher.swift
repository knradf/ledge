import AppKit
import ApplicationServices
import CoreGraphics

/// Finds displays where the frontmost app's window covers the whole screen
/// (games in borderless full screen, video players), so the bar can step aside.
///
/// Checks when apps switch, Spaces change or displays change, and whenever
/// the frontmost app's windows are resized or created: games often go
/// full screen a moment after they come forward. Those window events come
/// through Accessibility, on a thread of their own so a hung app can't stall
/// the bar. Without Accessibility it checks again after 1 and 3 seconds instead.
final class FullscreenWatcher {
    var onChange: ((Set<CGDirectDisplayID>) -> Void)?
    private var covered: Set<CGDirectDisplayID> = []
    private let windowEvents = FrontWindowEvents()
    private var checkPending = false
    /// a resize by dragging fires many events: one check per this
    static let coalesce: TimeInterval = 0.2

    func start() {
        windowEvents.onEvent = { [weak self] in
            DispatchQueue.main.async { self?.checkSoon() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontChanged(app)
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.check()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.check()
        }
        frontChanged(NSWorkspace.shared.frontmostApplication)
    }

    private func frontChanged(_ app: NSRunningApplication?) {
        check()
        if WindowFocus.trusted, let app, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            windowEvents.follow(pid: app.processIdentifier)
        } else {
            windowEvents.follow(pid: nil)
            // no window events to go on: look again once the app has settled
            for delay in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
            }
        }
    }

    private func checkSoon() {
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesce) { [weak self] in
            self?.checkPending = false
            self?.check()
        }
    }

    func check() {
        var now = Set<CGDirectDisplayID>()
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
               as? [[String: Any]] {
            let pid = front.processIdentifier
            for info in list {
                guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
                else { continue }
                for screen in NSScreen.screens {
                    let display = CGDisplayBounds(screen.displayID)  // same top-left coordinates as window bounds
                    if bounds.minX <= display.minX + 1, bounds.minY <= display.minY + 1,
                       bounds.maxX >= display.maxX - 1, bounds.maxY >= display.maxY - 1 {
                        now.insert(screen.displayID)
                    }
                }
            }
        }
        if now != covered {
            covered = now
            onChange?(now)
        }
    }
}

/// Window resized / created notifications from one app, through an
/// Accessibility observer on its own thread and run loop.
final class FrontWindowEvents {
    var onEvent: () -> Void = {}

    private var runLoop: CFRunLoop?
    private var observer: AXObserver?
    private let ready = DispatchSemaphore(value: 0)

    /// not moves: Paneru moves windows on every frame of a strip scroll
    private static let notifications = [
        kAXWindowResizedNotification,
        kAXWindowCreatedNotification,
        kAXMainWindowChangedNotification,
    ]

    init() {
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            self?.ready.signal()
            // a run loop with nothing in it returns at once: a port keeps it alive
            RunLoop.current.add(NSMachPort(), forMode: .default)
            CFRunLoopRun()
        }
        thread.name = "Ledge window events"
        thread.start()
        ready.wait()
    }

    /// Follow this app's windows (nil: stop).
    func follow(pid: pid_t?) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.attach(pid)
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs on the observer's thread.
    private func attach(_ pid: pid_t?) {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            self.observer = nil
        }
        guard let pid else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FrontWindowEvents>.fromOpaque(refcon).takeUnretainedValue().onEvent()
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
    }
}
