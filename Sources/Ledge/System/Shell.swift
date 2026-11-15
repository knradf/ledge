import Foundation

enum Shell {
    /// Runs a binary and returns its stdout, or nil on failure / timeout.
    /// Blocking: call it off the main thread.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 2) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // read before waiting, so a full pipe can't deadlock us
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
