import AVFoundation
import Foundation

/// Records «Dictado» with `AVAudioRecorder`: AAC in MPEG-4, mono, 16 kHz at 32 kbit/s.
///
/// It is the phone's format (`MediaRecorderVoice` writes AAC at 32 kbit/s), small enough for the
/// history to keep hours of it, and Whisper reads it after the same `ffmpeg` conversion as the
/// phone's clips. The microphone permission is macOS's: the first recording asks, and a refusal
/// is reported so the box can point to Ajustes del Sistema.
@MainActor
final class UniConnectDictationAudioRecorder: NSObject, UniConnectDictationRecording {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var onLimit: (@MainActor () -> Void)?

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start(url: URL, maximumSeconds: TimeInterval, onLimit: @escaping @MainActor () -> Void) throws {
        cancel()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw UniConnectDictationRecorderError.couldNotStart
        }
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record(forDuration: maximumSeconds) else {
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
            throw UniConnectDictationRecorderError.couldNotStart
        }
        self.recorder = recorder
        self.recordingURL = url
        self.onLimit = onLimit
    }

    func stop() -> TimeInterval {
        guard let recorder else { return 0 }
        let elapsed = recorder.currentTime
        let url = recordingURL
        self.recorder = nil
        self.recordingURL = nil
        self.onLimit = nil
        recorder.stop()
        // The file's own length, read once it is finalized; the recorder's clock is 0 once it
        // stopped by itself at the limit.
        if let url, let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0 {
            return player.duration
        }
        return elapsed
    }

    func cancel() {
        guard let recorder else { return }
        let url = recordingURL
        self.recorder = nil
        self.recordingURL = nil
        self.onLimit = nil
        recorder.stop()
        recorder.deleteRecording()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func level() -> Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        return min(1, max(0, (decibels + 50) / 50))
    }

    /// The recorder stopped by itself at the limit: the dictation goes on as if the user stopped it.
    private func recorderFinished(_ finished: ObjectIdentifier) {
        guard let recorder, ObjectIdentifier(recorder) == finished, let onLimit else { return }
        self.onLimit = nil
        onLimit()
    }
}

extension UniConnectDictationAudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let finished = ObjectIdentifier(recorder)
        Task { @MainActor in
            self.recorderFinished(finished)
        }
    }
}
