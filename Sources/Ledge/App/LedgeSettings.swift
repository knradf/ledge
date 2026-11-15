import Foundation

enum AppStyle: String, CaseIterable, Identifiable {
    case glyphs
    case icons

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glyphs: return "Glyphs"
        case .icons: return "App icons"
        }
    }
}

/// Where the clock sits: the middle of the bar, or after the status items.
enum ClockPosition: String, CaseIterable, Identifiable {
    case center
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .center: return "Center"
        case .right: return "Right"
        }
    }
}

/// Light or dark bar. Match Wallpaper looks at what's behind the bar, like
/// the macOS menu bar does: white text on dark wallpaper, dark on light.
enum BarAppearance: String, CaseIterable, Identifiable {
    case wallpaper
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wallpaper: return "Match Wallpaper"
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum BarStyle: String, CaseIterable, Identifiable {
    case glass
    case frosted
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "Glass"
        case .frosted: return "Frosted"
        case .none: return "Minimal"
        }
    }
}

/// Things that can sit on the right side of the bar.
enum StatusEntry: String, CaseIterable, Identifiable {
    case wifi, network, bluetooth, sound, battery, textInput, airdrop, siri

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .network: return "Network Speed"
        case .bluetooth: return "Bluetooth"
        case .sound: return "Sound"
        case .battery: return "Battery"
        case .textInput: return "Text Input"
        case .airdrop: return "AirDrop"
        case .siri: return "Siri"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .network: return "arrow.up.arrow.down"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .sound: return "speaker.wave.2.fill"
        case .battery: return "battery.75"
        case .textInput: return "keyboard"
        case .airdrop: return "paperplane.fill"
        case .siri: return "waveform"
        }
    }
}

/// Whether the sound watcher's app list is what to ignore or what to keep.
enum SoundFilterMode: String {
    case allExcept
    case only
}

/// An app in a settings list.
struct FilterApp: Codable, Identifiable, Equatable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// What a three-finger swipe up or down does.
enum SwipeDirection: String, CaseIterable, Identifiable {
    case off
    case upGoesAbove
    case upGoesBelow

    var id: String { rawValue }
}

/// "When this app opens, put it on workspace N."
struct WorkspaceRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var name: String
    var workspace: Int
}

/// One position on the right side of the bar: an item, or a divider that
/// starts a new pill.
struct LayoutSlot: Identifiable, Hashable {
    /// the item's raw value, or "divider:<uuid>"
    let id: String

    var item: StatusEntry? { StatusEntry(rawValue: id) }
    var isDivider: Bool { id.hasPrefix("divider:") }

    static func divider() -> LayoutSlot { LayoutSlot(id: "divider:" + UUID().uuidString) }
    static func of(_ item: StatusEntry) -> LayoutSlot { LayoutSlot(id: item.rawValue) }

    static var defaultLayout: [LayoutSlot] {
        [.of(.wifi), .of(.network), .divider(), .of(.sound), .of(.battery)]
    }

    /// Keeps known items once each, and dividers; drops anything else.
    static func sanitize(_ ids: [String]) -> [LayoutSlot] {
        var seen = Set<String>()
        var result: [LayoutSlot] = []
        for id in ids {
            let slot = LayoutSlot(id: id)
            if slot.isDivider || (slot.item != nil && !seen.contains(id)) {
                seen.insert(id)
                result.append(slot)
            }
        }
        return result
    }

    /// Settings from 0.5 kept an order, an enabled set and three fixed breaks.
    static func migrate(order: [String], enabled: Set<String>) -> [LayoutSlot] {
        var ids: [String] = []
        for id in order where enabled.contains(id) {
            ids.append(id.hasPrefix("break") ? "divider:" + UUID().uuidString : id)
        }
        return sanitize(ids)
    }
}

