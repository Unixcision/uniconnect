/// Controls exact local or remote Claude sessions without exposing terminal implementation types.
///
/// Implementations must return only sanitized errors and must never expose SSH argv, environment,
/// passwords, tokens, or credential-vault values.
public protocol ClaudeSessionControlling: Sendable {
    /// Inspects the exact process currently owning a target.
    ///
    /// - Parameter target: The immutable target to inspect.
    /// - Returns: Live identity fields used for fail-closed comparison.
    /// - Throws: When the target cannot be inspected safely.
    func inspect(_ target: ClaudeUpdateTarget) async throws -> ClaudeSessionInspection

    /// Awaits a real idle/safe-to-exit signal with an adapter-owned bounded deadline.
    ///
    /// Implementations must consume a process or terminal signal rather than polling or sleeping.
    ///
    /// - Parameter target: The exact target expected to become idle.
    /// - Returns: A fresh inspection captured at the idle transition.
    /// - Throws: On timeout, cancellation, disconnect, or identity loss.
    func waitUntilReadyForExit(_ target: ClaudeUpdateTarget) async throws -> ClaudeSessionInspection

    /// Sends Claude's clean `/exit` command to the exact validated target.
    ///
    /// The adapter must revalidate `expectedProcessID`, pane identity, UUID, cwd, and executable at
    /// the send boundary, confirm the session is still safe to exit, and fail closed if any value
    /// changed since preflight.
    ///
    /// - Parameters:
    ///   - target: The target previously validated and durably journaled.
    ///   - expectedProcessID: The exact PID validated immediately before journaling.
    /// - Throws: When the exit request cannot be sent; the result may be uncertain, so callers
    ///   retain their restoration obligation.
    func requestCleanExit(
        _ target: ClaudeUpdateTarget,
        expectedProcessID: Int32
    ) async throws

    /// Awaits proof that the old Claude PID is gone and the owning shell has returned.
    ///
    /// - Parameters:
    ///   - target: The exact target whose exit was requested.
    ///   - exitedProcessID: The PID that must be absent before the shell is accepted.
    /// - Throws: On deadline, disconnect, pane replacement, or any ambiguous state.
    func waitForShellAfterExit(
        _ target: ClaudeUpdateTarget,
        exitedProcessID: Int32
    ) async throws

    /// Idempotently restores or reconciles the exact bound Claude session.
    ///
    /// If the expected UUID is already live under a PID different from `replacingProcessID`, the
    /// implementation must succeed without launching a duplicate. The old PID itself is not proof
    /// of restoration: when it is still live, the implementation must first await its exit and the
    /// owning shell before resuming the session. Restoration must not be abandoned merely because
    /// the update task was cancelled. It must use the persisted cwd, executable, and UUID from
    /// ``ClaudeSessionBinding`` and add the required `--dangerously-skip-permissions` resume flag.
    ///
    /// - Parameters:
    ///   - target: The durably journaled target to restore.
    ///   - replacingProcessID: The old Claude PID that must be gone before a live matching session
    ///     can satisfy restoration, or `nil` when no prior PID was durably observed.
    /// - Throws: When the session cannot be safely resumed or reconciled.
    func restore(
        _ target: ClaudeUpdateTarget,
        replacingProcessID: Int32?
    ) async throws
}
