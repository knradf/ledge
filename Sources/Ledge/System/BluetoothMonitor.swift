import Foundation
import IOBluetooth

/// Connected Bluetooth devices, from IOBluetooth connect/disconnect
/// notifications (no polling). Started only when the Bluetooth item is shown,
/// so the permission prompt only appears if you use it.
final class BluetoothMonitor: NSObject, ObservableObject {
    @Published private(set) var connected: [String] = []

    private var started = false
    private var connectNotification: IOBluetoothUserNotification?

    func startIfNeeded() {
        guard !started else { return }
        started = true
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        for device in pairedDevices() where device.isConnected() {
            device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
        update()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        DispatchQueue.main.async { self.update() }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        // the device still reports connected for a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.update() }
    }

    private func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    func update() {
        let names = pairedDevices()
            .filter { $0.isConnected() }
            .compactMap { $0.nameOrAddress }
            .sorted()
        if connected != names { connected = names }
    }
}
