import Foundation

/// What is known about the agent living in a pane, gathered from outside its screen.
///
/// The screen is not enough and for some agents it is nothing at all: Claude prints its conversation
/// on the way out, Codex does not. What settles identity there is a writer lock **actually held by
/// the process** (`fdinfo` / `/proc/locks`) or a rollout open for writing — and a hook record only
/// when its process, start PID and pane all agree.
///
/// What must never settle it: the first UUID that happens to be visible, the argument the pane was
/// started with, a lock *file* that merely exists, or "the last one". Each of those resumes somebody
/// else's conversation sooner or later, and doing that is worse than not resuming at all.
public struct RelaunchIdentityEvidence: Sendable, Equatable {
    /// The process currently occupying the pane.
    public let processID: Int32
    /// The PID recorded when this pane's agent was started, if the host kept one.
    public let startProcessID: Int32?
    /// The pane this evidence was gathered from, so a record from another pane cannot vouch for it.
    public let pane: String
    /// Conversation identifiers whose writer lock this very process holds.
    public let lockedConversations: [String]
    /// Conversation identifiers whose rollout this process has open for writing.
    public let writableRollouts: [String]
    /// What a hook recorded, and the process and pane it recorded it for.
    public let hook: Hook?

    /// A hook's claim about which conversation a pane is on.
    public struct Hook: Sendable, Equatable {
        public let conversationID: String
        public let processID: Int32
        public let pane: String

        public init(conversationID: String, processID: Int32, pane: String) {
            self.conversationID = conversationID
            self.processID = processID
            self.pane = pane
        }
    }

    public init(
        processID: Int32,
        startProcessID: Int32? = nil,
        pane: String,
        lockedConversations: [String] = [],
        writableRollouts: [String] = [],
        hook: Hook? = nil
    ) {
        self.processID = processID
        self.startProcessID = startProcessID
        self.pane = pane
        self.lockedConversations = lockedConversations
        self.writableRollouts = writableRollouts
        self.hook = hook
    }

    /// The conversation this evidence proves, or `nil` when it proves none.
    ///
    /// Held locks and writable rollouts are proof because only the live process can hold them. A
    /// hook is hearsay that becomes proof only when its process and pane match the ones in front of
    /// us. More than one candidate is **ambiguous**, which is a refusal and not a coin toss.
    public var provenConversation: String? {
        var candidates = Set(lockedConversations).union(writableRollouts)
        if let hook, hook.processID == processID, hook.pane == pane,
           startProcessID.map({ $0 == hook.processID }) ?? true {
            candidates.insert(hook.conversationID)
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}
