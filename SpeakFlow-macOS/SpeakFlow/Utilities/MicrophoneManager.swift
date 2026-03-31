import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "MicrophoneManager")

struct MicrophoneInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let audioDeviceID: AudioDeviceID

    static func == (lhs: MicrophoneInfo, rhs: MicrophoneInfo) -> Bool {
        lhs.id == rhs.id
    }
}

enum MicrophoneManager {
    /// List all audio input devices on the system.
    static func listInputDevices() -> [MicrophoneInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else {
            logger.error("Failed to get audio device list size")
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else {
            logger.error("Failed to enumerate audio devices")
            return []
        }

        let devices = ids.compactMap { deviceID -> MicrophoneInfo? in
            guard hasInputChannels(deviceID) else { return nil }
            guard let name = deviceName(deviceID) else { return nil }
            return MicrophoneInfo(id: "\(deviceID)", name: name, audioDeviceID: deviceID)
        }
        logger.info("Enumerated \(devices.count) input device(s) from \(count) total audio devices")
        return devices
    }

    /// Get the system default input device ID.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else {
            logger.warning("Failed to get default input device ID")
            return nil
        }
        logger.info("Default input device ID: \(deviceID)")
        return deviceID
    }

    // MARK: - Private

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }

        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, data) == noErr else { return false }

        let bufferList = data.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let cfName = name?.takeUnretainedValue() else { return nil }
        return cfName as String
    }
}
