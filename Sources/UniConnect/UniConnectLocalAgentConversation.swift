import Foundation

/// A durable, secret-free reference to one agent conversation seen in a local window.
struct UniConnectLocalAgentConversation: Codable, Equatable, Identifiable, Sendable {
    static let maximumSessionIDUTF8Bytes = 8 * 1_024
    static let maximumDisplayNameUTF8Bytes = 512
    static let maximumKindIDUTF8Bytes = 128

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case sessionID
        case displayName
        case firstSeenAt
    }

    let id: UUID
    let kind: RestorableAgentKind
    let sessionID: String
    let displayName: String
    let firstSeenAt: TimeInterval

    init?(
        id: UUID = UUID(),
        kind: RestorableAgentKind,
        sessionID: String,
        displayName: String? = nil,
        firstSeenAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard sessionID.utf8.count <= Self.maximumSessionIDUTF8Bytes,
              !sessionID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty,
              kind.rawValue.utf8.count <= Self.maximumKindIDUTF8Bytes else {
            return nil
        }
        if let displayName {
            guard displayName.utf8.count <= Self.maximumDisplayNameUTF8Bytes,
                  !displayName.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                return nil
            }
        }
        let normalizedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName = normalizedDisplayName?.isEmpty == false
            ? normalizedDisplayName!
            : kind.displayName
        guard resolvedDisplayName.utf8.count <= Self.maximumDisplayNameUTF8Bytes else {
            return nil
        }
        self.id = id
        self.kind = kind
        self.sessionID = normalizedSessionID
        self.displayName = resolvedDisplayName
        self.firstSeenAt = firstSeenAt.isFinite ? firstSeenAt : 0
    }

    init?(
        id: UUID = UUID(),
        snapshot: SessionRestorableAgentSnapshot,
        firstSeenAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.init(
            id: id,
            kind: snapshot.kind,
            sessionID: snapshot.sessionId,
            displayName: snapshot.agentDisplayName,
            firstSeenAt: firstSeenAt
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decoded = UniConnectLocalAgentConversation(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(RestorableAgentKind.self, forKey: .kind),
            sessionID: try container.decode(String.self, forKey: .sessionID),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            firstSeenAt: try container.decodeIfPresent(TimeInterval.self, forKey: .firstSeenAt) ?? 0
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID,
                in: container,
                debugDescription: "Invalid UniConnect local agent session identifier"
            )
        }
        self = decoded
    }

    /// Stable identity used to deduplicate repeated hook/process observations.
    var identityKey: String {
        let normalizedSessionID = UUID(uuidString: sessionID)?
            .uuidString.lowercased() ?? sessionID
        return kind.rawValue + "\u{0}" + normalizedSessionID
    }

    /// Rebuilds the minimum safe resume snapshot using the validated window cwd.
    func restorableSnapshot(
        workingDirectory: String,
        registry: CmuxVaultAgentRegistry
    ) -> SessionRestorableAgentSnapshot {
        let customRegistration = kind.customAgentID.flatMap { customAgentID in
            registry.registration(id: customAgentID)
        }
        return SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionID,
            workingDirectory: workingDirectory,
            launchCommand: safeLaunchCommand(
                workingDirectory: workingDirectory,
                registration: customRegistration
            ),
            registration: customRegistration
        )
    }

    /// Keeps only explicit permission policy flags; captured argv and environment may contain secrets.
    private func safeLaunchCommand(
        workingDirectory: String,
        registration: CmuxVaultAgentRegistration?
    ) -> AgentLaunchCommandSnapshot? {
        let executable: String
        let arguments: [String]
        switch kind {
        case .claude:
            executable = "claude"
            arguments = [executable, "--dangerously-skip-permissions"]
        case .codex:
            executable = "codex"
            arguments = [executable, "--yolo"]
        case .antigravity:
            executable = "agy"
            arguments = [executable, "--dangerously-skip-permissions"]
        case .grok:
            executable = "grok"
            arguments = [executable]
        case .custom:
            guard let registration else { return nil }
            executable = registration.defaultExecutable
            arguments = [executable]
        default:
            return nil
        }
        return AgentLaunchCommandSnapshot(
            launcher: nil,
            executablePath: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: nil,
            capturedAt: firstSeenAt,
            source: "uniconnect-local-history"
        )
    }
}
