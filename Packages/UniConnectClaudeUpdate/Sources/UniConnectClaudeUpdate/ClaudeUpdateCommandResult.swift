/// Captured, credential-scrubbed output from one controlled `claude update` process.
public struct ClaudeUpdateCommandResult: Sendable, Hashable, Codable {
    /// The process exit status.
    public let exitCode: Int32

    /// Whether the process was terminated at its configured interaction or runtime deadline.
    public let didTimeOut: Bool

    /// Captured standard output after the service removed terminal escapes and sensitive values.
    public let standardOutput: String

    /// Captured standard error after the service removed terminal escapes and sensitive values.
    public let standardError: String

    /// Creates captured update-process output.
    ///
    /// - Parameters:
    ///   - exitCode: The controlled process exit status.
    ///   - didTimeOut: Whether an adapter deadline stopped the command.
    ///   - standardOutput: Sanitized standard output.
    ///   - standardError: Sanitized standard error.
    public init(
        exitCode: Int32,
        didTimeOut: Bool,
        standardOutput: String,
        standardError: String
    ) {
        self.exitCode = exitCode
        self.didTimeOut = didTimeOut
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}
