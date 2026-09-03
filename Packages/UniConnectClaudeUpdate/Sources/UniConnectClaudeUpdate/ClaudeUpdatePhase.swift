/// A state-machine phase published for one operation or target.
public enum ClaudeUpdatePhase: String, Sendable, Hashable, Codable, CaseIterable {
    /// Work has not started for the target.
    case pending

    /// Validate persisted identity against the live process.
    case preflight

    /// Await an adapter-provided idle signal before requesting exit.
    case waitingForIdle

    /// Persist recovery intent and send Claude's clean `/exit` command.
    case requestingExit

    /// Await proof that the old Claude PID is gone and the shell owns the terminal.
    case waitingForShell

    /// Run the host's single controlled update command.
    case updating

    /// Read and compare the installed version after the command.
    case verifyingUpdate

    /// Resume or reconcile the exact persisted session.
    case restoring

    /// Verify that the expected UUID, cwd, and executable are live again.
    case verifyingSession

    /// The target or operation has a terminal outcome.
    case completed
}
