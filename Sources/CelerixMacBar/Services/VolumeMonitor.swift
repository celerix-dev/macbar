import Foundation
import CoreAudio
import AudioToolbox

final class VolumeMonitor {
    static let shared = VolumeMonitor()

    private var currentOutputDeviceID: AudioDeviceID = 0
    private var isObserving = false
    private var observers: [UUID: (Int, Bool) -> Void] = [:]
    private let observersLock = NSLock()

    @discardableResult
    func addObserver(_ observer: @escaping (Int, Bool) -> Void) -> UUID {
        let id = UUID()
        observersLock.lock()
        observers[id] = observer
        observersLock.unlock()
        let state = fetchVolumeAndMute()
        observer(state.volume, state.isMuted)
        return id
    }

    func removeObserver(_ id: UUID) {
        observersLock.lock()
        observers.removeValue(forKey: id)
        observersLock.unlock()
    }

    var onVolumeChanged: ((Int, Bool) -> Void)? {
        didSet {
            if let onVolumeChanged = onVolumeChanged {
                _ = addObserver(onVolumeChanged)
            }
        }
    }

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var scalarVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        startObserving()
    }

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        // 1. Observe default output device change
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.updateDeviceObservation()
            self?.notifyVolumeChange()
        }

        updateDeviceObservation()
    }

    private func updateDeviceObservation() {
        let newDeviceID = getDefaultOutputDeviceID()
        guard newDeviceID != currentOutputDeviceID else { return }

        // Remove listener from old device if valid
        if currentOutputDeviceID != 0 {
            AudioObjectRemovePropertyListenerBlock(
                currentOutputDeviceID,
                &volumeAddress,
                DispatchQueue.main,
                deviceVolumeListener
            )
            AudioObjectRemovePropertyListenerBlock(
                currentOutputDeviceID,
                &scalarVolumeAddress,
                DispatchQueue.main,
                deviceVolumeListener
            )
            AudioObjectRemovePropertyListenerBlock(
                currentOutputDeviceID,
                &muteAddress,
                DispatchQueue.main,
                deviceMuteListener
            )
        }

        currentOutputDeviceID = newDeviceID
        guard currentOutputDeviceID != 0 else { return }

        // Add listener on new device
        AudioObjectAddPropertyListenerBlock(
            currentOutputDeviceID,
            &volumeAddress,
            DispatchQueue.main,
            deviceVolumeListener
        )
        AudioObjectAddPropertyListenerBlock(
            currentOutputDeviceID,
            &scalarVolumeAddress,
            DispatchQueue.main,
            deviceVolumeListener
        )
        AudioObjectAddPropertyListenerBlock(
            currentOutputDeviceID,
            &muteAddress,
            DispatchQueue.main,
            deviceMuteListener
        )
    }

    private lazy var deviceVolumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.notifyVolumeChange()
    }

    private lazy var deviceMuteListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.notifyVolumeChange()
    }

    private func getDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultDeviceAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    func fetchVolumeAndMute() -> (volume: Int, isMuted: Bool) {
        let deviceID = currentOutputDeviceID != 0 ? currentOutputDeviceID : getDefaultOutputDeviceID()
        guard deviceID != 0 else {
            return (0, false)
        }

        // 1. Get volume
        var volume: Float32 = 0.0
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var vAddr = volumeAddress

        var gotVolume = false
        if AudioObjectHasProperty(deviceID, &vAddr) {
            let status = AudioObjectGetPropertyData(deviceID, &vAddr, 0, nil, &volumeSize, &volume)
            if status == noErr {
                gotVolume = true
            }
        }

        if !gotVolume {
            var scalarAddr = scalarVolumeAddress
            scalarAddr.mElement = kAudioObjectPropertyElementMain
            if AudioObjectHasProperty(deviceID, &scalarAddr) {
                let status = AudioObjectGetPropertyData(deviceID, &scalarAddr, 0, nil, &volumeSize, &volume)
                if status == noErr {
                    gotVolume = true
                }
            }
        }

        if !gotVolume {
            var scalarAddr = scalarVolumeAddress
            scalarAddr.mElement = 1
            if AudioObjectHasProperty(deviceID, &scalarAddr) {
                let status = AudioObjectGetPropertyData(deviceID, &scalarAddr, 0, nil, &volumeSize, &volume)
                if status == noErr {
                    gotVolume = true
                }
            }
        }

        // 2. Get mute
        var isMuted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var mAddr = muteAddress

        if AudioObjectHasProperty(deviceID, &mAddr) {
            _ = AudioObjectGetPropertyData(deviceID, &mAddr, 0, nil, &muteSize, &isMuted)
        } else {
            mAddr.mElement = 1
            if AudioObjectHasProperty(deviceID, &mAddr) {
                _ = AudioObjectGetPropertyData(deviceID, &mAddr, 0, nil, &muteSize, &isMuted)
            }
        }

        let volumePercent = Int(round(volume * 100.0))
        return (max(0, min(100, volumePercent)), isMuted != 0)
    }

    private func notifyVolumeChange() {
        let state = fetchVolumeAndMute()
        observersLock.lock()
        let currentObservers = Array(observers.values)
        observersLock.unlock()
        for observer in currentObservers {
            observer(state.volume, state.isMuted)
        }
    }
}
