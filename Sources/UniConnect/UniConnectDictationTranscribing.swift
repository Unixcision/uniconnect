import Foundation

/// What turns a recording into text for «Dictado».
///
/// In the app it is this Mac's Whisper, ``MobileTranscriptionService`` with
/// ``MobileTranscriptionLimits/macDictation``: the same engine and model that read the phone's
/// dictations. Tests pass a fake.
protocol UniConnectDictationTranscribing: Sendable {
    /// Reads `audio` and returns one line of text.
    ///
    /// - Parameters:
    ///   - audio: The whole clip.
    ///   - mime: Its format (`audio/mp4` for what the Mac records).
    ///   - language: `"es"`, `"en"` or `nil` to detect it.
    /// - Throws: ``MobileTranscriptionError``.
    func transcribe(audio: Data, mime: String, language: String?) async throws -> MobileTranscriptionOutcome
}
