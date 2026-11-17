import AppKit
import Combine

/// Paneru's own settings as Ledge shows them (Settings → Paneru, plus the
/// swipe and animation bits elsewhere). Read from `paneru.toml` in one go when
/// Settings comes forward (you may have edited it meanwhile); a change shows
/// at once and is written a moment later, so dragging a slider doesn't make
/// Paneru reload its config on every step. Paneru reloads on save.
final class PaneruSettings: ObservableObject {
    static let shared = PaneruSettings()

    // the file
    @Published private(set) var configFound = false
    /// an init.lua replaces the TOML entirely: then Ledge only shows values
    @Published private(set) var usesLua = false
    var editable: Bool { configFound && !usesLua }

    // swiping and animation
    @Published private(set) var verticalSwipes: Bool?
    @Published private(set) var movement = WindowMovement.instant
    @Published private(set) var stripSwipe = StripSwipe.free
    @Published private(set) var haptics = true
    /// Paneru's [swipe] sensitivity (0.1 to 2, default 0.35)
    @Published private(set) var swipeSpeed = 0.35
    /// Paneru's [swipe] deceleration (1 to 10, default 4): higher stops sooner
    @Published private(set) var swipeDeceleration = 4.0
    /// finger travel per window when paging (default 2 cm)
    @Published private(set) var pageDistance = 2.0

    // layout
    @Published private(set) var padding = EdgePadding()
    /// Paneru's [options] menubar_height; nil is its auto value
    @Published private(set) var menubarHeight: Int?
    /// what you see between two windows: twice Paneru's per-window padding
    @Published private(set) var gap = 8
    /// each window's own top and bottom inset ([windows.all] vertical_padding)
    @Published private(set) var windowInset = 4
    @Published private(set) var columnWidths: [Double] = [0.33, 0.5, 0.66, 1.0]
    @Published private(set) var resizeCycle = true

    // focus and mouse
    @Published private(set) var focusFollowsMouse = false
    @Published private(set) var mouseFollowsFocus = false
    @Published private(set) var bringIntoView = BringIntoView.always

    struct EdgePadding: Equatable {
        var top = 0, bottom = 0, left = 0, right = 0
    }

    static let gapSection = "windows.all"
    static let gesture = "swipe.gesture"
    static let swipe = "swipe"
    static let options = "options"
    static let paddingSection = "padding"
    /// Paneru's column width presets Ledge offers (fractions of the screen)
    static let widthChoices: [Double] = [0.25, 0.33, 0.4, 0.5, 0.6, 0.66, 0.75, 1.0]

