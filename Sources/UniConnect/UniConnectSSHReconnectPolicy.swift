import Foundation

/// Pure retry-budget policy shared by delayed and immediate tmux reconnection entry points.
enum UniConnectSSHReconnectPolicy {
    struct Owner: Equatable, Hashable, Sendable {
        let workspaceID: UUID
        let panelID: UUID
    }

    struct Candidate: Equatable, Sendable {
        let workspaceID: UUID
        let panelID: UUID
        let tmuxSession: String
        /// Filled whenever the credential still resolves. It permits global deduplication
        /// across boxes and immutable credential revisions that name the same endpoint.
        let targetKey: UniConnectSSHTargetKey?

        init(
            workspaceID: UUID,
            panelID: UUID,
            tmuxSession: String,
            targetKey: UniConnectSSHTargetKey? = nil
        ) {
            self.workspaceID = workspaceID
            self.panelID = panelID
            self.tmuxSession = tmuxSession
            self.targetKey = targetKey
        }

        var owner: Owner {
            Owner(workspaceID: workspaceID, panelID: panelID)
        }
    }

    static func nextAttempt(
        trigger: UniConnectSSHReconnectTrigger,
        isDisconnected: Bool,
        attemptsSpent: Int,
        maximumAutomaticAttempts: Int,
        hasReconnectInFlight: Bool
    ) -> Int? {
        guard !hasReconnectInFlight else { return nil }
        switch trigger {
        case .userForced:
            // A deliberate reconnect is allowed for a hung-but-not-yet-disconnected ssh process.
            // It starts a fresh outage budget, with this immediate reconnect as attempt one.
            return 1
        case .automatic:
            guard isDisconnected,
                  attemptsSpent < maximumAutomaticAttempts else {
                return nil
            }
            return attemptsSpent + 1
        }
    }

    /// Keeps one deterministic panel per logical endpoint/tmux target. A candidate whose
    /// credential cannot be resolved falls back to its workspace identity so reconnecting
    /// unrelated unresolved records is never suppressed.
    static func deduplicatedCandidates(_ candidates: [Candidate]) -> [Candidate] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.workspaceID != rhs.workspaceID {
                return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
            }
            if lhs.tmuxSession != rhs.tmuxSession {
                return lhs.tmuxSession < rhs.tmuxSession
            }
            return lhs.panelID.uuidString < rhs.panelID.uuidString
        }
        enum DedupeKey: Hashable {
            case target(UniConnectSSHTargetKey)
            case unresolved(workspaceID: UUID, tmuxSession: String)
        }
        var seen = Set<DedupeKey>()
        return ordered.filter { candidate in
            let key = candidate.targetKey.map(DedupeKey.target)
                ?? .unresolved(workspaceID: candidate.workspaceID, tmuxSession: candidate.tmuxSession)
            return seen.insert(key).inserted
        }
    }

    /// Returns the deterministic live owner that blocks opening the same remote target.
    static func conflictingCandidate(
        for targetKey: UniConnectSSHTargetKey,
        excluding owners: Set<Owner>,
        in candidates: [Candidate]
    ) -> Candidate? {
        candidates
            .filter {
                $0.targetKey == targetKey && !owners.contains($0.owner)
            }
            .sorted(by: candidateSort)
            .first
    }

    /// Chooses the sole deterministic owner when legacy/restored state already contains
    /// multiple live records for one target, preventing mutual reconnect deadlock.
    static func canonicalOwner(
        for targetKey: UniConnectSSHTargetKey,
        in candidates: [Candidate]
    ) -> Owner? {
        candidates
            .filter { $0.targetKey == targetKey }
            .sorted(by: candidateSort)
            .first?
            .owner
    }

    private static func candidateSort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.workspaceID != rhs.workspaceID {
            return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
        }
        if lhs.tmuxSession != rhs.tmuxSession {
            return lhs.tmuxSession < rhs.tmuxSession
        }
        return lhs.panelID.uuidString < rhs.panelID.uuidString
    }
}
