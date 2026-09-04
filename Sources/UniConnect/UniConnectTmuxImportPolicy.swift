import Foundation

/// Describes whether a CONNECT declaration may create a remote tmux session.
enum UniConnectTmuxImportPolicy: String, Equatable, Hashable, Sendable {
    /// The named session must already exist and import may only attach to it.
    case attachExisting
    /// Import may create the named session when it does not exist.
    case createIfMissing
    /// The document did not state whether the session already exists.
    case unspecified
}
