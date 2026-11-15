import AppKit
import SwiftUI

/// Four bars bouncing next to the time while something is playing. Not a
/// real spectrum (that would need to record your audio), just a calm loop.
/// Core Animation plays it in the system's render server, so music playing
/// all day costs Ledge next to nothing (the SwiftUI version redrew every
/// frame, about 4% CPU).
struct SpectrumGlyph: NSViewRepresentable {
    var color: NSColor = .labelColor

    func makeNSView(context: Context) -> SpectrumView {
        let view = SpectrumView()
        view.color = color
        return view
    }

    func updateNSView(_ view: SpectrumView, context: Context) {
        if view.color != color { view.color = color }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpectrumView, context: Context) -> CGSize? {
        SpectrumView.size
    }
}

final class SpectrumView: NSView {
    static let barCount = 4
    static let barWidth: CGFloat = 2.5
    static let gap: CGFloat = 1.5
    static let size = CGSize(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap, height: 12)
    /// each bar has its own pace, so they never move in step
    private static let durations: [CFTimeInterval] = [0.55, 0.42, 0.5, 0.63]

    var color: NSColor = .labelColor { didSet { applyColor() } }
    private var bars: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        for index in 0..<Self.barCount {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            bar.frame = CGRect(x: CGFloat(index) * (Self.barWidth + Self.gap), y: 0,
                               width: Self.barWidth, height: Self.size.height)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        applyColor()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var intrinsicContentSize: NSSize { Self.size }

    override func layout() {
        super.layout()
        let top = (bounds.height - Self.size.height) / 2
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: CGFloat(index) * (Self.barWidth + Self.gap) + Self.barWidth / 2,
                                   y: top + Self.size.height / 2)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { animate() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let cg = color.cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for bar in bars { bar.backgroundColor = cg }
            CATransaction.commit()
        }
    }

    private func animate() {
        for (index, bar) in bars.enumerated() {
            // the middle bars reach a bit higher
            let peak: CGFloat = (index == 1 || index == 2) ? 12 : 9
            let grow = CABasicAnimation(keyPath: "bounds.size.height")
            grow.fromValue = 3
            grow.toValue = peak
            grow.duration = Self.durations[index]
            grow.autoreverses = true
            grow.repeatCount = .infinity
            grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            grow.timeOffset = Double(index) * 0.17
            bar.add(grow, forKey: "bounce")
        }
    }
}

/// What the clock opens: a month, what's next, what's playing, waiting
/// and the way to Ledge's settings.
struct IslandPanel: View {
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var audio: AudioActivity
    @ObservedObject var nowPlaying: NowPlayingStore
    let paneru: PaneruStore

    static let width: CGFloat = 320

    /// the track, unless its app is filtered out in Settings → Rules
    private var track: NowPlayingStore.Track? {
        guard let track = nowPlaying.track else { return nil }
        if let bundle = track.bundleID, !LedgeSettings.shared.soundCounts(bundle) { return nil }
        return track
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track {
                MediaCard(track: track, store: nowPlaying) {
                    if let bundle = track.bundleID { paneru.open(bundleID: bundle) }
                }
                IslandDivider()
            } else if audio.playing, let bundle = audio.apps.first {
                NowPlayingRow(bundleID: bundle, others: audio.apps.count - 1) {
                    paneru.open(bundleID: bundle)
                }
                IslandDivider()
            }

            MiniCalendar(store: calendar)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            IslandDivider()
            EventsSection(store: calendar)

            IslandDivider()
            HStack {
                FooterLink(title: "Open Calendar") { CalendarStore.openCalendarApp() }
                Spacer()
                FooterLink(title: "Ledge Settings…") { SettingsWindowController.shared.show() }
            }
            .padding(.bottom, 2)
        }
        .frame(width: Self.width, alignment: .leading)
        // the panel follows its content's height as things load in
        .onReceive(calendar.objectWillChange) { _ in Dropdown.shared.refitSoon() }
        .onReceive(audio.objectWillChange) { _ in Dropdown.shared.refitSoon() }
        .onReceive(nowPlaying.objectWillChange) { _ in Dropdown.shared.refitSoon() }
    }
}

