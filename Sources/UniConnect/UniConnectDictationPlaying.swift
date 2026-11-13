import Foundation

/// Plays a kept dictation back; the app passes ``UniConnectDictationAudioPlayer``.
@MainActor
protocol UniConnectDictationPlaying: AnyObject {
    /// Plays `url` from the start, stopping whatever was playing.
    ///
    /// - Parameter onFinish: Called once when it ends by itself.
    /// - Returns: `false` when the file cannot be played.
    func play(_ url: URL, onFinish: @escaping @MainActor () -> Void) -> Bool

    /// Stops playing, without calling the pending `onFinish`.
    func stop()
}
