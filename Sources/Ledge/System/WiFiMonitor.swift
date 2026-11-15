import CoreWLAN
import Foundation
import Network

/// Wi-Fi power and connection, from CoreWLAN events plus network path
/// changes (no polling).
final class WiFiMonitor: NSObject, ObservableObject, CWEventDelegate {
    @Published private(set) var available = false   // false on Macs without Wi-Fi
    @Published private(set) var powered = false
    @Published private(set) var ip: String?
    /// 0...1 for the Wi-Fi symbol's bars, from the signal strength (RSSI)
    @Published private(set) var strength: Double = 1

    private let client = CWWiFiClient.shared()
    private let pathMonitor = NWPathMonitor()

    var connected: Bool { powered && ip != nil }

    func start() {
        client.delegate = self
        try? client.startMonitoringEvent(with: .powerDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)

        // IP addresses arrive a moment after the link comes up
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ledge.wifi.path"))
        update()
    }

    func update() {
        guard let iface = client.interface() else {
            if available { available = false }
            return
        }
        let isPowered = iface.powerOn()
        let address = iface.interfaceName.flatMap { NetUtil.ipv4(for: $0) }
        if !available { available = true }
        if powered != isPowered { powered = isPowered }
        if ip != address { ip = address }
        let level = Self.level(rssi: iface.rssiValue())
        if strength != level { strength = level }
    }

    /// Roughly how macOS fills the Wi-Fi bars.
    private static func level(rssi: Int) -> Double {
        if rssi == 0 { return 0 }
        if rssi >= -60 { return 1 }
        if rssi >= -70 { return 0.66 }
        if rssi >= -80 { return 0.33 }
        return 0.1
    }

    func setPower(_ on: Bool) {
        guard let iface = client.interface() else { return }
        DispatchQueue.global().async {
            do {
                try iface.setPower(on)
            } catch {
                if let name = iface.interfaceName {
                    _ = Shell.run("/usr/sbin/networksetup", ["-setairportpower", name, on ? "on" : "off"], timeout: 5)
                }
            }
            DispatchQueue.main.async { self.update() }
        }
    }

    // MARK: CWEventDelegate (called on a background thread)

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { self.update() }
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { self.update() }
    }
}
