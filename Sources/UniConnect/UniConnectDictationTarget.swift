import Foundation

/// The terminal a dictation is pasted into.
///
/// It is chosen when the recording stops, the way the phone keeps the window it was dictating
/// for: moving to another window while Whisper reads does not move the text.
struct UniConnectDictationTarget: Equatable, Sendable {
    let workspaceID: UUID
    let panelID: UUID
    /// Window name shown to the user («Pegado en GYM DATOS»).
    let name: String
}
