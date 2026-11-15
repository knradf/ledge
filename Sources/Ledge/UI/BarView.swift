import SwiftUI

/// The whole bar: workspaces left, status right, the clock centered or
/// after the status items.
/// Light/dark comes from the window's appearance (set in AppDelegate).
struct BarView: View {
    let displayID: CGDirectDisplayID
    @EnvironmentObject var settings: LedgeSettings

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                WorkspacesView()
                Spacer(minLength: 12)
                StatusView()
                if settings.clockPosition == .right {
                    ClockView()
                        .padding(.leading, settings.pillGap)
                        .transition(.opacity)
                }
            }
            if settings.clockPosition == .center {
                ClockView()
                    .transition(.opacity)
            }
        }
        .frame(height: BarMetrics.pillHeight)
        .padding(.horizontal, settings.edgeMargin)
        .padding(.top, settings.topOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(BareLegibility(active: settings.barStyle == .none))
        .animation(Theme.animation, value: settings.edgeMargin)
        .animation(Theme.animation, value: settings.topOffset)
        .animation(Theme.animation, value: settings.barStyle)
        .animation(Theme.animation, value: settings.clockPosition)
    }
}

/// Only for the Minimal style: a faint shadow so text stays readable on busy
/// wallpapers (a light halo behind dark text, a dark one behind white text).
struct BareLegibility: ViewModifier {
    let active: Bool
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.shadow(color: (scheme == .light ? Color.white : Color.black).opacity(0.3), radius: 1.5)
        } else {
            content
        }
    }
}
