import AppKit
import SwiftUI

/// The island. Looks like the clock it always was; while something plays,
/// a small pill with a moving spectrum appears to its left. Centered, it
/// floats there without moving the clock off center; on the right it takes
/// its place in the row. Click either: the island panel (now playing,
/// calendar, what's next, settings). Right-click the clock: Calendar.
/// Like the status items, the clock is highlighted while pressed and while
/// its island is open.
struct ClockView: View {
    @EnvironmentObject var settings: LedgeSettings
    @EnvironmentObject var audio: AudioActivity
    @EnvironmentObject var paneru: PaneruStore
    @ObservedObject private var dropdown = Dropdown.shared
    @ObservedObject private var highlight = StatusHighlight.shared

    static let islandID = "island"
    /// the clock pill's inner padding before it had a highlight (pill 10 + text 4)
    static let textInset: CGFloat = 14

    private var highlighted: Bool {
        dropdown.openID == Self.islandID || highlight.id == "clock"
    }

    var body: some View {
        Group {
            if settings.clockPosition == .right {
                HStack(spacing: settings.pillGap) {
                    if audio.playing {
                        playingPill
                            .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
                    }
                    clock
                }
            } else {
                // drawn outside the clock's own frame, so the clock stays centered
                clock.overlay(alignment: .leading) {
                    if audio.playing {
                        playingPill
                            // a fixed width, so it can sit exactly one gap left of the clock
                            .offset(x: -(Theme.playingPillWidth + settings.pillGap))
                            .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(Theme.animation, value: audio.playing)
    }

    private var clock: some View {
        Group {
            if settings.clockShowSeconds {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label(context.date)
                }
            } else {
                // redraws exactly when the minute changes
                TimelineView(.everyMinute) { context in
                    label(context.date)
                }
            }
        }
        .overlay(
            MouseCatcher(
                onLeft: { openIsland() },
                onRight: { CalendarStore.openCalendarApp() },
                onPress: { pressed in
                    if pressed {
                        highlight.id = "clock"
                    } else if highlight.id == "clock" {
                        highlight.id = nil
                    }
                }
            )
        )
    }

    private var playingPill: some View {
        Pill {
            SpectrumGlyph(color: NSColor.labelColor.withAlphaComponent(0.85))
                .frame(width: Theme.playingGlyphWidth)
        }
        .contentShape(Capsule())
        .onTapGesture { openIsland() }
        .help("Playing")
    }

    private func label(_ date: Date) -> some View {
        // same size as before: the highlight sits where the padding was
        Pill(padding: StatusMetrics.pillPadding) {
            Text(ClockFormat.string(from: date, settings: settings))
                .font(Theme.menuFont.monospacedDigit())
                .padding(.horizontal, Self.textInset - StatusMetrics.pillPadding)
                .frame(height: StatusMetrics.highlightHeight)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(highlighted ? StatusMetrics.highlightOpacity : 0))
                )
        }
    }

    private func openIsland() {
        let calendar = CalendarStore.shared
        calendar.showToday()
        calendar.prepare()
        let audio = self.audio
        let paneru = self.paneru
        // centered: under the middle of the screen; on the right: under the click
        Dropdown.shared.toggle(id: Self.islandID, centered: settings.clockPosition == .center) {
            IslandPanel(
                calendar: calendar,
                audio: audio,
                nowPlaying: NowPlayingStore.shared,
                paneru: paneru
            )
        }
    }
}

enum ClockFormat {
    private static var formatters: [String: DateFormatter] = [:]

    static func string(from date: Date, settings: LedgeSettings) -> String {
        var time = settings.clock24h ? "HH:mm" : "h:mm"
        if settings.clockShowSeconds { time += ":ss" }
        if !settings.clock24h { time += " a" }
        let pattern = settings.clockShowDate ? "EEE d MMM   " + time : time
        return formatter(pattern).string(from: date)
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        if let cached = formatters[pattern] { return cached }
        let f = DateFormatter()
        f.dateFormat = pattern
        formatters[pattern] = f
        return f
    }
}
