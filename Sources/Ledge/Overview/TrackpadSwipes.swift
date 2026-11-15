import AppKit
import Foundation

/// Three-finger vertical swipes on the trackpad.
///
/// Read straight from the trackpad through Apple's private MultitouchSupport
/// framework (what MiddleClick and BetterTouchTool use), not from the event
/// stream: Paneru grabs three-finger gestures out of the event stream before
/// anyone else can see them. This only reads finger positions, it can't block
/// or delay any input, and needs no permission.
///
/// Swipes that start out sideways are ignored, those belong to Paneru's strip.
final class TrackpadSwipes {
    /// One swipe, decided: fingers went up (true) or down. Called on the
    /// main thread, once per swipe.
    var onSwipe: (_ up: Bool) -> Void = { _ in }

    /// the C callback can't capture, so it finds us here
    fileprivate static var current: TrackpadSwipes?

    private var devices: [UnsafeMutableRawPointer] = []
    private var deviceList: CFArray?
    var isRunning: Bool { !devices.isEmpty }
    private var wakeObserver: Any?

    // touch thread only. Kept to a few numbers: this runs for every frame
    // while three fingers are down, so it allocates nothing.
    private var tracking = false
    private var decided = false      // axis known (and for sideways: ignore the rest)
    private var vertical = false
    private var fired = false
    private var originX: Float = 0
    private var originY: Float = 0
    private var lastDY: Float = 0
    private var startTime: Double = 0
    private var lastTime: Double = 0
    private var loggedFirstEvent = false

    static let fingers = 3
    /// how far fingers move before the swipe decides if it's up/down or sideways
    static let axisSlop: Float = 0.02
    /// travel (in trackpad heights) that switches workspace mid-swipe
    static let distance: Float = 0.12
    /// a shorter swipe still counts if it's quick (heights per second)
    static let flickDistance: Float = 0.04
    static let flickSpeed: Float = 0.6

    @discardableResult
    func start() -> Bool {
        guard devices.isEmpty else { return true }
        guard let api = MultitouchAPI.shared else {
            NSLog("Ledge: MultitouchSupport isn't available, three-finger swipes are off")
            return false
        }
        Self.current = self
        // kept (never released): the devices in it must outlive the callbacks
        guard let list = api.createList()?.takeUnretainedValue() else { return false }
        deviceList = list
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            api.register(pointer, contactCallback)
            api.start(pointer, 0)
            devices.append(pointer)
        }
        NSLog("Ledge: listening for three-finger swipes on \(devices.count) trackpad(s)")

        // trackpads stop reporting after sleep until they're started again
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.stop()
                self.start()
            }
        }
        return !devices.isEmpty
    }

    /// Stops reading the trackpad entirely (when Paneru handles the swipes).
    func stop() {
        if let api = MultitouchAPI.shared {
            for device in devices {
                api.unregister(device, contactCallback)
                api.stop(device)
            }
        }
        devices = []
        deviceList = nil
    }

    /// Called on MultitouchSupport's thread with every frame of contacts.
    fileprivate func frame(_ data: UnsafeMutableRawPointer?, count: Int, time: Double) {
        // the common case (one or two fingers moving the pointer or scrolling)
        // costs one comparison
        guard count == Self.fingers, let data else {
            if tracking {
                finish()
                ThreeFingerScrollGate.shared.fingersDown = false
            }
            return
        }
        if !loggedFirstEvent {
            loggedFirstEvent = true
            NSLog("Ledge: three-finger touches are coming through")
        }

        var sumX: Float = 0
        var sumY: Float = 0
        for i in 0..<count {
            let finger = data.advanced(by: i * MultitouchAPI.fingerStride)
            sumX += finger.load(fromByteOffset: MultitouchAPI.positionOffset, as: Float.self)
            sumY += finger.load(fromByteOffset: MultitouchAPI.positionOffset + 4, as: Float.self)
        }
        let x = sumX / Float(count)
        let y = sumY / Float(count)

        if !tracking {
            ThreeFingerScrollGate.shared.fingersDown = true
            tracking = true
            decided = false
            vertical = false
            fired = false
            originX = x
            originY = y
            lastDY = 0
            startTime = time
            lastTime = time
            return
        }
        // one switch per swipe; sideways swipes belong to Paneru
        if fired || (decided && !vertical) { return }

        let dx = x - originX
        let dy = y - originY   // 0 is the edge nearest you, so up is positive
        if !decided {
            guard dx * dx + dy * dy > Self.axisSlop * Self.axisSlop else { return }
            decided = true
            vertical = abs(dy) > abs(dx)
            if !vertical { return }
        }
        lastDY = dy
        lastTime = time
        if abs(dy) > Self.distance { fire(up: dy > 0) }
    }

    private func finish() {
        defer { tracking = false }
        guard vertical, !fired else { return }
        let duration = Float(lastTime - startTime)
        if abs(lastDY) > Self.flickDistance, duration > 0, abs(lastDY) / duration > Self.flickSpeed {
            fire(up: lastDY > 0)
        }
    }

    private func fire(up: Bool) {
        fired = true
        DispatchQueue.main.async { self.onSwipe(up) }
    }
}

