/// A start or recovery error that occurs before orchestration can safely proceed.
public enum ClaudeUpdateOrchestratorError: Error, Sendable, Hashable {
    /// Another update or recovery operation already owns the orchestrator.
    case operationAlreadyRunning
}
