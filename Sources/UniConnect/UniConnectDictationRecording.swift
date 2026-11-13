import Foundation

/// The microphone behind «Dictado»; the app passes ``UniConnectDictationAudioRecorder`` and tests
/// a fake.
@MainActor
protocol UniConnectDictationRecording: AnyObject {
    /// Whether the microphone may be used, asking macOS the first time.
    func requestAccess() async -> Bool

    /// Starts recording into `url`.
    ///
    /// - Parameters:
    ///   - url: File to write (AAC in MPEG-4).
    ///   - maximumSeconds: The recording stops by itself at this length.
    ///   - onLimit: Called once when it stopped by itself, so the dictation goes on as if the
    ///     user had stopped it.
    /// - Throws: ``UniConnectDictationRecorderError``.
    func start(url: URL, maximumSeconds: TimeInterval, onLimit: @escaping @MainActor () -> Void) throws

    /// Stops, finalizes the file and returns its length in seconds.
    func stop() -> TimeInterval

    /// Stops and throws the file away.
    func cancel()

    /// Voice level now, from 0 to 1; 0 when nothing is being recorded.
    func level() -> Double
}
