import AppKit
import ScreenCaptureKit

/// Live window previews (ScreenCaptureKit, needs Screen Recording). A
/// workspace is captured the moment you leave it, so the overview opens with
/// previews ready instead of waiting for them.
///
/// Kept short-lived: a preview is dropped as soon as its window closes, and
/// after a few minutes either way (the overview recaptures anything missing
/// when it opens). Memory stays at what the last few minutes needed.
final class PreviewStore: ObservableObject {
    static let shared = PreviewStore()

    @Published private(set) var images: [CGWindowID: NSImage] = [:]
    /// bumps on every new image, so the view can crossfade old -> new
    @Published private(set) var versions: [CGWindowID: Int] = [:]
    private var capturedAt: [CGWindowID: Date] = [:]

    /// how long a preview is kept
    static let lifetime: TimeInterval = 5 * 60

    /// Drops previews of windows that are gone, and old ones.
    func prune(keeping windows: Set<CGWindowID>, now: Date = Date()) {
        let stale = images.keys.filter { id in
            !windows.contains(id) || now.timeIntervalSince(capturedAt[id] ?? .distantPast) > Self.lifetime
        }
        guard !stale.isEmpty else { return }
        for id in stale {
            images[id] = nil
            versions[id] = nil
            capturedAt[id] = nil
        }
    }

    /// Captures these windows in parallel. `scale` is pixels per point.
    func capture(_ ids: [CGWindowID], scale: CGFloat) async {
        guard WindowFocus.canCapture, !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return }
        let wanted = Set(ids)
        let windows = content.windows.filter { wanted.contains($0.windowID) }

        await withTaskGroup(of: Void.self) { group in
            for window in windows {
                group.addTask {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(window.frame.width * scale))
                    config.height = max(1, Int(window.frame.height * scale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    // one window refusing to be captured doesn't stop the rest
                    guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    else { return }
                    let image = NSImage(cgImage: cgImage, size: window.frame.size)
                    let id = window.windowID
                    await MainActor.run {
                        self.images[id] = image
                        self.versions[id, default: 0] += 1
                        self.capturedAt[id] = Date()
                    }
                }
            }
        }
    }
}
