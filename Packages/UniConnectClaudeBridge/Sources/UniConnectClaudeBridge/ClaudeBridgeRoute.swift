import Foundation

/// Immutable local routing metadata for one SSH/tmux terminal window.
///
/// The route deliberately contains no SSH command, password, key path, prompt,
/// response, or transcript. It is safe to retain as ordinary application state.
public struct ClaudeBridgeRoute: Codable, Hashable, Sendable {
    /// The stable bridge identity. UniConnect normally reuses the terminal panel UUID.
    public let id: UUID

    /// The workspace that should receive and navigate from the notification.
    public let workspaceID: UUID

    /// The exact terminal panel that should receive and navigate from the notification.
    public let surfaceID: UUID

    /// The vault credential identity used only for grouped cleanup.
    public let credentialID: UUID

    /// A password-free logical host label for local presentation.
    public let hostLabel: String

    /// The local workspace name shown in a notification.
    public let workspaceName: String

    /// The local terminal-window name shown in a notification.
    public let windowName: String

    /// The exact remote tmux session used to find the route from `TMUX_PANE`.
    public let tmuxSession: String

    /// Creates a privacy-minimized route.
    ///
    /// - Parameters:
    ///   - id: Stable route identity, normally the panel UUID.
    ///   - workspaceID: Local workspace UUID.
    ///   - surfaceID: Local terminal panel UUID.
    ///   - credentialID: Encrypted-vault credential UUID.
    ///   - hostLabel: Password-free logical host label.
    ///   - workspaceName: Local workspace display name.
    ///   - windowName: Local window display name.
    ///   - tmuxSession: Remote tmux session identifier.
    public init(
        id: UUID,
        workspaceID: UUID,
        surfaceID: UUID,
        credentialID: UUID,
        hostLabel: String,
        workspaceName: String,
        windowName: String,
        tmuxSession: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.credentialID = credentialID
        self.hostLabel = hostLabel
        self.workspaceName = workspaceName
        self.windowName = windowName
        self.tmuxSession = tmuxSession
    }
}
