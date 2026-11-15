import AppKit
import SwiftUI

/// Frosted: real macOS blur (the material menus use), not a translucent color.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var material: NSVisualEffectView.Material = Theme.pillMaterial

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.maskImage = GlassBackground.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.maskImage = GlassBackground.mask(radius: cornerRadius)
    }

    /// A stretchable rounded-rect mask; the documented way to round an
    /// NSVisualEffectView that blurs what's behind the window.
    static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

enum Surface {
    /// Liquid Glass on macOS 26+, frosted blur before that.
    static func liquidGlass(cornerRadius: CGFloat) -> AnyView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return AnyView(
                Color.clear.glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            )
        }
        #endif
        return AnyView(GlassBackground(cornerRadius: cornerRadius))
    }

    static func background(_ style: BarStyle, cornerRadius: CGFloat) -> AnyView {
        switch style {
        case .glass: return liquidGlass(cornerRadius: cornerRadius)
        case .frosted: return AnyView(GlassBackground(cornerRadius: cornerRadius))
        case .none: return AnyView(Color.clear)
        }
    }

    /// Hairline edge: only the frosted style needs one (Liquid Glass draws its own).
    static func hasStroke(_ style: BarStyle) -> Bool { style == .frosted }
}

/// Background for every group in the bar, in the chosen style.
struct SurfaceBackground: View {
    @EnvironmentObject var settings: LedgeSettings
    var cornerRadius: CGFloat = BarMetrics.pillHeight / 2
    var emphasized = false

    var body: some View {
        Surface.background(settings.barStyle, cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(emphasized ? Theme.strokeActive : Theme.stroke),
                        lineWidth: 0.5
                    )
                    .opacity(Surface.hasStroke(settings.barStyle) ? 1 : 0)
            )
    }
}

/// Capsule used for the clock and status groups.
struct Pill<Content: View>: View {
    let content: Content
    var padding: CGFloat

    init(padding: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, padding)
            .frame(height: BarMetrics.pillHeight)
            .background(SurfaceBackground())
    }
}
