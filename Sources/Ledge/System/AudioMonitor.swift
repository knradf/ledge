import AudioToolbox
import CoreAudio
import Foundation

/// Volume and mute of the default output device, via CoreAudio property
/// listeners (no polling). Follows the default device when it changes.
final class AudioMonitor: ObservableObject {
    /// 0...1, nil when the device has no software volume (e.g. some DACs)
    @Published private(set) var volume: Float?
    @Published private(set) var muted = false

    struct Output: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
    }
    @Published private(set) var outputs: [Output] = []
    @Published private(set) var currentOutput: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    private var device = AudioObjectID(kAudioObjectUnknown)

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private lazy var changeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.update()
    }
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.bindDefaultDevice()
    }
    private lazy var deviceListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.loadOutputs()
    }

    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, DispatchQueue.main, deviceListener
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, DispatchQueue.main, deviceListListener
        )
        bindDefaultDevice()
        loadOutputs()
    }

    private func bindDefaultDevice() {
        if device != AudioObjectID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, DispatchQueue.main, changeListener)
            AudioObjectRemovePropertyListenerBlock(device, &muteAddress, DispatchQueue.main, changeListener)
        }

        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id
        )
        device = id
        if currentOutput != id { currentOutput = id }

        if device != AudioObjectID(kAudioObjectUnknown) {
            AudioObjectAddPropertyListenerBlock(device, &volumeAddress, DispatchQueue.main, changeListener)
            AudioObjectAddPropertyListenerBlock(device, &muteAddress, DispatchQueue.main, changeListener)
        }
        update()
    }

    func update() {
        var newVolume: Float?
        if AudioObjectHasProperty(device, &volumeAddress) == true {
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == 0 {
                newVolume = value
            }
        }

        var newMuted = false
        if AudioObjectHasProperty(device, &muteAddress) == true {
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == 0 {
                newMuted = value != 0
            }
        }

        if volume != newVolume { volume = newVolume }
        if muted != newMuted { muted = newMuted }
    }

    // MARK: output devices

    /// Every device that can play sound (has output streams).
    func loadOutputs() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &deviceListAddress, 0, nil, &size) == 0, size > 0 else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &deviceListAddress, 0, nil, &size, &ids) == 0 else { return }

        let found = ids.compactMap { id -> Output? in
            guard Self.hasOutputStreams(id), let name = Self.name(of: id) else { return nil }
            return Output(id: id, name: name)
        }
        if outputs != found { outputs = found }
    }

    func setOutput(_ id: AudioObjectID) {
        var value = id
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value
        )
    }

    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == 0 && size > 0
    }

    private static func name(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == 0,
              let value = name?.takeRetainedValue()
        else { return nil }
        return value as String
    }

    // MARK: actions

    func setVolume(_ value: Float) {
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if muted && v > 0 { setMuted(false) }
    }

    func setMuted(_ value: Bool) {
        var v: UInt32 = value ? 1 : 0
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    func toggleMute() {
        setMuted(!muted)
    }

    /// One step = 1/16, same as the volume keys.
    func step(_ steps: Int) {
        guard let volume else { return }
        setVolume(volume + Float(steps) / 16)
    }
}
