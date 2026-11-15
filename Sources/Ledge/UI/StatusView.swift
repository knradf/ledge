import AppKit
import SwiftUI

/// Right side: your status items in your order, split into pills at every divider.
struct StatusView: View {
    @EnvironmentObject var settings: LedgeSettings
    @EnvironmentObject var wifi: WiFiMonitor
    @EnvironmentObject var battery: BatteryMonitor

    var body: some View {
        HStack(spacing: settings.pillGap) {
            ForEach(groups, id: \.self) { group in
                Pill(padding: StatusMetrics.pillPadding) {
                    HStack(spacing: 0) {
                        ForEach(group) { entry in
                            StatusItem(entry: entry)
                        }
                    }
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .font(Theme.menuFont)
        // the size macOS draws its own menu bar icons at (.large was a few
        // points taller and wider, and the speaker spilled over its percentage)
        .imageScale(.medium)
        .animation(Theme.animation, value: groups)
    }

    private var groups: [[StatusEntry]] {
        var result: [[StatusEntry]] = [[]]
        for slot in settings.statusLayout {
            if slot.isDivider {
                result.append([])
            } else if let item = slot.item, isAvailable(item) {
                result[result.count - 1].append(item)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// Hide items this Mac can't show (no battery, no Wi-Fi card).
    private func isAvailable(_ entry: StatusEntry) -> Bool {
        switch entry {
        case .wifi: return wifi.available
        case .battery: return battery.percent != nil
        default: return true
        }
    }
}

/// Spacing and highlight of the status items, the way the system menu bar
/// does them: every item has the same padding, and the one you click gets
/// a capsule behind it while its menu is open.
enum StatusMetrics {
    static let itemPadding: CGFloat = 6
    static let highlightHeight: CGFloat = 22
    /// keeps the highlight as far from the pill's sides as from its top and bottom
    static let pillPadding: CGFloat = (BarMetrics.pillHeight - highlightHeight) / 2
    static let highlightOpacity: Double = 0.16
}

/// Which status item is pressed or has its menu open.
final class StatusHighlight: ObservableObject {
    static let shared = StatusHighlight()
    @Published var id: String?
}

struct StatusItem: View {
    let entry: StatusEntry
    @EnvironmentObject var wifi: WiFiMonitor
    @EnvironmentObject var bluetooth: BluetoothMonitor
    @EnvironmentObject var audio: AudioMonitor
    @EnvironmentObject var input: InputSourceMonitor
    @EnvironmentObject var battery: BatteryMonitor

    var body: some View {
        switch entry {
        case .wifi:
            StatusControl(id: "wifi", menu: { StatusMenus.wifi(wifi) }) { WiFiItem() }
        case .network:
            // nothing to click: same spacing, no highlight
            NetworkItem().padding(.horizontal, StatusMetrics.itemPadding)
        case .bluetooth:
            StatusControl(id: "bluetooth", menu: { StatusMenus.bluetooth(bluetooth) }) { BluetoothItem() }
        case .sound:
            // click: menu, right-click: mute, scroll: louder / quieter
            StatusControl(
                id: "sound",
                menu: { StatusMenus.sound(audio) },
                onRight: { audio.toggleMute() },
                onScroll: { audio.step($0) }
            ) { SoundItem() }
        case .battery:
            StatusControl(id: "battery", menu: { StatusMenus.battery(battery) }) { BatteryItem() }
        case .textInput:
            StatusControl(id: "input", menu: { StatusMenus.input(input) }) { InputItem() }
        case .airdrop:
            StatusControl(id: "airdrop", action: {
                StatusItem.open("/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
            }, help: "AirDrop") {
                Image(systemName: "paperplane").frame(width: 20)
            }
        case .siri:
            StatusControl(id: "siri", action: { StatusItem.open("/System/Applications/Siri.app") }, help: "Siri") {
                Image(systemName: "waveform.circle").frame(width: 20)
            }
        }
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// One clickable status item: even padding, the highlight, and its menu
/// (or action) on click.
struct StatusControl<Content: View>: View {
    let id: String
    var menu: (() -> NSMenu)?
    var action: () -> Void
    var onRight: () -> Void
    var onScroll: (Int) -> Void
    var help: String?
    let content: Content
    @ObservedObject private var highlight = StatusHighlight.shared

    init(id: String, menu: (() -> NSMenu)? = nil, action: @escaping () -> Void = {},
         onRight: @escaping () -> Void = {}, onScroll: @escaping (Int) -> Void = { _ in },
         help: String? = nil, @ViewBuilder content: () -> Content) {
        self.help = help
        self.id = id
        self.menu = menu
        self.action = action
        self.onRight = onRight
        self.onScroll = onScroll
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, StatusMetrics.itemPadding)
            .frame(height: StatusMetrics.highlightHeight)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(highlight.id == id ? StatusMetrics.highlightOpacity : 0))
            )
            .contentShape(Capsule())
            .overlay(
                MouseCatcher(
                    onLeft: action,
                    onRight: onRight,
                    onScroll: onScroll,
                    menu: menu,
                    onPress: { pressed in
                        if pressed {
                            highlight.id = id
                        } else if highlight.id == id {
                            highlight.id = nil
                        }
                    },
                    help: help
                )
            )
    }
}

// MARK: Wi-Fi

struct WiFiItem: View {
    @EnvironmentObject var wifi: WiFiMonitor

    var body: some View {
        Group {
            if wifi.powered {
                // bars fill with signal strength, like the system's
                Image(systemName: "wifi", variableValue: wifi.connected ? wifi.strength : 0)
            } else {
                Image(systemName: "wifi.slash")
            }
        }
            .opacity(wifi.connected ? 1 : 0.4)
            .frame(width: 20)
    }
}

// MARK: Network speed

struct NetworkItem: View {
    @EnvironmentObject var network: NetworkSpeedMonitor

    var body: some View {
        HStack(spacing: 6) {
            SpeedItem(symbol: "arrow.down", text: network.down)
            SpeedItem(symbol: "arrow.up", text: network.up)
        }
    }
}

/// Arrow first, then the value (same order as every other item); takes only
/// the room its value needs, and none when there's nothing to show.
struct SpeedItem: View {
    let symbol: String
    let text: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: max(8, Theme.menuFontSize - 4), weight: .semibold))
                .imageScale(.medium)
                .opacity(text == nil ? 0.3 : 1)
            if let text {
                Text(text)
                    .font(Theme.menuFont.monospacedDigit())
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(Theme.animation, value: text == nil)
    }
}

// MARK: Bluetooth

struct BluetoothItem: View {
    @EnvironmentObject var bluetooth: BluetoothMonitor

    var body: some View {
        BluetoothRune()
            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 7, height: 13)
            .frame(width: 16, height: 18)
            .opacity(bluetooth.connected.isEmpty ? 0.4 : 1)
            .onAppear { bluetooth.startIfNeeded() }
    }
}

/// The Bluetooth rune, drawn (SF Symbols doesn't include it).
struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0, 0.27))
        path.addLine(to: point(1, 0.73))
        path.addLine(to: point(0.5, 1))
        path.addLine(to: point(0.5, 0))
        path.addLine(to: point(1, 0.27))
        path.addLine(to: point(0, 0.73))
        return path
    }
}

