import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspacesView: View {
    @EnvironmentObject var paneru: PaneruStore
    @EnvironmentObject var settings: LedgeSettings

    init() {}

    private var shown: [Workspace] {
        if paneru.appsOnly { return paneru.workspaces }
        return settings.showEmptyWorkspaces ? paneru.workspaces.withEmpty() : paneru.workspaces
    }

    /// Paneru is stuck but we know what the workspaces looked like: keep
    /// them, dimmed, behind a small warning instead of a blank bar
    private var stale: Bool { paneru.notAnswering && !shown.isEmpty }

    var body: some View {
        HStack(spacing: settings.pillGap) {
            if paneru.notAnswering {
                PaneruProblemPill(paneru: paneru, compact: stale)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            ForEach(shown) { workspace in
                WorkspacePill(workspace: workspace)
                    .opacity(stale ? 0.4 : 1)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(Theme.animation, value: stale)
        // Minimal style: one highlight that slides to the active workspace
        // (the other styles fade each pill's own highlight in and out)
        .backgroundPreferenceValue(WorkspaceBoundsKey.self) { anchors in
            if settings.barStyle == .none {
                GeometryReader { proxy in
                    if let active = shown.first(where: { $0.active }), let anchor = anchors[active.number] {
                        SlidingHighlight(rect: proxy[anchor], dot: WorkspacePill.isDot(active, settings: settings))
                    }
                }
            }
        }
        .animation(Theme.animation, value: shown)
        .animation(Theme.animation, value: settings.showEmptyWorkspaces)
        .animation(Theme.animation, value: settings.showNumbers)
        .animation(Theme.animation, value: settings.showApps)
        .animation(Theme.animation, value: settings.appStyle)
    }
}

/// Shown instead of empty workspaces when Paneru isn't there or is stuck,
/// so a broken Paneru doesn't look like a broken bar.
struct PaneruProblemPill: View {
    @ObservedObject var paneru: PaneruStore
    /// just the icon, next to the last known (dimmed) workspaces
    var compact = false

    var body: some View {
        Pill {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                if !compact {
                    Text(paneru.binaryFound ? "Paneru isn't answering" : "Paneru not found")
                        .font(Theme.menuFont)
                }
            }
            .foregroundStyle(Color.primary.opacity(0.85))
        }
        .contentShape(Capsule())
        .onTapGesture {
            Dropdown.shared.toggle(id: "paneru-problem") { PaneruProblemMenu(paneru: paneru) }
        }
    }
}

struct PaneruProblemMenu: View {
    @ObservedObject var paneru: PaneruStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(text: paneru.binaryFound ? "Paneru isn't answering" : "Paneru isn't installed")
            Text(paneru.binaryFound
                 ? "It's running but can't list your windows. This usually follows a game or app in macOS full screen: quit it or leave full screen, then restart Paneru. If that doesn't help, log out and back in."
                 : "Ledge shows Paneru's workspaces. Get it from github.com/karinushka/paneru")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            if paneru.binaryFound {
                Divider().padding(.vertical, 3)
                MenuRow(title: "Restart Paneru") { paneru.restartPaneru() }
                MenuRow(title: "Open Paneru's Log") {
                    let log = "/tmp/com.github.karinushka.paneru_\(getuid()).err.log"
                    NSWorkspace.shared.open(URL(fileURLWithPath: log))
                }
            }
        }
        .frame(width: 300, alignment: .leading)
    }
}

/// Where each workspace pill sits, so the Minimal highlight can slide to it.
struct WorkspaceBoundsKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The Minimal style's highlight: a bright dot over a workspace shown as a
/// dot, a soft capsule behind one showing its apps or number. It morphs
/// between the two while it slides.
struct SlidingHighlight: View {
    let rect: CGRect
    let dot: Bool

    var body: some View {
        let size = dot ? CGSize(width: Theme.bareDotSize, height: Theme.bareDotSize) : rect.size
        RoundedRectangle(cornerRadius: min(size.width, size.height) / 2, style: .continuous)
            .fill(Color.primary.opacity(dot ? AppMark.focusedOpacity : Theme.activeHighlight))
            .frame(width: size.width, height: size.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(Theme.highlightSlide, value: rect)
            .animation(Theme.highlightSlide, value: dot)
    }
}

/// One workspace. With numbers and apps off it's a plain pill; the active
/// one is wider. Numbers and apps are added inside when turned on.
struct WorkspacePill: View {
    let workspace: Workspace
    @EnvironmentObject var paneru: PaneruStore
    @EnvironmentObject var settings: LedgeSettings

    private var showsApps: Bool { settings.showApps && !workspace.apps.isEmpty }
    private var isSimple: Bool { !settings.showNumbers && !showsApps }
    private var noBackground: Bool { settings.barStyle == .none }

