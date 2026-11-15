import Foundation
import IOKit.ps

/// Battery level and charging state, updated by IOKit's power-source
/// notification (no polling).
final class BatteryMonitor: ObservableObject {
    @Published private(set) var percent: Int?   // nil on Macs without a battery
    @Published private(set) var charging = false
    @Published private(set) var onAC = false

    private var source: CFRunLoopSource?

    func start() {
        update()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().update()
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    func update() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let listRef = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
        else {
            percent = nil
            return
        }
        let list = listRef as [AnyObject]
        for ps in list {
            guard let info = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any],
                  (info["Type"] as? String) == "InternalBattery"
            else { continue }

            let current = info["Current Capacity"] as? Int ?? 0
            let max = info["Max Capacity"] as? Int ?? 100
            let value = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let isCharging = info["Is Charging"] as? Bool ?? false
            let isAC = (info["Power Source State"] as? String) == "AC Power"

            if percent != value { percent = value }
            if charging != isCharging { charging = isCharging }
            if onAC != isAC { onAC = isAC }
            return
        }
        percent = nil
    }
}