struct IslandDivider: View {
    var body: some View {
        Divider().padding(.vertical, 6).padding(.horizontal, 4)
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
    }
}

/// Small text button for the bottom row.
struct FooterLink: View {
    let title: String
    let action: () -> Void
    @EnvironmentObject var hover: HoverModel

    var body: some View {
        let hovering = hover.hovered == "footer-" + title
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hover.hovered = "footer-" + title
                } else if hover.hovered == "footer-" + title {
                    hover.hovered = nil
                }
            }
            .onTapGesture {
                Dropdown.shared.close()
                action()
            }
    }
}

// MARK: calendar

struct MiniCalendar: View {
    @ObservedObject var store: CalendarStore

    private var calendar: Calendar { Calendar.current }

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()

    var body: some View {
        let grid = MonthGrid(month: store.month, calendar: calendar)

        VStack(spacing: 6) {
            HStack {
                Text(Self.monthTitle.string(from: grid.monthStart))
                    .font(.system(size: 13, weight: .semibold))
                    .contentShape(Rectangle())
                    .onTapGesture { store.showToday() }
                    .help("Back to today")
                Spacer()
                ArrowButton(symbol: "chevron.left") { store.shiftMonth(-1) }
                ArrowButton(symbol: "chevron.right") { store.shiftMonth(1) }
            }
            .padding(.horizontal, 4)

            // plain rows rather than a lazy grid, so the panel can measure itself
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        Text(weekdaySymbols[column])
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 16)
                    }
                }
                ForEach(0..<(grid.days.count / 7), id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(grid.days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                            DayCell(
                                day: day,
                                inMonth: calendar.isDate(day, equalTo: grid.monthStart, toGranularity: .month),
                                isToday: calendar.isDateInToday(day),
                                isSelected: calendar.isDate(day, inSameDayAs: store.selectedDay),
                                busy: store.busyDays.contains(calendar.startOfDay(for: day))
                            )
                            .onTapGesture { store.select(day) }
                        }
                    }
                }
            }
        }
    }

    /// Mon Tue … in the order your locale starts the week.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }
}

struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let busy: Bool

    var body: some View {
        let number = Calendar.current.component(.day, from: day)
        VStack(spacing: 1) {
            Text("\(number)")
                .font(.system(size: 12, weight: isToday ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.6)))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(isToday ? Color.accentColor : Color.primary.opacity(isSelected ? 0.12 : 0))
                )
            Circle()
                .fill(Color.secondary)
                .frame(width: 3.5, height: 3.5)
                .opacity(busy ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct ArrowButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

// MARK: events

struct EventsSection: View {
    @ObservedObject var store: CalendarStore

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(text: store.showingToday ? "Up Next" : Self.dayTitle.string(from: store.selectedDay))
            switch store.access {
            case .denied:
                HStack {
                    Text("Ledge can't see your calendars.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") { CalendarStore.openPrivacySettings() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
            case .unknown:
                EmptyLine(text: "Loading…")
            case .granted:
                if store.dayEvents.isEmpty {
                    EmptyLine(text: store.showingToday ? "Nothing else today" : "Nothing on this day")
                } else {
                    ForEach(store.dayEvents) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
    }
}

struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

struct EventRow: View {
    let event: CalendarStore.Event
    @EnvironmentObject var hover: HoverModel

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        let key = "event-" + event.id
        let hovering = hover.hovered == key
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: event.color))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                TimelineView(.everyMinute) { context in
                    Text(detail(now: context.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let link = event.link {
                Button("Join") {
                    Dropdown.shared.close()
                    NSWorkspace.shared.open(link)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hover.hovered = key
            } else if hover.hovered == key {
                hover.hovered = nil
            }
        }
        .onTapGesture {
            Dropdown.shared.close()
            CalendarStore.openCalendarApp()
        }
    }

    /// "14:00 – 15:00 · in 25 min", "Now · until 15:00", "All day", "Tomorrow 9:00 – 9:30"
    private func detail(now: Date) -> String {
        if event.allDay { return "All day" }
        let range = Self.time.string(from: event.start) + " – " + Self.time.string(from: event.end)
        if event.start <= now && event.end > now {
            return "Now · until " + Self.time.string(from: event.end)
        }
        let calendar = Calendar.current
        if calendar.isDateInTomorrow(event.start) && !calendar.isDateInTomorrow(now) {
            return "Tomorrow " + range
        }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes >= 0 && minutes < 60 && calendar.isDate(event.start, inSameDayAs: now) {
            return range + " · in \(max(minutes, 1)) min"
        }
        return range
    }
}

// MARK: now playing

struct NowPlayingRow: View {
    let bundleID: String
    let others: Int
    let action: () -> Void
    @EnvironmentObject var hover: HoverModel

    var body: some View {
        let hovering = hover.hovered == "now-playing"
        HStack(spacing: 9) {
            Image(nsImage: AppInfo.icon(for: bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Playing in " + AppInfo.name(for: bundleID))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if others > 0 {
                    Text("and \(others) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SpectrumGlyph(color: .secondaryLabelColor)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hover.hovered = "now-playing"
            } else if hover.hovered == "now-playing" {
                hover.hovered = nil
            }
        }
        .onTapGesture {
            Dropdown.shared.close()
            action()
        }
        .help("Go to it")
    }
}

// MARK: media

/// Track, artwork, timeline and the three buttons.
struct MediaCard: View {
    let track: NowPlayingStore.Track
    @ObservedObject var store: NowPlayingStore
    let openApp: () -> Void

    static let artworkSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 11) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let bundle = track.bundleID {
                    Image(nsImage: AppInfo.icon(for: bundle))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Dropdown.shared.close()
                            openApp()
                        }
                        .help("Go to " + AppInfo.name(for: bundle))
                }
            }

            if track.duration != nil {
                // ticks once a second while playing
                TimelineView(.periodic(from: .now, by: track.playing ? 1 : 3600)) { context in
                    Timeline(track: track, store: store, now: context.date)
                }
            }

            HStack(spacing: 30) {
                MediaButton(symbol: "backward.fill", size: 14) { store.previous() }
                MediaButton(symbol: track.playing ? "pause.fill" : "play.fill", size: 20) { store.togglePlayPause() }
                MediaButton(symbol: "forward.fill", size: 14) { store.next() }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let image = track.artwork {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipShape(shape)
        } else {
            ZStack {
                shape.fill(Color.primary.opacity(0.08))
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.artworkSize, height: Self.artworkSize)
        }
    }
}

/// Drag anywhere on the bar to jump; elapsed and remaining underneath.
struct Timeline: View {
    let track: NowPlayingStore.Track
    @ObservedObject var store: NowPlayingStore
    let now: Date

    static let width: CGFloat = IslandPanel.width - 16

    var body: some View {
        let duration = track.duration ?? 1
        let fraction = store.scrubbing ?? (track.position(at: now) / max(duration, 1))
        let shown = fraction * duration

        VStack(spacing: 3) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule()
                    .fill(Color.primary.opacity(store.scrubbing == nil ? 0.6 : 0.85))
                    .frame(width: max(4, Self.width * CGFloat(fraction)))
            }
            .frame(width: Self.width, height: store.scrubbing == nil ? 4 : 6)
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        store.scrubbing = min(max(Double(value.location.x / Self.width), 0), 1)
                    }
                    .onEnded { value in
                        let target = min(max(Double(value.location.x / Self.width), 0), 1)
                        store.seek(to: target)
                        store.scrubbing = nil
                    }
            )
            .animation(.easeOut(duration: 0.12), value: store.scrubbing == nil)

            HStack {
                Text(Self.format(shown))
                Spacer()
                Text("-" + Self.format(max(duration - shown, 0)))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct MediaButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @EnvironmentObject var hover: HoverModel

    var body: some View {
        let key = "media-" + symbol
        let hovering = hover.hovered == key
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .frame(width: 34, height: 30)
            .background(
                Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hover.hovered = key
                } else if hover.hovered == key {
                    hover.hovered = nil
                }
            }
            .onTapGesture(perform: action)
    }
}
