import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case couldNotStartRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access was denied."
        case .couldNotStartRecording:
            return "The app could not start recording."
        case .notRecording:
            return "No recording is currently active."
        }
    }
}

@MainActor
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func startRecording() async throws -> URL {
        let granted = await requestMicrophonePermission()
        guard granted else {
            throw AudioRecorderError.microphonePermissionDenied
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XactimateCatalogCuratorRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioRecorderError.couldNotStartRecording
        }
        self.recorder = recorder
        currentURL = fileURL
        return fileURL
    }

    func stopRecording() throws -> URL {
        guard let recorder, let currentURL else {
            throw AudioRecorderError.notRecording
        }
        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        return currentURL
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .restricted, .denied:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

