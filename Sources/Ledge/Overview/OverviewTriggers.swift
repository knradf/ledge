import AppKit
import CoreGraphics

/// The overview's shortcut (Settings → Shortcuts, Super + O by default).
/// Sides matter: with Left Option as Super, right Option + O must still type
/// "ó" on a Polish layout. A Carbon hotkey can't tell the two Options apart,
/// so this listens the way Paneru does (an event tap, needs Accessibility)
/// and only swallows the exact combination.
///
/// The tap sees every keystroke before any app does, so it lives on its own
/// thread: whatever Ledge's main thread is busy with, typing never waits on it.
final class OverviewShortcut {
    var action: () -> Void = {}
    /// Esc while the overview is open. Handled here too, so Esc gets you out
    /// even if the overview somehow lost the keyboard.
    var escapeAction: () -> Void = {}

    /// Read on the tap's thread, written on main.
    private let lock = NSLock()
    private var _combo: Combo?
    private var _paused = false
    private var _escapeArmed = false
    /// nil: no shortcut
    var combo: Combo? {
        get { lock.lock(); defer { lock.unlock() }; return _combo }
        set { lock.lock(); _combo = newValue; lock.unlock() }
    }
    /// while Settings records a shortcut, so it can see this one too
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }
    var escapeArmed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _escapeArmed }
        set { lock.lock(); _escapeArmed = newValue; lock.unlock() }
    }

    static let keyEscape: Int64 = 53

    private var tap: CFMachPort?
    private var thread: Thread?
    var isRunning: Bool { tap != nil }

    /// A shortcut as the tap checks it: the key, the modifier bits that must
    /// be down and the ones that must not.
    struct Combo: Equatable {
        let keyCode: Int64
        let required: UInt64
        let forbidden: UInt64

        /// device-specific modifier bits in CGEventFlags, left and right
        static let sides: [ModifierFamily: (left: UInt64, right: UInt64)] = [
            .control: (0x01, 0x2000), .shift: (0x02, 0x04), .command: (0x08, 0x10), .option: (0x20, 0x40),
        ]
        static let masks: [ModifierFamily: UInt64] = [
            .control: CGEventFlags.maskControl.rawValue, .shift: CGEventFlags.maskShift.rawValue,
            .command: CGEventFlags.maskCommand.rawValue, .option: CGEventFlags.maskAlternate.rawValue,
        ]

        /// From Paneru's spelling ("lalt - o"); nil for a key this layout lacks.
        init?(_ combo: KeyCombo) {
            guard let code = (0..<128).first(where: { KeyNames.name(keyCode: UInt16($0)) == combo.key }) else { return nil }
            var required: UInt64 = 0
            var forbidden: UInt64 = 0
            for family in [ModifierFamily.control, .option, .shift, .command] {
                let mask = Self.masks[family]!, side = Self.sides[family]!
                let tokens = combo.tokens.filter { ModifierFamily(token: $0) == family }
                if tokens.isEmpty {
                    forbidden |= mask
                    continue
                }
                required |= mask
                if tokens.allSatisfy({ $0.hasPrefix("l") }) {
                    required |= side.left
                    forbidden |= side.right
                } else if tokens.allSatisfy({ $0.hasPrefix("r") }) {
                    required |= side.right
                    forbidden |= side.left
                }
            }
            self.init(keyCode: Int64(code), required: required, forbidden: forbidden)
        }

        init(keyCode: Int64, required: UInt64, forbidden: UInt64) {
            self.keyCode = keyCode
            self.required = required
            self.forbidden = forbidden
        }

        func matches(keyCode: Int64, flags: UInt64) -> Bool {
            keyCode == self.keyCode && flags & required == required && flags & forbidden == 0
        }
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<OverviewShortcut>.fromOpaque(refcon).takeUnretainedValue()

            // macOS switches a tap off if it ever stalls. On its own thread it
            // can't stall on Ledge, so switching it back on is safe.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            if keyCode == OverviewShortcut.keyEscape, me.escapeArmed {
                DispatchQueue.main.async { me.escapeAction() }
                return nil
            }
            guard !me.paused, let combo = me.combo,
                  combo.matches(keyCode: keyCode, flags: event.flags.rawValue)
            else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { me.action() }
            }
            return nil  // swallow, so no "ø" gets typed
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Ledge shortcut"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }
}

enum HotCornerPosition: String, CaseIterable, Identifiable {
    case off, topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Is the pointer pushed into this corner of the screen?
    func contains(_ point: CGPoint, in frame: CGRect, tolerance: CGFloat = 1) -> Bool {
        let left = point.x <= frame.minX + tolerance
        let right = point.x >= frame.maxX - tolerance
        let top = point.y >= frame.maxY - tolerance      // AppKit: y grows upward
        let bottom = point.y <= frame.minY + tolerance
        switch self {
        case .off: return false
        case .topLeft: return top && left
        case .topRight: return top && right
        case .bottomLeft: return bottom && left
        case .bottomRight: return bottom && right
        }
    }
}

/// Push the pointer into the chosen corner to toggle the overview. A short
/// dwell keeps it from firing when the mouse just flies past.
final class HotCorner {
    var action: () -> Void = {}
    var position: () -> HotCornerPosition = { .off }

    private var monitors: [Any] = []
    private var inCorner = false
    private var pending: DispatchWorkItem?

    /// Watches the pointer only while a corner is picked: every mouse
    /// move on the system goes through this.
    func update(_ corner: HotCornerPosition) {
        corner == .off ? stop() : start()
    }

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.check() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        inCorner = false
        pending?.cancel()
        pending = nil
    }

    private func check() {
        let corner = position()
        let point = NSEvent.mouseLocation
        let hit = corner != .off && NSScreen.screens.contains { corner.contains(point, in: $0.frame) }

        if hit && !inCorner {
            inCorner = true
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.inCorner else { return }
                self.action()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.hotCornerDelay, execute: work)
        } else if !hit && inCorner {
            inCorner = false
            pending?.cancel()
            pending = nil
        }
    }
}