/// User settings, saved to UserDefaults on every change.
/// Plain ObservableObject on purpose: @AppStorage/@State are macros in the
/// macOS 27 SDK and need full Xcode to build.
final class LedgeSettings: ObservableObject {
    static let shared = LedgeSettings()

    private static let defaults: [String: Any] = [
        "barStyle": BarStyle.glass.rawValue,
        "barAppearance": BarAppearance.wallpaper.rawValue,
        "edgeMargin": 12.0,
        "topOffset": 4.0,
        "pillGap": 6.0,
        "showNumbers": false,
        "showApps": false,
        "appStyle": AppStyle.glyphs.rawValue,
        "showWindowCount": true,
        "workspaceSlide": false,
        // new installs choose in the welcome
        "paneruTopFollowsBar": false,
        "networkThresholdKB": 10.0,
        "clock24h": true,
        "clockShowDate": false,
        "clockShowSeconds": false,
        "clockPosition": ClockPosition.center.rawValue,
        "soundShowPercent": true,
        "batteryShowPercent": true,
        "overviewShortcut": true,
        "hotCorner": "topLeft",
        "overviewReverseScroll": false,
        "overviewZoom": 0.42,
        "showEmptyWorkspaces": false,
        "desktopSwipe": SwipeDirection.off.rawValue,
    ]

    private let store = UserDefaults.standard

    // appearance
    @Published var barStyle: BarStyle { didSet { store.set(barStyle.rawValue, forKey: "barStyle") } }
    /// light or dark bar picked from the wallpaper behind it (like the macOS menu bar)
    @Published var barAppearance: BarAppearance { didSet { store.set(barAppearance.rawValue, forKey: "barAppearance") } }

    // layout
    @Published var edgeMargin: Double { didSet { store.set(edgeMargin, forKey: "edgeMargin") } }
    @Published var topOffset: Double { didSet { store.set(topOffset, forKey: "topOffset") } }
    @Published var pillGap: Double { didSet { store.set(pillGap, forKey: "pillGap") } }

    // workspaces
    @Published var showNumbers: Bool { didSet { store.set(showNumbers, forKey: "showNumbers") } }
    @Published var showApps: Bool { didSet { store.set(showApps, forKey: "showApps") } }
    @Published var appStyle: AppStyle { didSet { store.set(appStyle.rawValue, forKey: "appStyle") } }
    @Published var showWindowCount: Bool { didSet { store.set(showWindowCount, forKey: "showWindowCount") } }
    /// experimental: Ledge's snapshot slide between workspaces
    @Published var workspaceSlide: Bool { didSet { store.set(workspaceSlide, forKey: "workspaceSlide") } }
    /// Paneru's top padding is kept just below Ledge's bar
    @Published var paneruTopFollowsBar: Bool { didSet { store.set(paneruTopFollowsBar, forKey: "paneruTopFollowsBar") } }
    /// 1 to the last used workspace plus one more, empty ones included
    @Published var showEmptyWorkspaces: Bool { didSet { store.set(showEmptyWorkspaces, forKey: "showEmptyWorkspaces") } }
    /// three fingers up/down on the desktop; off leaves it to Paneru
    @Published var desktopSwipe: SwipeDirection { didSet { store.set(desktopSwipe.rawValue, forKey: "desktopSwipe") } }

    // status items
    @Published var statusLayout: [LayoutSlot] {
        didSet { store.set(statusLayout.map { $0.id }, forKey: "statusLayout") }
    }
    @Published var networkThresholdKB: Double { didSet { store.set(networkThresholdKB, forKey: "networkThresholdKB") } }
    @Published var soundShowPercent: Bool { didSet { store.set(soundShowPercent, forKey: "soundShowPercent") } }
    @Published var batteryShowPercent: Bool { didSet { store.set(batteryShowPercent, forKey: "batteryShowPercent") } }

