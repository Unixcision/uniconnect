/// The exact tmux pane that owns a remote Claude process.
public struct ClaudeTmuxPaneIdentity: Sendable, Hashable, Codable {
    /// The tmux session name.
    public let sessionName: String

    /// The tmux window index captured during preflight.
    public let windowIndex: Int

    /// The tmux pane index captured during preflight.
    public let paneIndex: Int

    /// The tmux server's stable pane identifier, such as `%3`.
    public let paneID: String

    /// Creates an exact tmux pane identity.
    ///
    /// - Parameters:
    ///   - sessionName: The tmux session containing the pane.
    ///   - windowIndex: The captured window index.
    ///   - paneIndex: The captured pane index.
    ///   - paneID: The stable tmux pane identifier returned by tmux.
    public init(sessionName: String, windowIndex: Int, paneIndex: Int, paneID: String) {
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.paneIndex = paneIndex
        self.paneID = paneID
    }
}