/// Keeps three-finger swipes from scrolling the window under them.
///
/// Paneru swallows the three-finger movements it handles (sideways), but lets
/// the vertical ones through when Ledge handles those, and macOS turns them
/// into a scroll in the active window. This filter sits after Paneru (Paneru
/// sees every event first, so its swipes are untouched) and drops scroll and
/// gesture events while three fingers are down, plus the momentum scroll that
/// follows. Two-finger scrolling never has three fingers down, so it passes.
///
/// An event tap sees every scroll on the system, so it lives on its own
/// thread and does nothing but read one flag.
final class ThreeFingerScrollGate {
    static let shared = ThreeFingerScrollGate()

    /// set from the trackpad's thread, read on the tap's
    var fingersDown: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fingersDown }
        set { lock.lock(); _fingersDown = newValue; lock.unlock() }
    }
    private var _fingersDown = false
    private let lock = NSLock()

    private var tap: CFMachPort?
    /// tap thread only: a swipe was swallowed, so its momentum goes too
    private var swallowingMomentum = false

    static let gestureEventType: UInt32 = 29

    func start() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue) | CGEventMask(1 << Self.gestureEventType)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let gate = Unmanaged<ThreeFingerScrollGate>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = gate.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let down = gate.fingersDown
            if type == .scrollWheel {
                let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                if down {
                    gate.swallowingMomentum = true
                    return nil
                }
                if momentum != 0, gate.swallowingMomentum {
                    if momentum == 3 { gate.swallowingMomentum = false }  // momentum ended
                    return nil
                }
                if momentum == 0 { gate.swallowingMomentum = false }  // a new scroll
                return Unmanaged.passUnretained(event)
            }
            return down ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Ledge: can't filter three-finger scrolls (needs Accessibility)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Ledge scroll gate"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        fingersDown = false
    }
}

/// Every frame of finger contacts from a trackpad.
private let contactCallback: MultitouchAPI.ContactCallback = { _, data, count, timestamp, _ in
    TrackpadSwipes.current?.frame(data, count: Int(count), time: timestamp)
    return 0
}

/// The few MultitouchSupport functions needed, looked up at runtime so
/// nothing links against a private framework.
private struct MultitouchAPI {
    typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeMutableRawPointer?, ContactCallback?) -> Void
    typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let createList: CreateList
    let register: Register
    let unregister: Register
    let start: Start
    let stop: Stop

    /// Layout of one finger (MTTouch, 96 bytes): frame, timestamp, identifier,
    /// state, finger and hand ids, then the normalized position (x, y in 0...1).
    static let fingerStride = 96
    static let positionOffset = 32

    static let shared: MultitouchAPI? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let createList = symbol("MTDeviceCreateList", CreateList.self),
              let register = symbol("MTRegisterContactFrameCallback", Register.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", Register.self),
              let start = symbol("MTDeviceStart", Start.self),
              let stop = symbol("MTDeviceStop", Stop.self)
        else { return nil }
        return MultitouchAPI(createList: createList, register: register, unregister: unregister, start: start, stop: stop)
    }()
}
