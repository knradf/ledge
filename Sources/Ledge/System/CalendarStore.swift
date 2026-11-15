import AppKit
import EventKit

/// Your calendars through EventKit (asks for access the first time the
/// island opens). Refreshes when anything changes in Calendar.
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    enum Access: Equatable { case unknown, granted, denied }

    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
        /// a video call to join, found in the URL, location or notes
        let link: URL?
    }

    @Published private(set) var access: Access = .unknown
    /// the month shown in the mini calendar (any date inside it)
    @Published var month = Date()
    /// the picked day; today shows what's next instead of the whole day
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    /// days in the shown grid that have something on them
    @Published private(set) var busyDays: Set<Date> = []
    @Published private(set) var dayEvents: [Event] = []

    private let store = EKEventStore()
    private var observing = false

    var showingToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    /// Called when the island opens.
    func prepare() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            access = .granted
            observe()
            reload()
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.access = granted ? .granted : .denied
                    Permissions.shared.check()
                    if granted {
                        self?.observe()
                        self?.reload()
                    }
                }
            }
        default:
            access = .denied
        }
    }

    func showToday() {
        month = Date()
        selectedDay = Calendar.current.startOfDay(for: Date())
        reload()
    }

    func shiftMonth(_ step: Int) {
        month = Calendar.current.date(byAdding: .month, value: step, to: month) ?? month
        reload()
    }

    func select(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        reload()
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    func reload() {
        guard access == .granted else { return }
        let calendar = Calendar.current

        // dots for the whole visible grid
        let grid = MonthGrid(month: month, calendar: calendar)
        if let first = grid.days.first, let last = grid.days.last,
           let end = calendar.date(byAdding: .day, value: 1, to: last) {
            var busy = Set<Date>()
            for event in events(from: first, to: end) {
                var day = calendar.startOfDay(for: event.startDate)
                // multi-day events mark every day they cover
                while day < event.endDate && day < end {
                    busy.insert(day)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            }
            if busyDays != busy { busyDays = busy }
        }

        // the list: what's still ahead today (plus tomorrow if today's done),
        // or everything on another picked day
        let dayStart = selectedDay
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        var list: [Event]
        if showingToday {
            let now = Date()
            let horizon = calendar.date(byAdding: .day, value: 2, to: dayStart) ?? dayEnd
            list = events(from: now, to: horizon)
                .filter { !$0.isAllDay && $0.endDate > now }
                .prefix(3)
                .map(Self.event)
        } else {
            list = events(from: dayStart, to: dayEnd).map(Self.event)
        }
        list.sort { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
        if dayEvents != list { dayEvents = list }
    }

    private func events(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    private static func event(_ event: EKEvent) -> Event {
        Event(
            id: (event.eventIdentifier ?? UUID().uuidString) + "@\(event.startDate.timeIntervalSince1970)",
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            allDay: event.isAllDay,
            color: event.calendar.map { NSColor(cgColor: $0.cgColor) ?? .systemBlue } ?? .systemBlue,
            link: meetingLink(url: event.url, location: event.location, notes: event.notes)
        )
    }

    static let meetingHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "whereby.com", "meet.jit.si", "webex.com", "facetime.apple.com", "around.co",
    ]

    /// First link in the event that points at a video call.
    static func meetingLink(url: URL?, location: String?, notes: String?) -> URL? {
        func isMeeting(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        if let url, isMeeting(url) { return url }
        let text = [location, notes].compactMap { $0 }.joined(separator: " ")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let found = match.url, isMeeting(found) { return found }
        }
        return nil
    }

    static func openCalendarApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    static func openPrivacySettings() {
        Permissions.openPane("Privacy_Calendars")
    }
}

/// The days a month view shows: whole weeks from the one holding the 1st to
/// the one holding the last day, starting on your locale's first weekday.
struct MonthGrid {
    let days: [Date]
    let monthStart: Date

    init(month: Date, calendar: Calendar) {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        monthStart = start
        let length = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let weekday = calendar.component(.weekday, from: start)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let total = Int((Double(lead + length) / 7).rounded(.up)) * 7
        let first = calendar.date(byAdding: .day, value: -lead, to: start) ?? start
        days = (0..<total).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
}
