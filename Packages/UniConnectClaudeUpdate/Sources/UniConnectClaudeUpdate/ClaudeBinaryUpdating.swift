/// Reads and updates one local or remote Claude installation through a controlled process.
///
/// Implementations must return only sanitized errors; raw argv, environment, passwords, tokens,
/// and credential-vault values must never cross this boundary.
public protocol ClaudeBinaryUpdating: Sendable {
    /// Reads the version from the exact planned executable on a host.
    ///
    /// - Parameters:
    ///   - host: The host whose installation is inspected.
    ///   - executablePath: The captured executable or launcher path shared by the host plan.
    /// - Returns: The parsed installed Claude version.
    /// - Throws: When the executable cannot be resolved, launched, or parsed.
    func installedVersion(
        on host: ClaudeUpdateHostIdentity,
        executablePath: String
    ) async throws -> ClaudeVersion

    /// Runs one noninteractive, deadline-bounded update for the host installation.
    ///
    /// Remote implementations must use a separate control connection rather than typing the update
    /// command into a visible tmux pane. Secrets belong in an injected environment or stdin, never
    /// argv. Returned output must already be scrubbed of escape sequences and sensitive values.
    ///
    /// - Parameters:
    ///   - host: The host whose installation is updated once.
    ///   - executablePath: The exact executable or launcher path captured in the plan.
    /// - Returns: Captured, sanitized process output and exit status.
    /// - Throws: On launch, connection, cancellation, or transport failure.
    func update(
        on host: ClaudeUpdateHostIdentity,
        executablePath: String
    ) async throws -> ClaudeUpdateCommandResult
}
