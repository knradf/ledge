import AppKit
import Foundation

/// The system's Now Playing (track, artist, artwork, position) and its
/// controls, through `media-control` (brew install media-control).
///
/// Since macOS 15.4 Apple only lets its own apps read Now Playing.
/// media-control gets around that by having Apple's signed perl load a small
/// helper, which macOS still trusts. Works with TIDAL, Spotify, Music and
/// browsers, but a macOS update could break it; then the island simply falls
/// back to "Playing in …".
final class NowPlayingStore: ObservableObject {
    static let shared = NowPlayingStore()

    struct Track: Equatable {
        var bundleID: String?
        var title: String
        var artist: String
        var album: String
        var duration: Double?
        /// position at `anchor`
        var elapsed: Double
        var anchor: Date
        var rate: Double
        var playing: Bool
        var artwork: NSImage?

        /// position right now, moving on its own while playing
        func position(at date: Date) -> Double {
            let moved = playing ? date.timeIntervalSince(anchor) * rate : 0
            let value = elapsed + moved
            if let duration { return min(max(value, 0), duration) }
            return max(value, 0)
        }
    }

    @Published private(set) var track: Track?
    @Published private(set) var available = false
    /// 0...1 while you drag the timeline
    @Published var scrubbing: Double?

    /// found at launch, or after Settings installs it
    private var binary: String? = NowPlayingStore.findBinary()
    private let queue = DispatchQueue(label: "ledge.nowplaying")
    private var process: Process?
    private var buffer = Data()
    private var artworkKey: Int?
    private var artworkImage: NSImage?

    static func findBinary() -> String? {
        ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        guard !available else { return }
        if binary == nil { binary = Self.findBinary() }
        guard binary != nil else {
            NSLog("Ledge: media-control not found, no track info")
            watchForInstall()
            return
        }
        available = true
        queue.async { self.startStream() }
    }

    /// Installed later from Terminal: picked up the next time Ledge becomes
    /// active (e.g. opening its Settings), no restart needed.
    private var watchingForInstall = false
    private func watchForInstall() {
        guard !watchingForInstall else { return }
        watchingForInstall = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.start()
        }
    }

    /// Runs on `queue`. One more round of tries the next time the Mac wakes.
    private func retryAfterWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                if let observer = self.wakeObserver {
                    NSWorkspace.shared.notificationCenter.removeObserver(observer)
                    self.wakeObserver = nil
                }
                self.failures = 0
                self.startStream()
            }
        }
    }

    // MARK: controls

    func togglePlayPause() {
        if var track { track.elapsed = track.position(at: Date()); track.anchor = Date(); track.playing.toggle(); self.track = track }
        send(["toggle-play-pause"])
    }

    func next() { send(["next-track"]) }
    func previous() { send(["previous-track"]) }

    func seek(to fraction: Double) {
        guard var track, let duration = track.duration, duration > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * duration
        track.elapsed = seconds
        track.anchor = Date()
        self.track = track
        send(["seek", String(format: "%.2f", seconds)])
    }

    private func send(_ arguments: [String]) {
        guard let binary else { return }
        queue.async { _ = Shell.run(binary, arguments) }
    }

    // MARK: stream (runs on `queue`)

    /// One long-running `media-control stream`. Full updates (no diffs) and a
    /// short debounce, since some apps (TIDAL) send a track in pieces.
    /// quick deaths in a row; a stream that ran a while resets it
    private var failures = 0
    private var wakeObserver: Any?
    /// 5 s, 10 s, 20 s, 40 s, then it waits for the Mac to wake
    static let maxFailures = 5

    private func startStream() {
        guard let binary, process == nil else { return }
        let startedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["stream", "--no-diff", "--debounce=150"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                self.process = nil
                self.buffer.removeAll()
                DispatchQueue.main.async { self.track = nil }
                // ran for a while: it just ended (e.g. after sleep); otherwise
                // it's failing, maybe a macOS update broke it
                if Date().timeIntervalSince(startedAt) > 60 { self.failures = 0 }
                self.failures += 1
                guard self.failures < Self.maxFailures else {
                    NSLog("Ledge: media-control keeps quitting, trying again after the next wake")
                    self.retryAfterWake()
                    return
                }
                let delay = 5 * pow(2, Double(self.failures - 1))
                self.queue.asyncAfter(deadline: .now() + delay) { self.startStream() }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("Ledge: media-control didn't start: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if let type = object["type"] as? String, type != "data" { continue }
            let payload = (object["payload"] as? [String: Any]) ?? object
            let next = parse(payload)
            DispatchQueue.main.async {
                if self.track != next { self.track = next }
            }
        }
    }

    private func parse(_ payload: [String: Any]) -> Track? {
        let title = (payload["title"] as? String) ?? ""
        guard !title.isEmpty else { return nil }   // nothing playing

        var artwork: NSImage?
        if let base64 = payload["artworkData"] as? String, !base64.isEmpty {
            let key = base64.hashValue
            if key == artworkKey {
                artwork = artworkImage
            } else if let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                artworkKey = key
                artworkImage = image
                artwork = image
            }
        }

        return Track(
            bundleID: (payload["bundleIdentifier"] as? String) ?? (payload["parentApplicationBundleIdentifier"] as? String),
            title: title,
            artist: (payload["artist"] as? String) ?? "",
            album: (payload["album"] as? String) ?? "",
            duration: Self.number(payload["duration"]).flatMap { $0 > 0 ? $0 : nil },
            elapsed: Self.number(payload["elapsedTime"]) ?? 0,
            anchor: Self.date(payload["timestamp"]).flatMap { abs($0.timeIntervalSinceNow) < 86_400 ? $0 : nil } ?? Date(),
            rate: Self.number(payload["playbackRate"]).flatMap { $0 > 0 ? $0 : nil } ?? 1,
            playing: (payload["playing"] as? Bool) ?? false,
            artwork: artwork
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            return isoFractional.date(from: string) ?? iso.date(from: string)
        }
        if let seconds = number(value) {
            // seconds since 1970, or since 2001 for small values
            return seconds > 1_000_000_000 ? Date(timeIntervalSince1970: seconds) : Date(timeIntervalSinceReferenceDate: seconds)
        }
        return nil
    }
}
