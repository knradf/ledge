import AppKit
import Foundation

/// Installs media-control with Homebrew from Settings, so nobody has to open
/// Terminal. Without Homebrew (or if it fails) Settings shows the command to
/// copy instead.
final class MediaControlInstaller: ObservableObject {
    static let shared = MediaControlInstaller()

    enum State: Equatable {
        case idle
        case installing
        /// what brew said, last few lines
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    static let command = "brew install media-control"

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func install() {
        guard state != .installing, let brew = Self.brew else { return }
        state = .installing
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(brew)
            DispatchQueue.main.async {
                if NowPlayingStore.findBinary() != nil {
                    self.state = .idle
                    NowPlayingStore.shared.start()
                } else {
                    self.state = .failed(result ?? "Homebrew didn't finish.")
                    NSLog("Ledge: brew install media-control failed: %@", result ?? "no output")
                }
            }
        }
    }

    static func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Runs brew and returns the tail of its output when it fails.
    private static func run(_ brew: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "media-control"]
        var env = ProcessInfo.processInfo.environment
        // a GUI app's PATH doesn't include Homebrew's own folder
        env["PATH"] = "\((brew as NSString).deletingLastPathComponent):/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        // brew can take a while (it may update itself first): give it 10 minutes
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus != 0 else { return nil }
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .suffix(3)
        return lines.joined(separator: "\n")
    }
}
