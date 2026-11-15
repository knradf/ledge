import AppKit

/// The status items' menus, as real macOS menus: native highlight, arrow
/// keys, type to select, the system's own open and close.
enum StatusMenus {
    static func wifi(_ wifi: WiFiMonitor) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Wi-Fi"))
        let status: String
        if !wifi.powered {
            status = "Off"
        } else if let ip = wifi.ip {
            status = "IP address: \(ip)"
        } else {
            status = "Not connected"
        }
        menu.addItem(.info(status))
        menu.addItem(.separator())
        menu.addItem(.action(wifi.powered ? "Turn Wi-Fi Off" : "Turn Wi-Fi On") { wifi.setPower(!wifi.powered) })
        menu.addItem(.separator())
        menu.addItem(.action("Wi-Fi Settings…") { SystemSettings.open("com.apple.wifi-settings-extension") })
        return menu
    }

    static func bluetooth(_ bluetooth: BluetoothMonitor) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: bluetooth.connected.isEmpty ? "No Devices Connected" : "Connected"))
        for name in bluetooth.connected {
            menu.addItem(.info(name))
        }
        menu.addItem(.separator())
        menu.addItem(.action("Bluetooth Settings…") { SystemSettings.open("com.apple.BluetoothSettings") })
        return menu
    }

    static func sound(_ audio: AudioMonitor) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Sound"))
        let slider = NSMenuItem()
        slider.view = VolumeSliderView(audio: audio)
        menu.addItem(slider)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Output"))
        for output in audio.outputs {
            let item = NSMenuItem.action(output.name) { audio.setOutput(output.id) }
            item.state = output.id == audio.currentOutput ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.action("Sound Settings…") { SystemSettings.open("com.apple.Sound-Settings.extension") })
        return menu
    }

    static func input(_ input: InputSourceMonitor) -> NSMenu {
        let menu = NSMenu()
        for source in input.available {
            let item = NSMenuItem.action(source.name) { input.select(source) }
            item.state = source.id == input.current?.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.action("Keyboard Settings…") { SystemSettings.open("com.apple.Keyboard-Settings.extension") })
        return menu
    }

    static func battery(_ battery: BatteryMonitor) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Battery \(battery.percent ?? 0)%"))
        let source: String
        if battery.charging {
            source = "Charging"
        } else if battery.onAC {
            source = "Power Adapter"
        } else {
            source = "Battery"
        }
        menu.addItem(.info("Power Source: \(source)"))
        menu.addItem(.separator())
        menu.addItem(.action("Battery Settings…") { SystemSettings.open("com.apple.Battery-Settings.extension") })
        return menu
    }
}

extension NSMenuItem {
    /// An item that runs a closure.
    static func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, run: run)
    }

    /// Plain text in the menu (greyed out, like the system's info lines).
    static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func fire() { run() }
}

/// Volume slider row, laid out like the one in the system's Sound menu.
final class VolumeSliderView: NSView {
    private let audio: AudioMonitor
    private let slider = NSSlider()

    init(audio: AudioMonitor) {
        self.audio = audio
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 28))

        let low = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)!)
        let high = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)!)
        for icon in [low, high] {
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        }
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = Double(audio.volume ?? 0)
        slider.isEnabled = audio.volume != nil
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)

        let row = NSStackView(views: [low, slider, high])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // menu items indent their text 14 pt; line up with that
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func changed() {
        audio.setVolume(Float(slider.doubleValue))
    }
}
