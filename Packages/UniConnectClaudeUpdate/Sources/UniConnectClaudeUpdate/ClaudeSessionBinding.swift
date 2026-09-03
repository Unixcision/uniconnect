import Foundation

/// The persisted information required to restore one exact Claude session.
public struct ClaudeSessionBinding: Sendable, Hashable, Codable {
    /// The Claude conversation UUID that must be resumed and verified.
    public let sessionID: UUID

    /// The normalized working directory captured for the session.
    public let workingDirectory: String

    /// The stable Claude executable or launcher path used by the session.
    public let executablePath: String

    /// A non-secret identity for the native or npm installation behind the executable.
    public let installationID: String

    /// Creates a persisted Claude session binding.
    ///
    /// - Parameters:
    ///   - sessionID: The exact Claude conversation UUID.
    ///   - workingDirectory: The normalized directory in which the conversation runs.
    ///   - executablePath: The stable executable or launcher path used for update and restore.
    ///   - installationID: A non-secret identity distinguishing conflicting installations.
    public init(
        sessionID: UUID,
        workingDirectory: String,
        executablePath: String,
        installationID: String
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.executablePath = executablePath
        self.installationID = installationID
    }
}