    // overview
    @Published var overviewShortcut: Bool { didSet { store.set(overviewShortcut, forKey: "overviewShortcut") } }
    @Published var hotCorner: HotCornerPosition { didSet { store.set(hotCorner.rawValue, forKey: "hotCorner") } }
    /// off: scrolling moves the stack like a page (follows the system's direction)
    @Published var overviewReverseScroll: Bool { didSet { store.set(overviewReverseScroll, forKey: "overviewReverseScroll") } }
    /// how far the camera pulls back
    @Published var overviewZoom: Double { didSet { store.set(overviewZoom, forKey: "overviewZoom") } }

    // island
    @Published var soundFilterMode: SoundFilterMode { didSet { store.set(soundFilterMode.rawValue, forKey: "soundFilterMode") } }
    @Published var soundFilterApps: [FilterApp] {
        didSet {
            if let data = try? JSONEncoder().encode(soundFilterApps) { store.set(data, forKey: "soundFilterApps") }
        }
    }

    /// Does sound from this app count?
    func soundCounts(_ bundleID: String) -> Bool {
        let listed = soundFilterApps.contains { $0.bundleID == bundleID }
        return soundFilterMode == .allExcept ? !listed : listed
    }

    // window rules
    @Published var workspaceRules: [WorkspaceRule] {
        didSet {
            if let data = try? JSONEncoder().encode(workspaceRules) { store.set(data, forKey: "workspaceRules") }
        }
    }

    // clock
    @Published var clock24h: Bool { didSet { store.set(clock24h, forKey: "clock24h") } }
    @Published var clockShowDate: Bool { didSet { store.set(clockShowDate, forKey: "clockShowDate") } }
    @Published var clockShowSeconds: Bool { didSet { store.set(clockShowSeconds, forKey: "clockShowSeconds") } }
    @Published var clockPosition: ClockPosition { didSet { store.set(clockPosition.rawValue, forKey: "clockPosition") } }

    init() {
        store.register(defaults: Self.defaults)
        barStyle = BarStyle(rawValue: store.string(forKey: "barStyle") ?? "") ?? .glass
        // older versions had an on/off "adapt to wallpaper"
        if store.object(forKey: "barAppearance") == nil, store.object(forKey: "adaptToWallpaper") != nil {
            store.set(store.bool(forKey: "adaptToWallpaper") ? "wallpaper" : "system", forKey: "barAppearance")
        }
        barAppearance = BarAppearance(rawValue: store.string(forKey: "barAppearance") ?? "") ?? .wallpaper
        edgeMargin = store.double(forKey: "edgeMargin")
        topOffset = store.double(forKey: "topOffset")
        pillGap = store.double(forKey: "pillGap")
        showNumbers = store.bool(forKey: "showNumbers")
        showApps = store.bool(forKey: "showApps")
        appStyle = AppStyle(rawValue: store.string(forKey: "appStyle") ?? "") ?? .glyphs
        showWindowCount = store.bool(forKey: "showWindowCount")
        workspaceSlide = store.bool(forKey: "workspaceSlide")
        paneruTopFollowsBar = store.bool(forKey: "paneruTopFollowsBar")
        networkThresholdKB = store.double(forKey: "networkThresholdKB")
        soundShowPercent = store.bool(forKey: "soundShowPercent")
        batteryShowPercent = store.bool(forKey: "batteryShowPercent")
        overviewShortcut = store.bool(forKey: "overviewShortcut")
        hotCorner = HotCornerPosition(rawValue: store.string(forKey: "hotCorner") ?? "") ?? .topLeft
        overviewReverseScroll = store.bool(forKey: "overviewReverseScroll")
        overviewZoom = store.double(forKey: "overviewZoom")
        showEmptyWorkspaces = store.bool(forKey: "showEmptyWorkspaces")
        desktopSwipe = SwipeDirection(rawValue: store.string(forKey: "desktopSwipe") ?? "") ?? .off
        clock24h = store.bool(forKey: "clock24h")
        clockShowDate = store.bool(forKey: "clockShowDate")
        clockShowSeconds = store.bool(forKey: "clockShowSeconds")
        clockPosition = ClockPosition(rawValue: store.string(forKey: "clockPosition") ?? "") ?? .center

        soundFilterMode = SoundFilterMode(rawValue: store.string(forKey: "soundFilterMode") ?? "") ?? .allExcept
        soundFilterApps = store.data(forKey: "soundFilterApps")
            .flatMap { try? JSONDecoder().decode([FilterApp].self, from: $0) } ?? []
        workspaceRules = store.data(forKey: "workspaceRules")
            .flatMap { try? JSONDecoder().decode([WorkspaceRule].self, from: $0) } ?? []

        if let saved = store.stringArray(forKey: "statusLayout") {
            statusLayout = LayoutSlot.sanitize(saved)
        } else if let oldOrder = store.stringArray(forKey: "statusOrder") {
            let oldEnabled = Set(store.stringArray(forKey: "statusEnabled") ?? [])
            statusLayout = LayoutSlot.migrate(order: oldOrder, enabled: oldEnabled)
        } else {
            statusLayout = LayoutSlot.defaultLayout
        }
    }

