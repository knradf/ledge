import Foundation

/// Upload / download speed of the interface currently in use.
/// A speed is bytes over time, so this one samples: one timer, every 2 s.
final class NetworkSpeedMonitor: ObservableObject {
    /// Formatted like "235K", "1.4M"; nil when under the threshold.
    @Published private(set) var down: String?
    @Published private(set) var up: String?

    private var last: (interface: String, rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var timer: Timer?
    private var loggedProblem = false

    /// Only runs while the Network Speed item is in the bar.
    func update(shown: Bool) {
        shown ? start() : stop()
    }

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
        timer.tolerance = 0.5   // lets macOS batch it with other wakeups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        last = nil
        set(down: nil, up: nil)
    }

    private func sample() {
        guard let name = NetUtil.primaryInterface() else {
            report("no primary network interface")
            last = nil
            set(down: nil, up: nil)
            return
        }
        guard let counters = NetUtil.byteCounters(for: name) else {
            report("no byte counters for \(name)")
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let last, last.interface == name, now > last.time {
            let dt = now - last.time
            // counters only go up; a drop means the interface was reset
            let rx = counters.rx >= last.rx ? counters.rx - last.rx : 0
            let tx = counters.tx >= last.tx ? counters.tx - last.tx : 0
            set(down: Self.format(Double(rx) / dt), up: Self.format(Double(tx) / dt))
        }
        last = (name, counters.rx, counters.tx, now)
    }

    private func set(down newDown: String?, up newUp: String?) {
        if down != newDown { down = newDown }
        if up != newUp { up = newUp }
    }

    private func report(_ problem: String) {
        guard !loggedProblem else { return }
        loggedProblem = true
        NSLog("Ledge network: \(problem)")
    }

    /// bytes/s -> nil | 12K | 235K | 1.4M | 24M | 1.1G  (never more than 4 characters)
    static func format(_ bytesPerSecond: Double) -> String? {
        let k = bytesPerSecond / 1024
        if k < LedgeSettings.shared.networkThresholdKB { return nil }
        if k < 999.5 { return "\(Int(k.rounded()))K" }
        let m = k / 1024
        if m < 9.95 { return String(format: "%.1fM", m) }
        if m < 999.5 { return "\(Int(m.rounded()))M" }
        return String(format: "%.1fG", m / 1024)
    }
}
