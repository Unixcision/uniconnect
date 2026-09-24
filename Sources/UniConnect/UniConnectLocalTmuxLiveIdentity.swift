import Foundation

/// The live tmux ids of a local window's session and active pane (`$N`, `%N`).
///
/// tmux renumbers them when its server restarts, so they are only shown (Detalles) and never
/// persisted; the durable identity is the socket and session name of ``UniConnectLocalTmuxBinding``.
struct UniConnectLocalTmuxLiveIdentity: Equatable, Sendable {
    let sessionID: String
    let paneID: String
}