    private var simpleWidth: CGFloat? {
        guard isSimple else { return nil }
        return workspace.active ? Theme.simplePillActiveWidth : Theme.simplePillWidth
    }

    /// Minimal style, nothing to show inside: drawn as a dot.
    static func isDot(_ workspace: Workspace, settings: LedgeSettings) -> Bool {
        settings.barStyle == .none && !settings.showNumbers && !(settings.showApps && !workspace.apps.isEmpty)
    }

    var body: some View {
        pill
            .anchorPreference(key: WorkspaceBoundsKey.self, value: .bounds) { [workspace.number: $0] }
    }

    @ViewBuilder
    private var pill: some View {
        if isSimple && noBackground {
            // no background to show a pill on: a dot, as quiet as the glyphs
            // of inactive workspaces; the bright one slides over it
            Circle()
                .fill(Color.primary.opacity(AppMark.inactiveOpacity))
                .frame(width: Theme.bareDotSize, height: Theme.bareDotSize)
                .padding(.horizontal, 4)
                .frame(height: BarMetrics.pillHeight)
                .contentShape(Rectangle())
                .onTapGesture { paneru.go(to: workspace.number) }
        } else {
            content
                .padding(.horizontal, isSimple ? 0 : 10)
                .frame(width: simpleWidth, height: BarMetrics.pillHeight)
                .background {
                    ZStack {
                        SurfaceBackground(emphasized: workspace.active)
                        // each pill has its own highlight that fades in and out,
                        // so it never travels outside the pill
                        Capsule()
                            .fill(Color.primary.opacity(Theme.activeHighlight))
                            .opacity(workspace.active && !noBackground ? 1 : 0)
                            .animation(Theme.highlightFade, value: workspace.active)
                    }
                }
                .contentShape(Capsule())
                .onTapGesture { paneru.go(to: workspace.number) }
        }
    }

    private var content: some View {
        HStack(spacing: 7) {
            if settings.showNumbers && !paneru.appsOnly {
                Text("\(workspace.number)")
                    .font(Theme.menuFont.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(workspace.active ? 1 : 0.5))
            }
            if showsApps {
                // Each glyph owns the pill's full height and half of each gap,
                // so a click near a glyph opens that app instead of falling
                // through to the pill (which only switches workspace).
                HStack(spacing: 0) {
                    ForEach(workspace.apps) { app in
                        AppMark(app: app, workspaceActive: workspace.active)
                            .padding(.horizontal, 3)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { paneru.focus(app, in: workspace.number) }
                            .contextMenu { windowMenu(for: app) }
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, -3)
            }
        }
    }
}

extension WorkspacePill {
    /// Right-click on a glyph: that app's windows in this workspace by title.
    @ViewBuilder
    func windowMenu(for app: WorkspaceApp) -> some View {
        let windows = paneru.windows(of: app, in: workspace.number)
        ForEach(windows) { window in
            Toggle(window.title.isEmpty ? app.name : window.title, isOn: Binding(
                get: { window.focused },
                set: { _ in paneru.focusWindow(window, in: workspace.number) }
            ))
        }
    }
}

/// An app inside a workspace: a glyph from sketchybar-app-font, or the real icon.
struct AppMark: View {
    let app: WorkspaceApp
    let workspaceActive: Bool
    @EnvironmentObject var settings: LedgeSettings

    static let focusedOpacity: Double = 1
    static let activeOpacity: Double = 0.65
    static let inactiveOpacity: Double = 0.4

    private var opacity: Double {
        workspaceActive ? (app.focused ? Self.focusedOpacity : Self.activeOpacity) : Self.inactiveOpacity
    }

    private var showCount: Bool { settings.showWindowCount && app.count > 1 }

    var body: some View {
        Group {
            if settings.appStyle == .glyphs, GlyphMap.shared.available {
                Text(GlyphMap.shared.glyph(for: app.name))
                    .font(.custom(GlyphMap.fontName, size: Theme.glyphFontSize))
                    .foregroundStyle(Color.primary.opacity(opacity))
                    .padding(.trailing, -Theme.glyphTrim)
                    .offset(x: Theme.glyphNudge)
            } else {
                Image(nsImage: IconCache.shared.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Theme.iconSize, height: Theme.iconSize)
                    .opacity(opacity)
                    .saturation(workspaceActive ? 1 : 0.4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showCount {
                Text("\(app.count)")
                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 11, minHeight: 11)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .offset(x: 5, y: 4)
            }
        }
        .help(app.name)
    }
}

/// Real app icons, looked up once per app.
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for app: WorkspaceApp) -> NSImage {
        if let cached = cache[app.id] { return cached }

        var image: NSImage?
        if let bundle = app.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == app.name }) {
            image = running.icon
        }
        let result = image ?? NSWorkspace.shared.icon(for: .application)
        cache[app.id] = result
        return result
    }
}
