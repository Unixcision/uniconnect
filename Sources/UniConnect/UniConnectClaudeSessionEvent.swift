import UniConnectClaudeBridge

/// A trusted local or authenticated remote transition for one Claude target.
enum UniConnectClaudeSessionEvent: Sendable, Equatable {
    case local(UniConnectClaudeSessionSignal)
    case remote(ClaudeBridgeSessionSignal)
}
