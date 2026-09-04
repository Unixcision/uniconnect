/// Credential-free failures from exact Claude session control.
enum UniConnectClaudeSessionControllerError: Error, Sendable, Equatable {
    case invalidTarget
    case identityMismatch
    case sessionNotIdle
    case panelUnavailable
    case inputRejected
    case shellUnavailable
    case timedOut
    case restoreUnavailable
}
