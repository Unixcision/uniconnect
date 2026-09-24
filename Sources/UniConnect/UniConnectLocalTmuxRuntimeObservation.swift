import CMUXAgentLaunch
import Foundation

/// A verified observation of an existing pane, never a request to launch or resume it.
struct UniConnectLocalTmuxRuntimeObservation: Sendable {
    struct Target: Sendable {
        let owner: UniConnectLocalTmuxOwner
        let record: UniConnectLocalWindowRecord
    }

    enum State: Equatable, Sendable {
        /// Legacy: a conversation already in the record. The service no longer emits it; kept so
        /// older call sites and snapshots keep compiling.
        case agent(conversationID: UUID)
        /// Exactly one agent in the pane's process subtree, on a known conversation.
        case discovered(AgentObservedConversation)
        /// Exactly one agent, but without a conversation id yet (`sin_id`). Never persisted.
        case unidentified(AgentObservedProvider)
        /// More than one independent agent in the pane (`identidad_ambigua`). Never persisted.
        case ambiguous
        case shell
    }

    let target: Target
    let state: State
}
