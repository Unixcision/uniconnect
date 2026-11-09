import Foundation

/// What a relaunch operation actually does to its targets.
///
/// Three verbs and never one: someone who asks to "reconnect" almost always wants the transport
/// back, not their conversation closed and reopened. Collapsing them is what turns a reconnection
/// into lost work, so the distinction lives in the type and not in a flag.
public enum RelaunchVerb: String, Sendable, Codable, CaseIterable {
    /// Reattaches the client to what is already running. Closes nothing, creates nothing.
    case transportReconnect = "transport.reconnect"

    /// Closes the agent and reopens it on the same conversation. Never touches tmux.
    case agentRelaunch = "agent.relaunch"

    /// Tells a live agent to carry on the previous assignment. Not a blanket approval.
    case agentContinue = "agent.continue"

    /// Runs `claude update` once per installation, then relaunches like ``agentRelaunch``,
    /// optionally with another model or effort (`contracts/relaunch-v1`, 09-11-2026). Claude only.
    case agentUpdate = "agent.update"

    /// The phases a target of this verb walks through, in order, before ``RelaunchTargetState/verified``.
    public var phases: [RelaunchTargetState] {
        switch self {
        case .agentRelaunch, .agentUpdate: [.planned, .closing, .reopening]
        case .transportReconnect: [.planned, .reattaching]
        case .agentContinue: [.planned, .delivering]
        }
    }

    /// Whether reaching ``RelaunchTargetState/verified`` requires the same conversation to be live.
    ///
    /// Only ``agentRelaunch`` and ``agentUpdate`` have a conversation to compare: reconnecting has
    /// none, and continuing compares an acknowledgement instead.
    public var verifiesConversationIdentity: Bool { self == .agentRelaunch || self == .agentUpdate }

    /// Whether this verb closes the agent and reopens it on the same conversation.
    public var reopensConversation: Bool { verifiesConversationIdentity }
}
