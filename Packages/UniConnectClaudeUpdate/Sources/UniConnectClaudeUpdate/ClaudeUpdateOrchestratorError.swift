/// A start or recovery error that occurs before orchestration can safely proceed.
public enum ClaudeUpdateOrchestratorError: Error, Sendable, Hashable {
    /// Another update or recovery operation already owns the orchestrator.
    case operationAlreadyRunning

    /// Durable recovery records must be reconciled before another update may begin.
    case recoveryRequired(recordCount: Int)
}
