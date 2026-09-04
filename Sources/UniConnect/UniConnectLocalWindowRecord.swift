import Foundation

/// Persistent identity and append-only agent history for one local terminal window.
struct UniConnectLocalWindowRecord: Codable, Equatable, Identifiable, Sendable {
    static let maximumVisibleNameUTF8Bytes = 512
    static let maximumBoxRootUTF8Bytes = 4 * 1_024
    static let maximumWorkingDirectoryUTF8Bytes = 4 * 1_024

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case visibleName
        case boxRoot
        case workingDirectory
        case runtimeState
        case conversations
        case latestConversationID
        case activeConversationID
        case createdAt
        case updatedAt
    }

    private(set) var version: Int
    let id: UUID
    private(set) var visibleName: String?
    private(set) var boxRoot: String
    private(set) var workingDirectory: String
    private(set) var runtimeState: UniConnectLocalWindowRuntimeState
    private(set) var conversations: [UniConnectLocalAgentConversation]
    private(set) var latestConversationID: UUID?
    private(set) var activeConversationID: UUID?
    let createdAt: TimeInterval
    private(set) var updatedAt: TimeInterval

    static let currentVersion = 2

    init(
        id: UUID = UUID(),
        visibleName: String? = nil,
        boxRoot: String,
        workingDirectory: String? = nil,
        runtimeState: UniConnectLocalWindowRuntimeState = .shell,
        conversations: [UniConnectLocalAgentConversation] = [],
        latestConversationID: UUID? = nil,
        activeConversationID: UUID? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval? = nil
    ) {
        self.version = Self.currentVersion
        self.id = id
        self.visibleName = Self.normalizedVisibleName(visibleName)
        self.boxRoot = Self.normalizedRoot(boxRoot)
        self.workingDirectory = Self.validatedWorkingDirectory(
            workingDirectory ?? self.boxRoot,
            within: self.boxRoot
        ) ?? self.boxRoot
        self.runtimeState = runtimeState
        self.conversations = Self.uniqueConversations(conversations)
        self.latestConversationID = latestConversationID
        self.activeConversationID = activeConversationID
        self.createdAt = createdAt.isFinite ? createdAt : 0
        self.updatedAt = (updatedAt ?? createdAt).isFinite ? (updatedAt ?? createdAt) : 0
        repairReferences()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard decodedVersion >= 1, decodedVersion <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported UniConnect local-window version \(decodedVersion)"
            )
        }
        let decodedCreatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
        self.version = Self.currentVersion
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedVisibleName = try container.decodeIfPresent(String.self, forKey: .visibleName)
        guard Self.isAcceptableVisibleName(decodedVisibleName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .visibleName,
                in: container,
                debugDescription: "UniConnect local-window name is oversized or contains control characters"
            )
        }
        self.visibleName = Self.normalizedVisibleName(decodedVisibleName)
        let decodedBoxRoot = try container.decodeIfPresent(String.self, forKey: .boxRoot) ?? "~"
        guard let validatedBoxRoot = Self.validatedBoxRoot(decodedBoxRoot) else {
            throw DecodingError.dataCorruptedError(
                forKey: .boxRoot,
                in: container,
                debugDescription: "UniConnect local-window root must be an absolute, bounded path without control characters"
            )
        }
        self.boxRoot = validatedBoxRoot
        let decodedWorkingDirectory = try container.decodeIfPresent(
            String.self,
            forKey: .workingDirectory
        ) ?? validatedBoxRoot
        guard let validatedWorkingDirectory = Self.validatedWorkingDirectory(
            decodedWorkingDirectory,
            within: validatedBoxRoot
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .workingDirectory,
                in: container,
                debugDescription: "UniConnect local-window cwd must be an absolute, bounded path inside its box root"
            )
        }
        self.workingDirectory = validatedWorkingDirectory
        self.runtimeState = try container.decodeIfPresent(
            UniConnectLocalWindowRuntimeState.self,
            forKey: .runtimeState
        ) ?? .shell
        self.conversations = Self.uniqueConversations(
            try container.decodeIfPresent(
                [UniConnectLocalAgentConversation].self,
                forKey: .conversations
            ) ?? []
        )
        self.latestConversationID = try container.decodeIfPresent(UUID.self, forKey: .latestConversationID)
        self.activeConversationID = try container.decodeIfPresent(UUID.self, forKey: .activeConversationID)
        self.createdAt = decodedCreatedAt.isFinite ? decodedCreatedAt : 0
        let decodedUpdatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt)
            ?? self.createdAt
        self.updatedAt = decodedUpdatedAt.isFinite ? decodedUpdatedAt : self.createdAt
        repairReferences()
    }

    var latestConversation: UniConnectLocalAgentConversation? {
        conversation(id: latestConversationID)
    }

    var activeConversation: UniConnectLocalAgentConversation? {
        conversation(id: activeConversationID)
    }

    var legacyClaudeSession: String? {
        guard latestConversation?.kind == .claude else { return nil }
        return latestConversation?.sessionID
    }

    func latestRestorableSnapshot(
        registry: CmuxVaultAgentRegistry
    ) -> SessionRestorableAgentSnapshot? {
        latestConversation?.restorableSnapshot(
            workingDirectory: workingDirectory,
            registry: registry
        )
    }

    func restorableSnapshot(
        for conversationID: UUID,
        registry: CmuxVaultAgentRegistry,
        workingDirectory overrideWorkingDirectory: String? = nil
    ) -> SessionRestorableAgentSnapshot? {
        conversation(id: conversationID)?.restorableSnapshot(
            workingDirectory: overrideWorkingDirectory ?? workingDirectory,
            registry: registry
        )
    }

    @discardableResult
    mutating func reconcileIdentity(
        visibleName: String?,
        boxRoot: String,
        workingDirectory: String? = nil,
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        let normalizedName = Self.normalizedVisibleName(visibleName)
        let normalizedBoxRoot = Self.validatedBoxRoot(boxRoot) ?? self.boxRoot
        let normalizedWorkingDirectory = Self.validatedWorkingDirectory(
            workingDirectory ?? self.workingDirectory,
            within: normalizedBoxRoot
        ) ?? normalizedBoxRoot
        guard self.visibleName != normalizedName
                || self.boxRoot != normalizedBoxRoot
                || self.workingDirectory != normalizedWorkingDirectory else {
            return false
        }
        self.visibleName = normalizedName
        self.boxRoot = normalizedBoxRoot
        self.workingDirectory = normalizedWorkingDirectory
        touch(timestamp)
        return true
    }

    /// Updates this window's cwd without changing the box-wide trust boundary.
    @discardableResult
    mutating func reconcileWorkingDirectory(
        _ value: String,
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let normalized = Self.validatedWorkingDirectory(value, within: boxRoot),
              normalized != workingDirectory else {
            return false
        }
        workingDirectory = normalized
        touch(timestamp)
        return true
    }

    /// Applies imported runtime selection while retaining conversations known only locally.
    @discardableResult
    mutating func mergeImportedStatePreservingHistory(
        _ imported: UniConnectLocalWindowRecord,
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        let original = self
        conversations = Self.uniqueConversations(conversations + imported.conversations)

        func mergedID(for importedID: UUID?) -> UUID? {
            guard let importedID,
                  let importedConversation = imported.conversations.first(where: {
                      $0.id == importedID
                  }) else {
                return nil
            }
            return conversations.first(where: {
                $0.identityKey == importedConversation.identityKey
            })?.id
        }

        if !imported.conversations.isEmpty {
            latestConversationID = mergedID(for: imported.latestConversationID)
                ?? conversations.last?.id
        }
        runtimeState = imported.runtimeState
        activeConversationID = runtimeState == .agent
            ? (mergedID(for: imported.activeConversationID) ?? latestConversationID)
            : nil
        repairReferences()
        touch(max(timestamp, imported.updatedAt))
        return self != original
    }

    /// Records a newly observed conversation without removing any prior conversation.
    @discardableResult
    mutating func record(
        _ snapshot: SessionRestorableAgentSnapshot,
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let candidate = UniConnectLocalAgentConversation(
            snapshot: snapshot,
            firstSeenAt: timestamp
        ) else {
            return false
        }
        let conversation: UniConnectLocalAgentConversation
        let inserted: Bool
        if let existing = conversations.first(where: { $0.identityKey == candidate.identityKey }) {
            conversation = existing
            inserted = false
        } else {
            conversations.append(candidate)
            conversation = candidate
            inserted = true
        }
        let changed = latestConversationID != conversation.id
            || activeConversationID != conversation.id
            || runtimeState != .agent
            || inserted
        latestConversationID = conversation.id
        activeConversationID = conversation.id
        runtimeState = .agent
        if changed { touch(timestamp) }
        return changed
    }

    /// Retains a discovered conversation for manual recovery without claiming it as live.
    @discardableResult
    mutating func rememberForManualRecovery(
        _ snapshot: SessionRestorableAgentSnapshot,
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let candidate = UniConnectLocalAgentConversation(
            snapshot: snapshot,
            firstSeenAt: timestamp
        ) else {
            return false
        }
        let conversation: UniConnectLocalAgentConversation
        let inserted: Bool
        if let existing = conversations.first(where: { $0.identityKey == candidate.identityKey }) {
            conversation = existing
            inserted = false
        } else {
            conversations.append(candidate)
            conversation = candidate
            inserted = true
        }
        let changed = latestConversationID != conversation.id
            || activeConversationID != nil
            || runtimeState != .shell
            || inserted
        latestConversationID = conversation.id
        activeConversationID = nil
        runtimeState = .shell
        if changed { touch(timestamp) }
        return changed
    }

    /// Returns to the login shell while retaining the complete resumable history.
    @discardableResult
    mutating func transitionToShell(
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard runtimeState != .shell || activeConversationID != nil else { return false }
        runtimeState = .shell
        activeConversationID = nil
        touch(timestamp)
        return true
    }

    /// Marks the terminal child as exited without discarding the logical window or history.
    @discardableResult
    mutating func markStopped(
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard runtimeState != .stopped || activeConversationID != nil else { return false }
        runtimeState = .stopped
        activeConversationID = nil
        touch(timestamp)
        return true
    }

    /// Chooses an existing history entry for the next resume without starting it implicitly.
    @discardableResult
    mutating func selectLatestConversation(
        id conversationID: UUID,
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard conversation(id: conversationID) != nil else { return false }
        guard latestConversationID != conversationID
                || activeConversationID != nil
                || runtimeState != .shell else {
            return false
        }
        latestConversationID = conversationID
        activeConversationID = nil
        runtimeState = .shell
        touch(timestamp)
        return true
    }

    /// Explicitly forgets one conversation reference; no runtime transition calls this implicitly.
    @discardableResult
    mutating func forgetConversation(
        id conversationID: UUID,
        at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return false
        }
        conversations.remove(at: index)
        if activeConversationID == conversationID {
            activeConversationID = nil
            runtimeState = .shell
        }
        if latestConversationID == conversationID {
            latestConversationID = conversations.last?.id
        }
        repairReferences()
        touch(timestamp)
        return true
    }

    static func migratingLegacy(
        id: UUID = UUID(),
        visibleName: String?,
        boxRoot: String,
        workingDirectory: String? = nil,
        agent: SessionRestorableAgentSnapshot?,
        claudeSession: String?,
        wasAgentRunning: Bool?,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> UniConnectLocalWindowRecord {
        var record = UniConnectLocalWindowRecord(
            id: id,
            visibleName: visibleName,
            boxRoot: boxRoot,
            workingDirectory: workingDirectory ?? agent?.workingDirectory,
            runtimeState: .shell,
            createdAt: timestamp
        )
        let legacySnapshot: SessionRestorableAgentSnapshot? = {
            if let agent { return agent }
            guard let rawClaudeSession = claudeSession,
                  let validatedClaudeSession = UniConnectLocalAgentConversation(
                      kind: .claude,
                      sessionID: rawClaudeSession
                  ) else {
                return nil
            }
            return SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: validatedClaudeSession.sessionID,
                workingDirectory: record.workingDirectory,
                launchCommand: nil
            )
        }()
        if let legacySnapshot {
            _ = record.record(legacySnapshot, at: timestamp)
            if wasAgentRunning == false {
                _ = record.transitionToShell(at: timestamp)
            }
        }
        return record
    }

    private func conversation(id: UUID?) -> UniConnectLocalAgentConversation? {
        guard let id else { return nil }
        return conversations.first { $0.id == id }
    }

    private mutating func repairReferences() {
        if conversation(id: latestConversationID) == nil {
            latestConversationID = conversations.last?.id
        }
        if runtimeState != .agent || conversation(id: activeConversationID) == nil {
            activeConversationID = nil
        }
        if runtimeState == .agent, activeConversationID == nil {
            activeConversationID = latestConversationID
        }
        if runtimeState == .agent, activeConversationID == nil {
            runtimeState = .shell
        }
    }

    private mutating func touch(_ timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        updatedAt = max(updatedAt, timestamp)
    }

    private static func uniqueConversations(
        _ conversations: [UniConnectLocalAgentConversation]
    ) -> [UniConnectLocalAgentConversation] {
        var seen: Set<String> = []
        return conversations.filter { seen.insert($0.identityKey).inserted }
    }

    private static func normalizedVisibleName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty,
              isAcceptableVisibleName(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func normalizedRoot(_ value: String) -> String {
        validatedBoxRoot(value)
            ?? (("~" as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    static func validatedBoxRoot(_ value: String) -> String? {
        guard isAcceptableBoxRoot(value) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath,
              isAcceptableBoxRoot(expanded) else {
            return nil
        }
        return (expanded as NSString).standardizingPath
    }

    static func validatedWorkingDirectory(_ value: String, within boxRoot: String) -> String? {
        guard value.utf8.count <= maximumWorkingDirectoryUTF8Bytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              let normalizedRoot = validatedBoxRoot(boxRoot) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        let normalized = (expanded as NSString).standardizingPath
        guard normalized.utf8.count <= maximumWorkingDirectoryUTF8Bytes,
              containsPath(normalized, root: normalizedRoot) else {
            return nil
        }

        // `URL.resolvingSymlinksInPath()` does not resolve an existing symlink when
        // a later path component is missing. Resolve every prefix independently so
        // `/box/link-to-outside/not-created-yet` cannot pass containment validation
        // and become an escape once its final directory appears.
        let resolvedRoot = resolvingExistingSymbolicLinkPrefixes(in: normalizedRoot)
        let resolved = resolvingExistingSymbolicLinkPrefixes(in: normalized)
        guard containsPath(resolved, root: resolvedRoot) else { return nil }
        return normalized
    }

    private static func resolvingExistingSymbolicLinkPrefixes(in path: String) -> String {
        let components = URL(fileURLWithPath: path, isDirectory: true).pathComponents
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            resolved.appendPathComponent(component, isDirectory: true)
            resolved = resolved.resolvingSymlinksInPath().standardizedFileURL
        }
        return resolved.path
    }

    private static func containsPath(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    private static func isAcceptableVisibleName(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maximumVisibleNameUTF8Bytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isAcceptableBoxRoot(_ value: String) -> Bool {
        value.utf8.count <= maximumBoxRootUTF8Bytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
