/// Stable failures emitted by the controlled process boundary.
enum UniConnectProcessRunnerError: Error, Sendable, Equatable {
    case invalidRequest
    case launchFailed
    case timedOut
    case cancelled
    case shutDown
    case outputReadFailed
}