    private var pending: [String: (section: String, value: String)] = [:]
    private var writeWork: DispatchWorkItem?
    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        reload()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        // the top padding follows Ledge's bar
        let settings = LedgeSettings.shared
        Publishers.CombineLatest(settings.$topOffset, settings.$paneruTopFollowsBar)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] offset, follows in
                guard follows else { return }
                DispatchQueue.main.async { self?.followBar(topOffset: offset) }
            }
            .store(in: &subscriptions)
    }

    // MARK: reading

    func reload() {
        writeNow()
        let luaPath = PaneruConfig.url.deletingLastPathComponent().appendingPathComponent("init.lua").path
        let lua = FileManager.default.fileExists(atPath: luaPath)
        if usesLua != lua { usesLua = lua }
        guard let text = try? String(contentsOf: PaneruConfig.url, encoding: .utf8) else {
            if configFound { configFound = false }
            return
        }
        if !configFound { configFound = true }
        func raw(_ key: String, _ section: String) -> String? { PaneruConfig.value(key, in: section, text: text) }
        func bool(_ key: String, _ section: String, _ fallback: Bool) -> Bool {
            raw(key, section).map { $0 == "true" } ?? fallback
        }
        func int(_ key: String, _ section: String) -> Int { raw(key, section).flatMap { Int($0) } ?? 0 }

        update(\.verticalSwipes, raw("vertical", Self.gesture).map { $0 == "true" })
        update(\.movement, WindowMovement(speed: raw("animation_speed", Self.options).flatMap(Double.init)))
        update(\.stripSwipe, StripSwipe(paging: bool("paging", Self.gesture, false),
                                        autoCenter: bool("auto_center", Self.options, false)))
        update(\.haptics, bool("haptics", Self.gesture, true))
        update(\.swipeSpeed, raw("sensitivity", Self.swipe).flatMap(Double.init) ?? 0.35)
        update(\.swipeDeceleration, raw("deceleration", Self.swipe).flatMap(Double.init) ?? 4)
        update(\.pageDistance, raw("page_distance_cm", Self.gesture).flatMap(Double.init) ?? 2)
        update(\.padding, EdgePadding(top: int("top", Self.paddingSection), bottom: int("bottom", Self.paddingSection),
                                      left: int("left", Self.paddingSection), right: int("right", Self.paddingSection)))
        update(\.menubarHeight, raw("menubar_height", Self.options).flatMap { Int($0) })
        update(\.gap, int("horizontal_padding", Self.gapSection) * 2)
        update(\.windowInset, int("vertical_padding", Self.gapSection))
        if let widths = raw("preset_column_widths", Self.options).map(Self.parseList), !widths.isEmpty {
            update(\.columnWidths, widths)
        }
        update(\.resizeCycle, bool("window_resize_cycle", Self.options, true))
        update(\.focusFollowsMouse, bool("focus_follows_mouse", Self.options, false))
        update(\.mouseFollowsFocus, bool("mouse_follows_focus", Self.options, false))
        update(\.bringIntoView, BringIntoView(ratio: raw("window_hidden_ratio", Self.options).flatMap(Double.init) ?? 0))
    }

    private func update<T: Equatable>(_ path: ReferenceWritableKeyPath<PaneruSettings, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    static func parseList(_ raw: String) -> [Double] {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: changing

    func setVerticalSwipes(_ on: Bool) {
        verticalSwipes = on
        write("vertical", in: Self.gesture, on ? "true" : "false", now: true)
    }

    func setMovement(_ value: WindowMovement) {
        movement = value
        write("animation_speed", in: Self.options, String(Int(value.speed)))
    }

    func setStripSwipe(_ mode: StripSwipe) {
        stripSwipe = mode
        write("paging", in: Self.gesture, mode.paging ? "true" : "false")
        write("auto_center", in: Self.options, mode.autoCenter ? "true" : "false")
    }

    func setHaptics(_ on: Bool) {
        haptics = on
        write("haptics", in: Self.gesture, on ? "true" : "false")
    }

    func setSwipeSpeed(_ value: Double) {
        swipeSpeed = value
        write("sensitivity", in: Self.swipe, String(format: "%g", value))
    }

    func setSwipeDeceleration(_ value: Double) {
        swipeDeceleration = value
        write("deceleration", in: Self.swipe, String(format: "%g", value))
    }

    func setPageDistance(_ value: Double) {
        pageDistance = value
        write("page_distance_cm", in: Self.gesture, String(format: "%g", value))
    }

    func setPadding(_ side: WritableKeyPath<EdgePadding, Int>, _ value: Int) {
        padding[keyPath: side] = value
        let key: String
        switch side {
        case \EdgePadding.top: key = "top"
        case \EdgePadding.bottom: key = "bottom"
        case \EdgePadding.left: key = "left"
        default: key = "right"
        }
        write(key, in: Self.paddingSection, String(value))
    }

    func setGap(_ value: Int) {
        gap = value
        // [windows.all] is a window rule, which needs a title pattern to match anything
        if PaneruConfig.value("title", in: Self.gapSection) == nil, pending["title"] == nil {
            write("title", in: Self.gapSection, "\".*\"")
        }
        write("horizontal_padding", in: Self.gapSection, String(value / 2))
        write("vertical_padding", in: Self.gapSection, String(value / 2))
        windowInset = value / 2
        followBarIfOn()
    }

    func toggleWidth(_ width: Double) {
        var widths = columnWidths
        if let index = widths.firstIndex(where: { abs($0 - width) < 0.005 }) {
            guard widths.count > 1 else { return }  // keep at least one
            widths.remove(at: index)
        } else {
            widths.append(width)
        }
        widths.sort()
        columnWidths = widths
        let list = widths.map { String(format: "%g", $0) }.joined(separator: ", ")
        write("preset_column_widths", in: Self.options, "[" + list + "]")
    }

    func hasWidth(_ width: Double) -> Bool {
        columnWidths.contains { abs($0 - width) < 0.005 }
    }

    func setResizeCycle(_ on: Bool) {
        resizeCycle = on
        write("window_resize_cycle", in: Self.options, on ? "true" : "false")
    }

    func setFocusFollowsMouse(_ on: Bool) {
        focusFollowsMouse = on
        write("focus_follows_mouse", in: Self.options, on ? "true" : "false")
    }

    func setMouseFollowsFocus(_ on: Bool) {
        mouseFollowsFocus = on
        write("mouse_follows_focus", in: Self.options, on ? "true" : "false")
    }

    func setBringIntoView(_ value: BringIntoView) {
        bringIntoView = value
        write("window_hidden_ratio", in: Self.options, String(format: "%g", value.ratio))
    }

    // MARK: the top padding follows Ledge's bar

    /// The bar sits exactly halfway between the screen's top edge and the
    /// windows: the space below it matches the space above it. Paneru adds
    /// each window's own inset on top of the padding, so that comes off.
    func topForBar(topOffset: Double = LedgeSettings.shared.topOffset) -> Int {
        max(0, Int((topOffset * 2 + Double(BarMetrics.pillHeight)).rounded()) - windowInset)
    }

    func followBarIfOn() {
        guard LedgeSettings.shared.paneruTopFollowsBar else { return }
        followBar(topOffset: LedgeSettings.shared.topOffset)
    }

    private func followBar(topOffset: Double) {
        guard editable else { return }
        let top = topForBar(topOffset: topOffset)
        if padding.top != top { setPadding(\.top, top) }
        // The bar starts at the screen's top edge (the macOS menu bar hides),
        // so the padding already covers it. Paneru's automatic menu bar height
        // is ~30 pt even while the menu bar hides, and it adds that on top.
        // A notch still counts: Paneru keeps the larger of the two.
        if menubarHeight != 0 {
            menubarHeight = 0
            write("menubar_height", in: Self.options, "0")
        }
    }

    // MARK: writing

    /// Collects changes and writes them together a moment later.
    private func write(_ key: String, in section: String, _ value: String, now: Bool = false) {
        guard editable else { return }
        pending[section + "\u{1}" + key] = (section, value)
        writeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeNow() }
        writeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.35), execute: work)
    }

    private func writeNow() {
        writeWork?.cancel()
        writeWork = nil
        guard !pending.isEmpty else { return }
        let changes = pending.map { entry in
            (key: String(entry.key.split(separator: "\u{1}").last ?? ""), section: entry.value.section, value: entry.value.value)
        }
        pending = [:]
        PaneruConfig.set(changes)
    }
}

/// When focusing a window that's partly off screen scrolls it into view
/// (Paneru's window_hidden_ratio: how much may be hidden first).
enum BringIntoView: String, CaseIterable, Identifiable {
    case always, halfHidden, fullyHidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: return "Always"
        case .halfHidden: return "When Half Hidden"
        case .fullyHidden: return "Only When Fully Hidden"
        }
    }

    var ratio: Double {
        switch self {
        case .always: return 0
        case .halfHidden: return 0.5
        case .fullyHidden: return 1
        }
    }

    init(ratio: Double) {
        if ratio >= 0.95 {
            self = .fullyHidden
        } else if ratio >= 0.25 {
            self = .halfHidden
        } else {
            self = .always
        }
    }
}
