import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// How bright it is right behind the bar, per display, so the bar can go
/// light on light wallpapers and dark on dark ones (like the macOS menu bar).
///
/// Looks at the screen itself, minus Ledge's own windows: since Sonoma macOS
/// no longer says which picture is the wallpaper (it reports the default
/// one), and Aerials are videos anyway. Needs Screen Recording; without it
/// the bar follows the system.
///
/// Checks when you pick another wallpaper (macOS rewrites its wallpaper
/// store; Ledge only watches that the folder changed, it doesn't read it),
/// and on Space changes, wake, display changes and app switches, at most
/// every few seconds. Enough to follow an Aerial drifting from day to dusk,
/// without a timer.
final class WallpaperTone: ObservableObject {
    /// true = light behind the bar. Missing = couldn't tell (follow the system).
    @Published private(set) var light: [CGDirectDisplayID: Bool] = [:]

    /// only looks while Match Wallpaper is chosen
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { refresh(force: true) } else { light = [:] }
        }
    }

    static let minInterval: TimeInterval = 10
    /// light above this, dark below; in between it keeps what it had, so a
    /// mid-grey wallpaper doesn't flip back and forth
    static let lightAbove = 0.6
    static let darkBelow = 0.45

    private var lastCheck = Date.distantPast
    private var busy = false
    private var checkAgain = false
    private var storeWatch: DispatchSourceFileSystemObject?
    private var pendingStoreCheck: DispatchWorkItem?
    /// macOS cross-fades to a new wallpaper: look once it's done
    static let afterWallpaperChange: TimeInterval = 1.5

    private static var storeFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store")
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh(force: true)
        }
        watchStore()
        refresh(force: true)
    }

    /// The folder, not the file: macOS replaces Index.plist rather than
    /// editing it, which shows up as a write to the folder.
    private func watchStore() {
        let fd = open(Self.storeFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }  // no such folder: the other triggers still work
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.wallpaperChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        storeWatch = source
    }

    private func wallpaperChanged() {
        pendingStoreCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh(force: true)
            NotificationCenter.default.post(name: .ledgeWallpaperChanged, object: nil)
        }
        pendingStoreCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.afterWallpaperChange, execute: work)
    }

    func refresh(force: Bool = false) {
        guard enabled else { return }
        if busy {
            // a wallpaper change mid-check: look again right after
            if force { checkAgain = true }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            if !light.isEmpty { light = [:] }
            return
        }
        guard force || Date().timeIntervalSince(lastCheck) >= Self.minInterval else { return }
        lastCheck = Date()
        busy = true
        Task {
            let measured = await Self.measure()
            await MainActor.run {
                self.busy = false
                self.apply(measured)
                if self.checkAgain {
                    self.checkAgain = false
                    self.refresh(force: true)
                }
            }
        }
    }

    private func apply(_ luminance: [CGDirectDisplayID: Double]) {
        var next: [CGDirectDisplayID: Bool] = [:]
        for (display, value) in luminance {
            if value > Self.lightAbove {
                next[display] = true
            } else if value < Self.darkBelow {
                next[display] = false
            } else {
                next[display] = light[display] ?? (value >= 0.5)
            }
        }
        if light != next {
            let summary = luminance.map { String(format: "display %u: %.2f", $0.key, $0.value) }.joined(separator: ", ")
            NSLog("Ledge: behind the bar %@ -> %@", summary,
                  next.values.contains(false) ? "white text" : "dark text")
            light = next
        }
    }

    /// Average brightness (0...1) of the strip each bar covers.
    private static func measure() async -> [CGDirectDisplayID: Double] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return [:] }
        let ledge = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        var result: [CGDirectDisplayID: Double] = [:]
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: ledge, exceptingWindows: [])
            let config = SCStreamConfiguration()
            // display points, from the top left
            config.sourceRect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: BarMetrics.windowHeight)
            // same shape as the strip: a different one gets letterboxed, and
            // the empty rows read as black
            config.height = 4
            config.width = max(8, Int((CGFloat(display.width) / BarMetrics.windowHeight * 4).rounded()))
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                  let value = luminance(of: image)
            else { continue }
            result[display.displayID] = value
        }
        return result
    }

    private static func luminance(of image: CGImage) -> Double? {
        let width = 32, height = 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }

        // premultiplied, so weighting by alpha leaves out anything transparent
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var total = 0.0
        var covered = 0.0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            total += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
            covered += Double(pixels[i + 3])
        }
        guard covered > 0 else { return nil }
        return total / covered
    }
}
