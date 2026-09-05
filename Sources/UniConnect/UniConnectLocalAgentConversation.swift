import Foundation

/// A durable, secret-free reference to one agent conversation seen in a local window.
struct UniConnectLocalAgentConversation: Codable, Equatable, Identifiable, Sendable {
    /// A validated, immutable copy of the custom provider contract used by this conversation.
    struct CustomAgentDescriptor: Codable, Equatable, Sendable {
        static let currentVersion = 1
        static let maximumNameUTF8Bytes = 512
        static let maximumTemplateUTF8Bytes = 16 * 1_024
        static let maximumPathUTF8Bytes = 4 * 1_024
        static let maximumDetectValues = 64
        static let maximumDetectValueUTF8Bytes = 1_024

        private enum CodingKeys: String, CodingKey {
            case version
            case registration
        }

        let version: Int
        let registration: CmuxVaultAgentRegistration

        init?(registration: CmuxVaultAgentRegistration) {
            guard Self.isSafeForPersistence(registration) else { return nil }
            self.version = Self.currentVersion
            self.registration = registration
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .version)
            guard version == Self.currentVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "Unsupported UniConnect custom-agent descriptor version \(version)"
                )
            }
            let registration = try container.decode(
                CmuxVaultAgentRegistration.self,
                forKey: .registration
            )
            guard let validated = CustomAgentDescriptor(registration: registration) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .registration,
                    in: container,
                    debugDescription: "Invalid UniConnect custom-agent resume descriptor"
                )
            }
            self = validated
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(registration, forKey: .registration)
        }

        private static func isSafeForPersistence(
            _ registration: CmuxVaultAgentRegistration
        ) -> Bool {
            guard CmuxVaultAgentRegistration.isValidID(registration.id),
                  RestorableAgentKind(rawValue: registration.id)?.customAgentID
                    == registration.id,
                  isSafeString(registration.name, maximumBytes: maximumNameUTF8Bytes),
                  isSafeString(
                      registration.resumeCommand,
                      maximumBytes: maximumTemplateUTF8Bytes
                  ),
                  !containsSensitivePersistenceMaterial(registration),
                  registration.resumeCommand.contains("{{sessionId}}")
                      || registration.resumeCommand.contains("{{sessionPath}}"),
                  isSafeOptionalString(
                      registration.iconAssetName,
                      maximumBytes: maximumPathUTF8Bytes
                  ),
                  isSafeOptionalString(
                      registration.sessionDirectory,
                      maximumBytes: maximumPathUTF8Bytes
                  ),
                  isSafeDetectRule(registration.detect),
                  isSafeSessionIDSource(registration.sessionIdSource) else {
                return false
            }
            return true
        }

        /// Rejects provider contracts that could reinterpret a captured credential as a
        /// conversation identifier or copy credential-bearing commands into readable history.
        fileprivate static func containsSensitivePersistenceMaterial(
            _ registration: CmuxVaultAgentRegistration
        ) -> Bool {
            if SurfaceResumeCommandCanonicalizer.containsSSHConnectionMaterial(
                registration.resumeCommand
            ) || commandContainsCredentialMaterial(registration.resumeCommand) {
                return true
            }
            guard case .argvOption(let option) = registration.sessionIdSource else {
                return false
            }
            return isSensitiveOptionName(option)
        }

        private static func commandContainsCredentialMaterial(_ command: String) -> Bool {
            guard let tokens = SurfaceResumeCommandCanonicalizer.tokens(from: command) else {
                return true
            }
            if command.range(
                of: #"://[^/\s:@]+:[^@/\s]+@"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                return true
            }
            return tokens.contains { token in
                let lowered = token.lowercased()
                if lowered.contains("authorization:")
                    || lowered.contains("proxy-authorization:")
                    || lowered.contains("cookie:") {
                    return true
                }

                let assignmentComponents = token.split(
                    separator: "=",
                    omittingEmptySubsequences: false
                )
                for component in assignmentComponents.dropLast() {
                    let name = String(component)
                    if SurfaceResumeCommandCanonicalizer.isSensitiveEnvironmentKey(name)
                        || isSensitiveOptionName(name) {
                        return true
                    }
                }

                guard token.hasPrefix("-") else { return false }
                return isSensitiveOptionName(
                    String(token.prefix { $0 != "=" })
                )
            }
        }

        private static func isSensitiveOptionName(_ rawValue: String) -> Bool {
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .lowercased()
            guard !normalized.isEmpty else { return false }

            let components = normalized
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let sensitiveComponents: Set<String> = [
                "auth",
                "authorization",
                "bearer",
                "cookie",
                "cookies",
                "credential",
                "credentials",
                "key",
                "oauth",
                "passphrase",
                "passwd",
                "password",
                "pwd",
                "secret",
                "sshpass",
                "token",
            ]
            if components.contains(where: sensitiveComponents.contains) {
                return true
            }

            let compact = components.joined()
            let sensitiveCompactNames: Set<String> = [
                "accesstoken",
                "accesskey",
                "apikey",
                "authtoken",
                "bearertoken",
                "clientkey",
                "clientsecret",
                "privatekey",
                "refreshtoken",
                "secretkey",
                "sessiontoken",
                "sshkey",
            ]
            return sensitiveCompactNames.contains(compact)
        }

        private static func isSafeDetectRule(_ rule: CmuxVaultAgentDetectRule) -> Bool {
            let values = [rule.processName].compactMap { $0 }
                + rule.processNames
                + rule.argvContains
                + rule.alternateArgvContains
            return values.count <= maximumDetectValues
                && values.allSatisfy {
                    isSafeString($0, maximumBytes: maximumDetectValueUTF8Bytes)
                }
        }

        private static func isSafeSessionIDSource(
            _ source: CmuxVaultAgentSessionIDSource
        ) -> Bool {
            switch source {
            case .argvOption(let option):
                return isSafeString(
                    option,
                    maximumBytes: maximumDetectValueUTF8Bytes
                )
            case .piSessionFile, .grokSessionDirectory:
                return true
            }
        }

        private static func isSafeOptionalString(
            _ value: String?,
            maximumBytes: Int
        ) -> Bool {
            value.map { isSafeString($0, maximumBytes: maximumBytes) } ?? true
        }

        private static func isSafeString(_ value: String, maximumBytes: Int) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && value.utf8.count <= maximumBytes
                && !value.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0)
                }
        }
    }

    static let maximumSessionIDUTF8Bytes = 8 * 1_024
    static let maximumDisplayNameUTF8Bytes = 512
    static let maximumKindIDUTF8Bytes = 128
    static let maximumWorkingDirectoryUTF8Bytes = 4 * 1_024

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case sessionID
        case displayName
        case resumeWorkingDirectory
        case customAgentDescriptor
        case firstSeenAt
    }

    let id: UUID
    let kind: RestorableAgentKind
    let sessionID: String
    let displayName: String
    /// Directory captured for this conversation's provider-specific resume lookup.
    let resumeWorkingDirectory: String?
    /// Immutable custom resume semantics; never includes captured argv or environment.
    let customAgentDescriptor: CustomAgentDescriptor?
    let firstSeenAt: TimeInterval

    init?(
        id: UUID = UUID(),
        kind: RestorableAgentKind,
        sessionID: String,
        displayName: String? = nil,
        resumeWorkingDirectory: String? = nil,
        customAgentDescriptor: CustomAgentDescriptor? = nil,
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
        if let customAgentDescriptor {
            guard kind.customAgentID == customAgentDescriptor.registration.id else {
                return nil
            }
        }
        self.id = id
        self.kind = kind
        self.sessionID = normalizedSessionID
        self.displayName = resolvedDisplayName
        self.resumeWorkingDirectory = Self.normalizedWorkingDirectory(resumeWorkingDirectory)
        self.customAgentDescriptor = customAgentDescriptor
        self.firstSeenAt = firstSeenAt.isFinite ? firstSeenAt : 0
    }

    /// Copies an already validated conversation under a replacement local identifier.
    init(reidentifying conversation: UniConnectLocalAgentConversation, as id: UUID) {
        self.id = id
        self.kind = conversation.kind
        self.sessionID = conversation.sessionID
        self.displayName = conversation.displayName
        self.resumeWorkingDirectory = conversation.resumeWorkingDirectory
        self.customAgentDescriptor = conversation.customAgentDescriptor
        self.firstSeenAt = conversation.firstSeenAt
    }

    init?(
        id: UUID = UUID(),
        snapshot: SessionRestorableAgentSnapshot,
        firstSeenAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let customAgentDescriptor: CustomAgentDescriptor?
        if let registration = snapshot.registration,
           let customAgentID = snapshot.kind.customAgentID {
            guard registration.id == customAgentID,
                  !CustomAgentDescriptor.containsSensitivePersistenceMaterial(
                      registration
                  ) else {
                // The session identifier may itself have come from the configured
                // credential option, so omit the complete observation rather than
                // retaining a value whose safety cannot be established.
                return nil
            }
            // Registry-owned built-ins may arrive under `.custom`; their stable
            // registration remains available, while their built-in id cannot round-trip
            // as a genuine `.custom` kind.
            if RestorableAgentKind(rawValue: customAgentID)?.customAgentID
                != customAgentID {
                customAgentDescriptor = nil
            } else {
                // A malformed or oversized provider contract cannot safely support
                // durable resume, so fail closed before retaining its session value.
                guard let descriptor = CustomAgentDescriptor(
                    registration: registration
                ) else {
                    return nil
                }
                customAgentDescriptor = descriptor
            }
        } else {
            customAgentDescriptor = nil
        }
        self.init(
            id: id,
            kind: snapshot.kind,
            sessionID: snapshot.sessionId,
            displayName: snapshot.agentDisplayName,
            resumeWorkingDirectory: snapshot.workingDirectory,
            customAgentDescriptor: customAgentDescriptor,
            firstSeenAt: firstSeenAt
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawWorkingDirectory = try container.decodeIfPresent(
            String.self,
            forKey: .resumeWorkingDirectory
        )
        let customAgentDescriptor = try container.decodeIfPresent(
            CustomAgentDescriptor.self,
            forKey: .customAgentDescriptor
        )
        if rawWorkingDirectory != nil,
           Self.normalizedWorkingDirectory(rawWorkingDirectory) == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .resumeWorkingDirectory,
                in: container,
                debugDescription: "Invalid UniConnect local agent resume working directory"
            )
        }
        guard let decoded = UniConnectLocalAgentConversation(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(RestorableAgentKind.self, forKey: .kind),
            sessionID: try container.decode(String.self, forKey: .sessionID),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            resumeWorkingDirectory: rawWorkingDirectory,
            customAgentDescriptor: customAgentDescriptor,
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

    /// Returns this conversation with a validated resume cwd while preserving its identity.
    func assigningResumeWorkingDirectory(
        _ workingDirectory: String
    ) -> UniConnectLocalAgentConversation? {
        guard let normalized = Self.normalizedWorkingDirectory(workingDirectory) else {
            return nil
        }
        return UniConnectLocalAgentConversation(
            id: id,
            kind: kind,
            sessionID: sessionID,
            displayName: displayName,
            resumeWorkingDirectory: normalized,
            customAgentDescriptor: customAgentDescriptor,
            firstSeenAt: firstSeenAt
        )
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
        let customRegistration = customAgentDescriptor?.registration
            ?? kind.customAgentID.flatMap { customAgentID in
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

    private static func normalizedWorkingDirectory(_ value: String?) -> String? {
        guard let value,
              value.utf8.count <= maximumWorkingDirectoryUTF8Bytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        let normalized = (expanded as NSString).standardizingPath
        return normalized.utf8.count <= maximumWorkingDirectoryUTF8Bytes
            ? normalized
            : nil
    }
}
