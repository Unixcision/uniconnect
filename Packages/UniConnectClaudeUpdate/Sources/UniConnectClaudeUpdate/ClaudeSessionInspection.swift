import Foundation

/// An exact, immutable observation of the process currently owning a target terminal.
public struct ClaudeSessionInspection: Sendable, Hashable, Codable {
    /// Whether the inspected process was positively identified as Claude Code.
    public let isClaudeProcess: Bool

    /// Whether Claude reported a state in which clean exit may be requested.
    public let isIdle: Bool

    /// The exact observed process identifier, when available.
    public let processID: Int32?

    /// The observed Claude conversation UUID, when available.
    public let sessionID: UUID?

    /// The normalized working directory observed for the process.
    public let workingDirectory: String?

    /// The stable executable or launcher path observed for the process.
    public let executablePath: String?

    /// The version reported by the restored Claude process, when available.
    public let version: ClaudeVersion?

    /// Creates a live session inspection.
    ///
    /// - Parameters:
    ///   - isClaudeProcess: Whether process identity was positively established as Claude.
    ///   - isIdle: Whether clean exit is currently safe.
    ///   - processID: The exact live PID, if available.
    ///   - sessionID: The observed Claude conversation UUID, if available.
    ///   - workingDirectory: The normalized live working directory, if available.
    ///   - executablePath: The stable executable or launcher path, if available.
    ///   - version: The version reported by the live process, if available.
    public init(
        isClaudeProcess: Bool,
        isIdle: Bool,
        processID: Int32?,
        sessionID: UUID?,
        workingDirectory: String?,
        executablePath: String?,
        version: ClaudeVersion?
    ) {
        self.isClaudeProcess = isClaudeProcess
        self.isIdle = isIdle
        self.processID = processID
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.executablePath = executablePath
        self.version = version
    }

    /// Checks the observed process against all persisted restore invariants.
    ///
    /// - Parameter target: The target whose exact Claude process is expected.
    /// - Returns: `true` only for a Claude process with matching UUID, cwd, and executable.
    public func matches(_ target: ClaudeUpdateTarget) -> Bool {
        guard let binding = target.binding else { return false }
        return isClaudeProcess
            && sessionID == binding.sessionID
            && workingDirectory == binding.workingDirectory
            && executablePath == binding.executablePath
    }
}
