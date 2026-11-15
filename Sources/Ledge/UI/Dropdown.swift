import AppKit
import SwiftUI

/// Small glass menu that drops down from the bar under the mouse.
/// Closes on any click outside it, or when an item is picked.
final class Dropdown: ObservableObject {
    static let shared = Dropdown()

    private var panel: FloatingPanel?
    private var host: FirstClickHostingView?
    private var centered = false
    private var refitPending = false
    /// which menu is open, so what opened it can stay highlighted
    @Published private(set) var openID: String?
    private var monitors: [Any] = []
    private var lastClosed: (id: String, time: TimeInterval)?

    /// `centered`: under the middle of the screen (the clock), instead of
    /// under the mouse.
    func toggle<Content: View>(id: String, centered: Bool = false, @ViewBuilder content: () -> Content) {
        if openID == id {
            close()
            return
        }
        // the outside-click monitor already closed it a moment ago: this click
        // was meant as "close", don't reopen
        if let lastClosed, lastClosed.id == id,
           ProcessInfo.processInfo.systemUptime - lastClosed.time < 0.4 {
            return
        }
        close()

        let hover = HoverModel()
        let host = FirstClickHostingView(rootView: AnyView(
            DropdownChrome { content() }.environmentObject(hover)
        ))
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }

        let frame = screen.frame
        let anchor = centered ? frame.midX : mouse.x
        let x = min(max(anchor - size.width / 2, frame.minX + 6), frame.maxX - size.width - 6)
        let top = frame.maxY - BarMetrics.windowHeight + 2
        let rect = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)

        let panel = FloatingPanel(
            contentRect: rect,
            level: NSWindow.Level(rawValue: BarMetrics.level.rawValue + 1),
            shadow: true
        )
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        self.host = host
        self.centered = centered
        openID = id
        installMonitors()
    }

    /// Content that loads after opening (calendar, now playing) changes the
    /// size: grow or shrink downward, keeping the top edge where it is.
    func refitSoon() {
        guard panel != nil, !refitPending else { return }
        refitPending = true
        DispatchQueue.main.async {
            self.refitPending = false
            self.refit()
        }
    }

    private func refit() {
        guard let panel, let host, let screen = panel.screen ?? NSScreen.main else { return }
        let size = host.fittingSize
        let old = panel.frame
        guard abs(size.width - old.width) > 0.5 || abs(size.height - old.height) > 0.5 else { return }
        let frame = screen.frame
        let anchor = centered ? frame.midX : old.midX
        let x = min(max(anchor - size.width / 2, frame.minX + 6), frame.maxX - size.width - 6)
        let rect = NSRect(x: x, y: old.maxY - size.height, width: size.width, height: size.height)
        host.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(rect, display: true)
    }

    func close() {
        guard let panel else { return }
        if let openID {
            lastClosed = (openID, ProcessInfo.processInfo.systemUptime)
        }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        self.panel = nil
        self.host = nil
        openID = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // clicks in other apps
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.close()
        }) {
            monitors.append(global)
        }
        // clicks elsewhere in our own bar
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if event.window !== self?.panel { self?.close() }
            return event
        }) {
            monitors.append(local)
        }
    }
}

struct DropdownChrome<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(6)
            // menus need a background even when the bar has none
            .background(
                LedgeSettings.shared.barStyle == .glass
                    ? Surface.liquidGlass(cornerRadius: 12)
                    : AnyView(GlassBackground(cornerRadius: 12, material: Theme.dropdownMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(Theme.stroke), lineWidth: 0.5)
                    .opacity(LedgeSettings.shared.barStyle == .glass ? 0 : 1)
            )
            .font(.system(size: 13))
    }
}

/// Which menu row the mouse is over. A plain observable object instead of
/// @State: in the macOS 27 SDK @State is a macro whose plugin only ships
/// with full Xcode, not the command line tools.
final class HoverModel: ObservableObject {
    @Published var hovered: String?
}

struct MenuRow: View {
    let title: String
    let checked: Bool
    let action: () -> Void
    @EnvironmentObject var hover: HoverModel

    init(title: String, checked: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.checked = checked
        self.action = action
    }

    var body: some View {
        let hovering = hover.hovered == title
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .opacity(checked ? 1 : 0)
                .frame(width: 10)
            Text(title)
                .lineLimit(1)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering ? 0.85 : 0))
            )
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hover.hovered = title
                } else if hover.hovered == title {
                    hover.hovered = nil
                }
            }
            .onTapGesture {
                action()
                Dropdown.shared.close()
            }
    }
}
