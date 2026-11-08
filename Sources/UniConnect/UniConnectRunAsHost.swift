import Foundation

/// The machine a window switches user on, as `run-as.v1` needs it: the wrapper's secret and
/// diary, and the pane `su` asks in.
///
/// The password crosses this seam only into ``writeSecret(_:windowID:)`` and
/// ``pastePassword(_:windowID:)``; neither puts it in a command line or an environment.
protocol UniConnectRunAsHost: Sendable {
    /// Leaves the password in `<dir>/<id>.secret` (0600) for the wrapper's askpass.
    func writeSecret(_ password: String, windowID: String) async throws
    /// Removes a secret the wrapper did not consume.
    func removeSecret(windowID: String) async
    /// The wrapper's diary so far, or `nil` while it does not exist.
    func diary(windowID: String) async -> String?
    /// Whether `su` is a child of the pane's process, i.e. its question is the pane's.
    func suIsAsking(windowID: String) async -> Bool
    /// Pastes the password into the pane through a tmux buffer, then Enter.
    func pastePassword(_ password: String, windowID: String) async throws
}
