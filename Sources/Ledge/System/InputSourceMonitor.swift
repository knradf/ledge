import AppKit
import Carbon

/// Current keyboard layout and the enabled ones, from the system's
/// input-source-changed notification (no polling).
final class InputSourceMonitor: ObservableObject {
    struct Source: Identifiable, Equatable {
        let id: String
        let name: String
        /// Short label, e.g. "PL", "EN", "US"
        let short: String
    }

    @Published private(set) var current: Source?
    @Published private(set) var available: [Source] = []

    private var refs: [String: TISInputSource] = [:]

    func start() {
        update()
        let center = DistributedNotificationCenter.default()
        let names: [CFString] = [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged]
        for name in names {
            center.addObserver(forName: Notification.Name(name as String), object: nil, queue: .main) { [weak self] _ in
                self?.update()
            }
        }
    }

    func select(_ source: Source) {
        if let ref = refs[source.id] {
            TISSelectInputSource(ref)
        }
    }

    func update() {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        var newRefs: [String: TISInputSource] = [:]
        var list: [Source] = []
        if let raw = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue(),
           let sources = raw as? [TISInputSource] {
            for ref in sources {
                guard let source = Self.describe(ref) else { continue }
                newRefs[source.id] = ref
                list.append(source)
            }
        }
        refs = newRefs
        if available != list { available = list }

        let now = TISCopyCurrentKeyboardInputSource().flatMap { Self.describe($0.takeRetainedValue()) }
        if current != now { current = now }
    }

    private static func describe(_ ref: TISInputSource) -> Source? {
        guard let id = string(ref, kTISPropertyInputSourceID) else { return nil }
        let name = string(ref, kTISPropertyLocalizedName) ?? id
        return Source(id: id, name: name, short: shortLabel(ref, name: name))
    }

    private static func string(_ ref: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(ref, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Language code from the source ("pl" -> "PL"), else the first letters of its name.
    private static func shortLabel(_ ref: TISInputSource, name: String) -> String {
        if let pointer = TISGetInputSourceProperty(ref, kTISPropertyInputSourceLanguages) {
            let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
            if let first = languages?.first {
                return String(first.prefix(2)).uppercased()
            }
        }
        return String(name.prefix(2)).uppercased()
    }
}
