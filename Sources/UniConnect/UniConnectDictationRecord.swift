import Foundation

/// One dictation recorded on this Mac, kept in «Dictado»'s history.
///
/// It mirrors the phone's history entry: the audio is kept from the moment the recording stops,
/// before Whisper reads it, so a transcription that fails or a paste that lands in the wrong
/// window never costs what was said. The text can be pasted again and the audio played back.
struct UniConnectDictationRecord: Codable, Equatable, Identifiable, Sendable {
    /// Where the entry is.
    enum State: String, Codable, Sendable {
        /// Recorded and handed to Whisper; nothing came back yet.
        case transcribing
        /// ``UniConnectDictationRecord/text`` holds what Whisper understood.
        case done
        /// Whisper could not read it (failed, cancelled or interrupted): only the audio is left.
        case unread
    }

    let id: String
    /// When the recording stopped.
    let createdAt: Date
    /// The transcription; `nil` while it is being read, or when it could not be read.
    var text: String?
    var state: State
    /// Name of the kept audio inside the history folder; `nil` once the cleaner removed it.
    var audioFile: String?
    /// Size of the kept audio, for the retention limit.
    var audioBytes: Int64
    /// Length of the recording, in seconds.
    var seconds: Double
    /// Name of the window the text was pasted into, if it was.
    var pastedInto: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case text
        case state
        case audioFile = "audio"
        case audioBytes = "audio_bytes"
        case seconds
        case pastedInto = "pasted_into"
    }
}
