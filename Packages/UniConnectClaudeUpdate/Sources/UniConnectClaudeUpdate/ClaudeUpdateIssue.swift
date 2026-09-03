/// A credential-free reason code for a skipped, restored, or failed update outcome.
public enum ClaudeUpdateIssue: String, Sendable, Hashable, Codable {
    /// The target did not have a safely resolved UUID, cwd, executable, or installation identity.
    case missingSessionBinding

    /// A remote target did not have an exact tmux pane identity.
    case missingPaneIdentity

    /// A local target unexpectedly carried a tmux pane identity.
    case invalidTargetShape

    /// Preflight could not inspect the live target.
    case inspectionFailed

    /// The observed process was not the exact bound Claude session.
    case processIdentityMismatch

    /// The Claude session did not become safe to exit before the adapter deadline.
    case idleTimeout

    /// The recovery record could not be durably saved before exit.
    case journalUnavailable

    /// Sending the clean exit request failed or had an uncertain result.
    case exitRequestFailed

    /// The adapter could not prove that Claude exited and the shell returned.
    case shellTimeout

    /// The installed version could not be read before or after updating.
    case versionReadFailed

    /// The update process exceeded its controlled deadline.
    case updateTimedOut

    /// The update process returned a nonzero exit status.
    case updateCommandFailed

    /// Command output and the before/after versions did not prove a safe result.
    case updateUnverifiable

    /// Restoring or reconciling the persisted session failed.
    case restorationFailed

    /// The restored process did not match the expected UUID, cwd, and executable.
    case restorationVerificationFailed

    /// Cancellation prevented additional mutation; already-armed targets still required restore.
    case cancelled
}
