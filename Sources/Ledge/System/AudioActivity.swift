import AppKit
import Combine
import CoreAudio

/// Which apps are playing sound right now. Public CoreAudio (macOS 14.2+):
/// every process that talks to the audio system is an object that reports
/// whether it's currently outputting. Listeners only, no polling, and no
/// permission needed. It can't tell music from a video or a call, and it
/// knows nothing about the track: Apple keeps that private.
final class AudioActivity: ObservableObject {
    @Published private(set) var playing = false
    /// apps making sound, as bundle ids of the real app (not its helper)
    @Published private(set) var apps: [String] = []

    /// short sounds (alerts, a click in a video) shouldn't flash the bars
    static let showAfter: TimeInterval = 0.8
    /// gaps between tracks shouldn't make them blink off
    static let hideAfter: TimeInterval = 2.0

    // Ledge needs macOS 26+ (Package.swift), which has these
    private static let processListSelector = kAudioHardwarePropertyProcessObjectList
    private static let runningOutputSelector = kAudioProcessPropertyIsRunningOutput
    private static let pidSelector = kAudioProcessPropertyPID
    private static let bundleSelector = kAudioProcessPropertyBundleID

    /// Backup signal: the output device itself is busy. Only used if the
    /// per-app information turns out to be unavailable.
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceRunning = false
    private var deviceRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.readDeviceRunning()
    }
    private lazy var defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.bindDevice()
    }

    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: DispatchWorkItem?

    private var listAddress = AudioObjectPropertyAddress(
        mSelector: AudioActivity.processListSelector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var runningAddress = AudioObjectPropertyAddress(
        mSelector: AudioActivity.runningOutputSelector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private lazy var listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.reloadProcesses()
    }

    func start() {
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, DispatchQueue.main, listListener
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, DispatchQueue.main, defaultDeviceListener
        )
        bindDevice()
        reloadProcesses()
        // the app list in Settings → Rules
        let settings = LedgeSettings.shared
        Publishers.CombineLatest(settings.$soundFilterMode, settings.$soundFilterApps)
            .dropFirst()
            .sink { [weak self] _, _ in
                // @Published hands over the value before storing it
                DispatchQueue.main.async { self?.recompute() }
            }
            .store(in: &subscriptions)
        NSLog("Ledge: sound watcher started (listener status \(status)), \(watched.count) audio processes")
    }

    /// Follows the default output device.
    private func bindDevice() {
        if device != AudioObjectID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(device, &deviceRunningAddress, DispatchQueue.main, deviceListener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id)
        device = id
        if device != AudioObjectID(kAudioObjectUnknown) {
            AudioObjectAddPropertyListenerBlock(device, &deviceRunningAddress, DispatchQueue.main, deviceListener)
        }
        readDeviceRunning()
    }

    private func readDeviceRunning() {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let ok = device != AudioObjectID(kAudioObjectUnknown)
            && AudioObjectGetPropertyData(device, &deviceRunningAddress, 0, nil, &size, &value) == noErr
        let running = ok && value != 0
        if running != deviceRunning {
            deviceRunning = running
            NSLog("Ledge: sound output device " + (running ? "running" : "idle"))
        }
        // the device waking up is also the moment to look at who's playing,
        // in case a per-app notice got lost
        reloadProcesses()
    }

    /// Watch every audio process's "is outputting" flag.
    private func reloadProcesses() {
        let current = Set(processObjects())
        for (id, block) in watched where !current.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &runningAddress, DispatchQueue.main, block)
            watched[id] = nil
        }
        for id in current where watched[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.recompute() }
            AudioObjectAddPropertyListenerBlock(id, &runningAddress, DispatchQueue.main, block)
            watched[id] = block
        }
        recompute()
    }

    private func recompute() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [String] = []
        var report: [String] = []
        for id in watched.keys where isRunningOutput(id) {
            guard let pid = pid(of: id), pid != ownPID else { continue }
            let processBundle = bundleID(of: id)
            let app = Self.owningApp(pid: pid, processBundle: processBundle)
            report.append("\(pid) \(processBundle ?? "?") -> \(app?.bundleIdentifier ?? "no app")")
            guard let bundle = app?.bundleIdentifier, !found.contains(bundle),
                  LedgeSettings.shared.soundCounts(bundle)
            else { continue }
            found.append(bundle)
        }
        found.sort()
        report.sort()
        // which apps count as playing, and what each sound was put down to,
        // in the log. Only when the apps change: system helpers
        // (CoreSpeech and friends) come and go all the time.
        if apps != found {
            NSLog("Ledge: playing: %@ (sound from %@)",
                  found.isEmpty ? "nothing" : found.joined(separator: ", "),
                  report.isEmpty ? "nothing" : report.joined(separator: ", "))
            apps = found
        }

        // no per-app information at all (processes not visible): fall back to
        // "the speakers are busy"
        let now = !found.isEmpty || (watched.isEmpty && deviceRunning)
        pending?.cancel()
        guard now != playing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.playing != now { self.playing = now }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? Self.showAfter : Self.hideAfter), execute: work)
    }

    // MARK: CoreAudio

    private func processObjects() -> [AudioObjectID] {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private func isRunningOutput(_ id: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func pid(of id: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: Self.pidSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    /// The bundle id CoreAudio has for the process (set even for helpers
    /// that aren't apps of their own).
    private func bundleID(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioActivity.bundleSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue()
        else { return nil }
        let string = cf as String
        return string.isEmpty ? nil : string
    }

    // MARK: which app

    /// Browsers and Electron apps (TIDAL, Spotify) play sound from helper
    /// processes. Tried in order: the process itself, the process macOS
    /// holds responsible for it, its parents, and finally an app whose
    /// bundle id the helper's starts with.
    static func owningApp(pid: pid_t, processBundle: String?) -> NSRunningApplication? {
        var candidates = [pid]
        if let responsible = responsiblePID(pid), responsible != pid { candidates.append(responsible) }
        var parent = parentPID(pid)
        while let current = parent, current > 1, !candidates.contains(current), candidates.count < 8 {
            candidates.append(current)
            parent = parentPID(current)
        }
        for candidate in candidates {
            if let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy == .regular {
                return app
            }
        }
        let helperIDs = [processBundle, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier].compactMap { $0 }
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier?.lowercased() else { return false }
            return helperIDs.contains { $0.lowercased() == id || $0.lowercased().hasPrefix(id + ".") }
        }
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let result = fn(pid)
        return result > 0 ? result : nil
    }
}
