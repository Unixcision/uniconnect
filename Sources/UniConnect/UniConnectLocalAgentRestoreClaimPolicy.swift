import Foundation

/// Ensures one local agent conversation has at most one automatic or live owner.
enum UniConnectLocalAgentRestoreClaimPolicy {
    struct Claim: Hashable, Sendable {
        let kind: RestorableAgentKind
        let sessionID: String
    }

    struct Owner: Hashable, Sendable {
        let workspaceID: UUID
        let panelID: UUID
    }

    struct ActiveCandidate: Sendable {
        let owner: Owner
        let record: UniConnectLocalWindowRecord
    }

    static func claim(
        kind: RestorableAgentKind,
        sessionID: String
    ) -> Claim? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return nil }
        // Registry-owned built-ins are observed as `.custom("antigravity")`/`.custom("grok")`
        // in a live process scan, but decode to their native enum case from durable JSON.
        // Canonicalize through the wire identifier so those two representations cannot
        // claim the same conversation in separate windows.
        let normalizedKind = RestorableAgentKind(rawValue: kind.rawValue) ?? kind
        let normalizedSessionID = UUID(uuidString: trimmedSessionID)?
            .uuidString.lowercased() ?? trimmedSessionID
        return Claim(kind: normalizedKind, sessionID: normalizedSessionID)
    }

    /// Stable persisted/import identity shared by every local agent provider.
    static func canonicalKey(
        kind: RestorableAgentKind,
        sessionID: String
    ) -> String? {
        guard let claim = claim(kind: kind, sessionID: sessionID) else { return nil }
        return claim.kind.rawValue + "\u{0}" + claim.sessionID
    }

    static func claim(for conversation: UniConnectLocalAgentConversation) -> Claim {
        claim(kind: conversation.kind, sessionID: conversation.sessionID)!
    }

    static func claim(for snapshot: SessionRestorableAgentSnapshot) -> Claim? {
        claim(kind: snapshot.kind, sessionID: snapshot.sessionId)
    }

    /// Returns the deterministic live owner that conflicts with a requested manual resume.
    static func conflictingActiveOwner(
        for requestedClaim: Claim,
        requester: Owner,
        candidates: [ActiveCandidate]
    ) -> Owner? {
        candidates
            .filter { candidate in
                candidate.owner != requester
                    && candidate.record.runtimeState == .agent
                    && candidate.record.activeConversation.map { claim(for: $0) } == requestedClaim
            }
            .map(\.owner)
            .sorted(by: ownerSort)
            .first
    }

    /// Gives the first snapshot-order owner each active `(kind, sessionID)` claim.
    /// Duplicate panels stay present with their full history, but restore as shells and
    /// carry no startup binding or hibernation capable of re-launching the same UUID.
    static func resolvingDuplicateAutomaticClaims(
        in snapshot: AppSessionSnapshot,
        alreadyClaimed: Set<Claim> = []
    ) -> AppSessionSnapshot {
        var resolved = snapshot
        var claimed = alreadyClaimed

        for windowIndex in resolved.windows.indices {
            for workspaceIndex in resolved.windows[windowIndex].tabManager.workspaces.indices {
                guard resolved.windows[windowIndex]
                    .tabManager.workspaces[workspaceIndex]
                    .uniConnect?.isSSH == false else {
                    continue
                }
                for panelIndex in resolved.windows[windowIndex]
                    .tabManager.workspaces[workspaceIndex].panels.indices {
                    guard var terminal = resolved.windows[windowIndex]
                        .tabManager.workspaces[workspaceIndex].panels[panelIndex].terminal,
                          let candidateClaim = automaticClaim(for: terminal) else {
                        continue
                    }
                    guard !claimed.insert(candidateClaim).inserted else { continue }

                    if var record = terminal.uniConnectLocalWindow {
                        _ = record.transitionToShell(at: record.updatedAt)
                        terminal.uniConnectLocalWindow = record
                    }
                    terminal.wasAgentRunning = false
                    terminal.hibernation = nil
                    terminal.resumeBinding = nil
                    resolved.windows[windowIndex]
                        .tabManager.workspaces[workspaceIndex].panels[panelIndex].terminal = terminal
                }
            }
        }
        return resolved
    }

    private static func automaticClaim(
        for terminal: SessionTerminalPanelSnapshot
    ) -> Claim? {
        if let record = terminal.uniConnectLocalWindow {
            guard record.runtimeState == .agent,
                  let conversation = record.activeConversation ?? record.latestConversation else {
                return nil
            }
            return claim(for: conversation)
        }
        guard terminal.wasAgentRunning != false,
              let snapshot = terminal.agent else {
            return nil
        }
        return claim(for: snapshot)
    }

    private static func ownerSort(_ lhs: Owner, _ rhs: Owner) -> Bool {
        if lhs.workspaceID != rhs.workspaceID {
            return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
        }
        return lhs.panelID.uuidString < rhs.panelID.uuidString
    }
}
