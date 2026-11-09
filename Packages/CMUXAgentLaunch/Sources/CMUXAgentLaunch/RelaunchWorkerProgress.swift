import Foundation

/// Where one target stands according to the worker's journal (`start`, `status`).
public struct RelaunchWorkerProgress: Sendable, Equatable {
    /// The target's state; an unknown state reads as ``RelaunchTargetState/failed``.
    public let state: RelaunchTargetState
    /// The cause, when it stopped.
    public let cause: RelaunchCause?
    /// The fields of the journal, applied to a result.
    private let effectiveID: String?
    private let escalation: RelaunchEscalation?
    private let droppedOptions: [String]
    private let version: String?
    private let model: String?
    private let effort: String?
    private let backgroundSaved: Int?
    private let messageSent: Bool?
    private let draftRestored: Bool?

    /// Reads a reply to `start` or `status`.
    ///
    /// - Parameter reply: The worker's reply.
    /// - Returns: `nil` for a refusal or a reply without a state.
    public init?(reply: RelaunchWorkerReply) {
        guard reply.error == nil else { return nil }
        let fields = reply.fields
        guard let text = fields["state"] as? String else { return nil }
        let state = RelaunchTargetState(rawValue: text)
        self.state = state ?? .failed
        let causeText = fields["cause"] as? String
        // A cause this build does not know keeps the target visible as failed, never as fine.
        cause = causeText.flatMap(RelaunchCause.init(rawValue:))
            ?? (causeText != nil || state == nil ? .unknownDialog : nil)
        effectiveID = fields["effective_id"] as? String
        escalation = (fields["escalation"] as? String).flatMap(RelaunchEscalation.init(rawValue:))
        droppedOptions = fields["dropped_options"] as? [String] ?? []
        version = fields["version"] as? String
        model = fields["model"] as? String
        effort = fields["effort"] as? String
        backgroundSaved = (fields["background_saved"] as? NSNumber)?.intValue
        messageSent = fields["message_sent"] as? Bool
        draftRestored = fields["draft_restored"] as? Bool
    }

    /// Whether the target has no phases left.
    public var isSettled: Bool {
        [.verified, .failed, .skipped, .needsUser].contains(state)
    }

    /// The result of `key` as this progress describes it.
    ///
    /// - Parameters:
    ///   - key: The target.
    ///   - provider: Its agent.
    /// - Returns: The result, with every field the journal carried.
    public func result(key: RelaunchTargetKey, provider: String) -> RelaunchOperation.Result {
        var result = RelaunchOperation.Result(
            key: key, state: state, cause: cause, effectiveID: effectiveID, provider: provider
        )
        result.escalation = escalation
        result.droppedOptions = droppedOptions
        result.version = version
        result.model = model
        result.effort = effort
        result.backgroundSaved = backgroundSaved
        result.messageSent = messageSent
        result.draftRestored = draftRestored
        return result
    }
}
