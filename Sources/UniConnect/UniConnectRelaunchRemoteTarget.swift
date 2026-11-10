import CMUXAgentLaunch
import Foundation

/// An SSH window as the Linux worker proved it, everything needed to relaunch it there.
///
/// The worker on the destination is the single executor for this pane: it holds the lock and the
/// journal next to it (`~/.local/state/uniconnect/relaunch-v1`). The Mac only carries its proof
/// back verbatim and reads the journal.
struct UniConnectRelaunchRemoteTarget: Sendable, Equatable {
    /// The box's vault credential.
    let credentialID: UUID
    /// The tmux session of the window.
    let session: String
    /// The tmux socket on the destination (`default`).
    let socket: String
    /// The window's stable id (its panel), sent as `window_id`.
    let windowID: String
    /// The proof `inspect` returned, sent back as `expected`.
    let proof: Data
    /// Claude's stable launcher on the destination, from the proof; one installation per launcher.
    var launcher: String? = nil
}
