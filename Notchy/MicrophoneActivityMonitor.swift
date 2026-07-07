import Foundation
import CoreAudio

enum MicrophoneActivityMonitor {
    /// True if any audio device with input streams is currently running.
    /// We can't rely on the default input device alone — Teams, Zoom, etc.
    /// frequently route through a specific device (headset, virtual mic)
    /// that isn't the system default.
    static var isInputDeviceActive: Bool {
        for deviceID in allAudioDevices() where deviceHasInputStreams(deviceID) {
            if deviceIsRunningSomewhere(deviceID) {
                return true
            }
        }
        return false
    }

    private static func allAudioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize,
            &devices
        )
        guard status == noErr else { return [] }
        return devices
    }

    private static func deviceHasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else { return false }
        return dataSize > 0
    }

    private static func deviceIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0, nil,
            &size,
            &isRunning
        )
        guard status == noErr else { return false }
        return isRunning != 0
    }
}
