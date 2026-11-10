import Foundation

/// What `inspect` proved about a pane: the opaque proof to send back, and what the plan shows.
public struct RelaunchWorkerProof: Sendable, Equatable {
    /// The proof, verbatim, to be sent back as `expected`.
    public let raw: Data
    /// The worker's own key (`linux:<digest>|gen:<n>`).
    public let workerKey: String?
    /// The pane occupant's generation.
    public let generation: Int
    /// The tmux pane id (`%815`).
    public let pane: String?
    /// The conversation proven live.
    public let effectiveID: String?
    /// Claude's stable launcher on the destination (`installation.launcher`), for `update`.
    public let launcher: String?
    /// What the plan shows about it.
    public let notes: RelaunchTargetNotes

    /// Reads a reply to `inspect`.
    ///
    /// - Parameter reply: The worker's reply.
    /// - Returns: `nil` for a refusal or a reply without a generation.
    public init?(reply: RelaunchWorkerReply) {
        guard reply.error == nil else { return nil }
        let fields = reply.fields
        guard let generation = (fields["generation"] as? NSNumber)?.intValue else { return nil }
        raw = reply.object
        workerKey = fields["key"] as? String
        self.generation = generation
        pane = (fields["pane"] as? [String: Any])?["pane"] as? String
        effectiveID = fields["effective_id"] as? String
        let installation = fields["installation"] as? [String: Any]
        launcher = installation?["launcher"] as? String
        notes = RelaunchTargetNotes(
            warning: (fields["warning"] as? String).flatMap(RelaunchCause.init(rawValue:))
                ?? ((fields["active"] as? Bool) == true ? .backgroundTasks : nil),
            background: (fields["background"] as? NSNumber)?.intValue,
            draft: fields["draft"] as? Bool,
            contextTokens: (fields["context_tokens"] as? NSNumber)?.intValue,
            message: fields["message"] as? Bool,
            version: fields["version"] as? String ?? installation?["version"] as? String,
            installed: fields["installed"] as? String ?? installation?["installed"] as? String,
            droppedOptions: fields["dropped_options"] as? [String] ?? []
        )
    }
}
