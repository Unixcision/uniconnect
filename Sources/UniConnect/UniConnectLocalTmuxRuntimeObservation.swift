import Foundation

/// A verified observation of an existing pane, never a request to launch or resume it.
struct UniConnectLocalTmuxRuntimeObservation: Sendable {
    struct Target: Sendable {
        let owner: UniConnectLocalTmuxOwner
        let record: UniConnectLocalWindowRecord
    }

    enum State: Equatable, Sendable {
        case agent(conversationID: UUID)
        case shell
    }

    let target: Target
    let state: State
}
