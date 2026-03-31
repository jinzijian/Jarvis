import AudioToolbox
import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "AudioRecorder")

final class AudioRecorderService {
    private var recorder: AVAudioRecorder?
    private var tempFileURL: URL?

    /// Start recording, optionally using a specific input device.
    /// Falls back to the default device if the requested one fails.
    func startRecording(deviceID: AudioDeviceID? = nil) throws -> URL {
        // Ensure any previous recording is fully stopped
        if recorder != nil {
            _ = stopRecording()
        }

        // Set the input device before creating the recorder
        if let deviceID = deviceID {
            setInputDevice(deviceID)
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        do {
            let rec = try AVAudioRecorder(url: fileURL, settings: settings)
            rec.prepareToRecord()
            guard rec.record() else {
                throw RecordingError.recordFailed
            }
            recorder = rec
            tempFileURL = fileURL
            logger.info("Recording started: sampleRate=48000 channels=1 (AVAudioRecorder)")
            return fileURL
        } catch {
            // If specific device failed, retry with default
            if deviceID != nil {
                logger.warning("Failed with selected device, retrying with default: \(error.localizedDescription)")
                resetInputDevice()
                let rec = try AVAudioRecorder(url: fileURL, settings: settings)
                rec.prepareToRecord()
                guard rec.record() else {
                    throw RecordingError.recordFailed
                }
                recorder = rec
                tempFileURL = fileURL
                logger.info("Recording started with default device: sampleRate=48000 channels=1")
                return fileURL
            }
            throw error
        }
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        logger.info("Recording stopped")
        return tempFileURL
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    // MARK: - Device Selection via CoreAudio

    /// Set the system default input device so AVAudioRecorder picks it up.
    private func setInputDevice(_ deviceID: AudioDeviceID) {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        if status != noErr {
            logger.warning("Failed to set default input device (status: \(status))")
        }
    }

    /// Reset to system default (no-op, just for symmetry).
    private func resetInputDevice() {
        // AVAudioRecorder will use whatever the current default is
    }
}

enum RecordingError: LocalizedError {
    case invalidFormat(sampleRate: Double, channels: AVAudioChannelCount)
    case recordFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let rate, let ch):
            return "Microphone not ready (rate=\(rate), ch=\(ch)). Try again."
        case .recordFailed:
            return "Failed to start recording. Check microphone permissions."
        }
    }
}