// MARK: Sound

struct SoundItem: View {
    @EnvironmentObject var audio: AudioMonitor
    @EnvironmentObject var settings: LedgeSettings

    var body: some View {
        HStack(spacing: 3) {
            // fixed, so the percentage doesn't jump when the icon changes
            // (muted and loud aren't the same width); fits the widest one
            speaker
                .frame(width: 22, alignment: .leading)
            if settings.soundShowPercent, let volume = audio.volume {
                Text("\(Int((volume * 100).rounded()))%")
                    .font(Theme.menuFont.monospacedDigit())
            }
        }
        .opacity(audio.muted || audio.volume == nil ? 0.5 : 1)
    }

    /// Waves fill with the volume, like the system's.
    @ViewBuilder
    private var speaker: some View {
        if let volume = audio.volume, !audio.muted {
            Image(systemName: "speaker.wave.3.fill", variableValue: Double(volume))
        } else if audio.volume == nil {
            Image(systemName: "speaker.fill")
        } else {
            Image(systemName: "speaker.slash.fill")
        }
    }
}

// MARK: Battery

struct BatteryItem: View {
    @EnvironmentObject var battery: BatteryMonitor
    @EnvironmentObject var settings: LedgeSettings

    var body: some View {
        let percent = battery.percent ?? 0
        BatteryGlyph(
            percent: percent,
            charging: battery.charging || battery.onAC,
            showPercent: settings.batteryShowPercent,
            low: percent <= 15 && !battery.onAC
        )
        .help("\(percent)%")
    }
}

/// The battery as macOS 26 and later draw it in the menu bar: a rounded
/// body that fills with the charge, a small cap, and the percentage (and a
/// bolt while charging) cut out of it.
struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    let showPercent: Bool
    let low: Bool

    static let size = CGSize(width: 25, height: 12)
    static let corner: CGFloat = 4

    var body: some View {
        let level = CGFloat(min(max(percent, 0), 100)) / 100
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                shape.fill(Color.primary.opacity(0.35))
                Rectangle()
                    .fill(low ? Color.red : Color.primary)
                    .frame(width: Self.size.width * level)
                if showPercent || charging {
                    HStack(spacing: 0.5) {
                        if showPercent {
                            Text("\(percent)")
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        }
                        if charging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: showPercent ? 6.5 : 8.5, weight: .bold))
                        }
                    }
                    .frame(width: Self.size.width, height: Self.size.height)
                    .blendMode(.destinationOut)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(shape)
            .compositingGroup()
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.primary.opacity(0.35))
                .frame(width: 1.5, height: 4.5)
        }
        .animation(Theme.animation, value: percent)
    }
}

// MARK: Text Input

struct InputItem: View {
    @EnvironmentObject var input: InputSourceMonitor

    var body: some View {
        Text(input.current?.short ?? "--")
            .font(.system(size: max(9, Theme.menuFontSize - 3), weight: .semibold))
            .padding(.horizontal, 3)
            .frame(minWidth: 20, minHeight: 15)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: 1.1)
            )
            .help(input.current?.name ?? "")
    }
}

// MARK: shared

struct MenuHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

enum SystemSettings {
    /// Opens a System Settings pane by its extension id.
    static func open(_ pane: String) {
        Dropdown.shared.close()
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
