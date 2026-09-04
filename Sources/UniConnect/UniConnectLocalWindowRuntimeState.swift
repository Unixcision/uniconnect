import Foundation

/// Describes what the terminal process of a persistent local window is doing now.
enum UniConnectLocalWindowRuntimeState: String, Codable, Equatable, Sendable {
    /// The login shell is available, including while it is running a non-agent command.
    case shell
    /// A resumable coding-agent conversation is currently running.
    case agent
    /// The terminal child process exited, but the logical window remains recoverable.
    case stopped
}
