import AppKit
import SwiftUI

/// The whole stack of workspaces, seen through one camera: a scale around the
/// screen's center plus a vertical offset to the focused row. It fades in while
/// settling from slightly closer, and leans back in while fading out.
struct OverviewView: View {
    @ObservedObject var model: OverviewModel

    /// world coordinates (before the camera), for dragging
    static let space = NamedCoordinateSpace.named("overview.world")

    /// the world being drawn: what a drop would leave, while dragging
    private var shown: OverviewWorld { model.preview ?? model.world }

    /// the dragged window's slot in the preview, in world points
    private var ghostFrame: CGRect? {
        guard let drag = model.drag, let preview = model.preview,
              let placed = preview.placedCards.first(where: { $0.id == drag.id })
        else { return nil }
        return placed.frame.offsetBy(dx: 0, dy: preview.rowTop(CGFloat(placed.row)))
    }

    var body: some View {
        let world = model.world
        let width = world.screen.width
        let height = world.screen.height
        let p = model.progress
        let scale = Theme.overviewScale * (1 + (Theme.overviewEnterScale - 1) * (1 - p))
        let focusY = world.rowTop(model.focusRow) + height / 2

        ZStack(alignment: .topLeading) {
            // the real screen, blurred and dimmed, behind the stack
            ZStack {
                GlassBackground(cornerRadius: 0, material: .fullScreenUI)
                Color.black.opacity(0.25)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture { OverviewController.shared.cancel() }

            ZStack(alignment: .topLeading) {
                // every desktop first, every window after: a desktop can never
                // cover a window, whichever row it belongs to
                ForEach(Array(world.rows.enumerated()), id: \.element.id) { index, row in
                    RowDesktopView(row: row, index: index, screen: world.screen, model: model)
                        .offset(y: world.rowTop(CGFloat(index)))
                }
                // where a dragged window will land
                if let ghost = ghostFrame {
                    DropGhost(size: ghost.size)
                        .offset(x: ghost.minX, y: ghost.minY)
                        .transition(.opacity)
                }
                // one layer for all windows, so a window moved to another
                // workspace (or along its strip) slides there instead of popping.
                // While dragging, the others are drawn where they'd be after the
                // drop, so they make room for it.
                ForEach(shown.placedCards) { placed in
                    // one view either way, so on drop it glides from the pointer
                    // into its slot
                    let dragged = model.drag?.id == placed.id ? model.drag : nil
                    let frame = dragged.map { $0.origin.offsetBy(dx: $0.offset.width, dy: $0.offset.height) }
                        ?? placed.frame.offsetBy(dx: 0, dy: shown.rowTop(CGFloat(placed.row)))
                    WorldCardView(placed: placed, size: frame.size, model: model)
                        .scaleEffect(dragged == nil ? 1 : 1.03)
                        .offset(x: frame.minX, y: frame.minY)
                        .zIndex(dragged == nil ? 0 : 1)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .coordinateSpace(OverviewView.space)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: width / 2 - width / 2 * scale, y: height / 2 - focusY * scale)

            PermissionHint()
                .frame(width: width, height: height, alignment: .bottom)
                .padding(.bottom, 28)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .opacity(p)
    }
}

/// A workspace's desktop: its wallpaper, number and the outline when centered.
struct RowDesktopView: View {
    let row: WorldRow
    let index: Int
    let screen: CGSize
    @ObservedObject var model: OverviewModel

    var body: some View {
        let zoom = Theme.overviewScale
        let dragging = model.drag != nil
        let dropTarget = dragging && model.preview != nil
            && model.drag?.target == index && model.drag?.fromRow != index
        let centered = !dragging && Int(model.focusRow.rounded()) == index
        let shape = RoundedRectangle(cornerRadius: Theme.overviewDesktopCorner, style: .continuous)

        ZStack(alignment: .topLeading) {
            desktop
                .frame(width: screen.width, height: screen.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(centered ? 0.55 : 0), lineWidth: 3 / zoom))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(dropTarget ? 1 : 0), lineWidth: 6 / zoom))
                .overlay(shape.fill(Color.accentColor.opacity(dropTarget ? 0.12 : 0)))
                .contentShape(shape)
                .onTapGesture { OverviewController.shared.choose(rowIndex: index) }

            Text("\(row.number)")
                .font(.system(size: 22 / zoom, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.4), radius: 4 / zoom)
                .padding(18 / zoom)
                .allowsHitTesting(false)
        }
        .animation(Theme.overviewPan, value: centered)
        .animation(.easeOut(duration: 0.15), value: dropTarget)
    }