    func isEnabled(_ entry: StatusEntry) -> Bool {
        statusLayout.contains(.of(entry))
    }

    /// Checking an item adds it at the end; unchecking removes it.
    func setEnabled(_ entry: StatusEntry, _ on: Bool) {
        if on {
            if !isEnabled(entry) { statusLayout.append(.of(entry)) }
        } else {
            statusLayout.removeAll { $0 == .of(entry) }
        }
    }

    func addDivider() {
        statusLayout.append(.divider())
    }

    func remove(_ slot: LayoutSlot) {
        statusLayout.removeAll { $0 == slot }
    }

    func move(_ slot: LayoutSlot, by offset: Int) {
        guard let index = statusLayout.firstIndex(of: slot) else { return }
        let target = index + offset
        guard statusLayout.indices.contains(target) else { return }
        statusLayout.swapAt(index, target)
    }

    /// Drag and drop in the Arrangement list: the dragged row takes the
    /// target row's place (the rows in between shift by one).
    func move(id: String, to target: LayoutSlot) {
        guard let from = statusLayout.firstIndex(where: { $0.id == id }),
              let to = statusLayout.firstIndex(of: target), from != to
        else { return }
        let slot = statusLayout.remove(at: from)
        statusLayout.insert(slot, at: to)
    }

    func resetStatusItems() {
        statusLayout = LayoutSlot.defaultLayout
    }

    func reset() {
        barStyle = .glass
        barAppearance = .wallpaper
        edgeMargin = 12
        topOffset = 4
        pillGap = 6
        showNumbers = false
        showApps = false
        appStyle = .glyphs
        showWindowCount = true
        workspaceSlide = false
        paneruTopFollowsBar = false
        resetStatusItems()
        networkThresholdKB = 10
        soundShowPercent = true
        batteryShowPercent = true
        overviewShortcut = true
        hotCorner = .topLeft
        overviewReverseScroll = false
        overviewZoom = 0.42
        showEmptyWorkspaces = false
        desktopSwipe = .off
        clock24h = true
        clockShowDate = false
        clockShowSeconds = false
        clockPosition = .center
    }

    // MARK: window rules

    func addRule(bundleID: String, name: String) {
        guard !workspaceRules.contains(where: { $0.bundleID == bundleID }) else { return }
        workspaceRules.append(WorkspaceRule(bundleID: bundleID, name: name, workspace: 1))
    }

    func updateRule(_ id: UUID, _ change: (inout WorkspaceRule) -> Void) {
        guard let index = workspaceRules.firstIndex(where: { $0.id == id }) else { return }
        change(&workspaceRules[index])
    }

    func removeRule(_ id: UUID) {
        workspaceRules.removeAll { $0.id == id }
    }
}