    @ViewBuilder
    private var desktop: some View {
        if let wallpaper = model.wallpaper {
            Image(nsImage: wallpaper)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            Color.black.opacity(0.35)
        }
    }
}

/// Dashed outline where the dragged window will go.
struct DropGhost: View {
    let size: CGSize

    var body: some View {
        let zoom = Theme.overviewScale
        let shape = RoundedRectangle(cornerRadius: Theme.windowCorner, style: .continuous)
        ZStack {
            shape.fill(Color.accentColor.opacity(0.18))
            shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 4 / zoom, dash: [16 / zoom, 10 / zoom]))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

struct WorldCardView: View {
    let placed: PlacedCard
    let size: CGSize
    @ObservedObject var model: OverviewModel

    private var card: WorldCard { placed.card }
    private var rowIndex: Int { placed.row }
    @EnvironmentObject var previews: PreviewStore

    private var icon: NSImage {
        IconCache.shared.icon(for: WorkspaceApp(
            id: card.window.bundleID ?? card.window.appName,
            bundleID: card.window.bundleID,
            name: card.window.appName,
            count: 1,
            focused: false
        ))
    }

    var body: some View {
        let zoom = Theme.overviewScale
        let hovering = model.hovered == card.id || model.drag?.id == card.id
        let shape = RoundedRectangle(cornerRadius: Theme.windowCorner, style: .continuous)

        ZStack(alignment: .bottomLeading) {
            preview
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34 / zoom, height: 34 / zoom)
                .shadow(color: .black.opacity(0.35), radius: 3 / zoom, y: 1 / zoom)
                .padding(10 / zoom)
        }
        .overlay(shape.strokeBorder(Color.accentColor.opacity(card.window.focused ? 1 : 0), lineWidth: 4 / zoom))
        .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.85 : 0), lineWidth: 4 / zoom))
        .shadow(color: .black.opacity(model.drag?.id == card.id ? 0.5 : 0.35),
                radius: model.drag?.id == card.id ? 40 : 20, y: model.drag?.id == card.id ? 16 : 8)
        .contentShape(shape)
        .onHover { inside in
            if inside {
                model.hovered = card.id
            } else if model.hovered == card.id {
                model.hovered = nil
            }
        }
        .onTapGesture { OverviewController.shared.choose(card.window, rowIndex: rowIndex) }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: OverviewView.space)
                .onChanged { value in
                    OverviewController.shared.dragChanged(
                        placed, translation: value.translation, location: value.location
                    )
                }
                .onEnded { _ in
                    OverviewController.shared.dragEnded(placed)
                }
        )
        .help(card.window.title.isEmpty ? card.window.appName : card.window.title)
    }

    /// Icon placeholder underneath; each new preview crossfades over the last.
    private var preview: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .opacity(0.85)
            if let image = previews.images[card.id] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .id(previews.versions[card.id] ?? 0)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: previews.versions[card.id] ?? 0)
    }
}

/// Shown at the bottom while a permission is missing.
struct PermissionHint: View {
    var body: some View {
        let missingCapture = !WindowFocus.canCapture
        let missingAccess = !WindowFocus.trusted
        if missingCapture || missingAccess {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                Text(message(capture: missingCapture, access: missingAccess))
                    .font(.system(size: 12))
                if missingCapture {
                    Button("Allow Previews…") { Permissions.shared.askScreenRecording() }
                }
                if missingAccess {
                    Button("Allow Window Focus…") { Permissions.shared.askAccessibility() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(GlassBackground(cornerRadius: 14, material: .hudWindow))
        }
    }

    private func message(capture: Bool, access: Bool) -> String {
        if capture && access { return "Previews need Screen Recording, focusing a window needs Accessibility." }
        if capture { return "Live previews need Screen Recording." }
        return "Focusing a specific window needs Accessibility."
    }
}
