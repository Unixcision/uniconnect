import Foundation

/// Owns the rolling, crash-safe session recovery archive under `~/.uniconnect`.
actor UniConnectRecoveryBackupRepository {
    enum Reason: String, Sendable, CaseIterable {
        case scheduled
        case beforeRestore = "before-restore"
    }

    struct Entry: Identifiable, Sendable, Equatable {
        let snapshotURL: URL
        let encryptedVaultURL: URL?
        let createdAt: Date
        let reason: Reason

        var id: URL { snapshotURL }
    }

    private let rootDirectory: URL
    private let policy: UniConnectRecoveryBackupPolicy
    private let fileManager: FileManager

    init(
        rootDirectory: URL = UniConnectRecoveryBackupRepository.defaultRootDirectory(),
        policy: UniConnectRecoveryBackupPolicy = .standard,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.policy = policy
        self.fileManager = fileManager
    }

    static func defaultRootDirectory(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = homeDirectory
            .appendingPathComponent(".uniconnect", isDirectory: true)
#if DEBUG
        let rawIdentifier = bundleIdentifier ?? "debug"
        let safeIdentifier = rawIdentifier.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return base
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent(safeIdentifier, isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
#else
        return base.appendingPathComponent("backups", isDirectory: true)
#endif
    }

    @discardableResult
    func archiveIfDue(
        snapshot: AppSessionSnapshot,
        encryptedVault: Data?,
        now: Date = Date()
    ) throws -> Entry? {
        let current = try discoveredEntries()
        let lastScheduledAt = current
            // A wall-clock correction must not let a future-dated archive suppress
            // all automatic backups until that timestamp is reached again.
            .filter { $0.reason == .scheduled && $0.createdAt <= now }
            .map(\.createdAt)
            .max()
        guard policy.isScheduledBackupDue(lastScheduledAt: lastScheduledAt, now: now) else {
            try prune(entries: current, now: now)
            return nil
        }
        return try archive(
            snapshot: snapshot,
            encryptedVault: encryptedVault,
            reason: .scheduled,
            now: now
        )
    }

    @discardableResult
    func archive(
        snapshot: AppSessionSnapshot,
        encryptedVault: Data?,
        reason: Reason,
        now: Date = Date()
    ) throws -> Entry {
        let requiredCredentialIDs = Self.referencedSSHCredentialIDs(in: snapshot)
        guard requiredCredentialIDs.isEmpty || encryptedVault != nil else {
            throw UniConnectError.missingCredential
        }
        try ensureRootDirectory()
        let millis = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let stem = "session-\(millis)-\(reason.rawValue)-\(UUID().uuidString.lowercased())"
        let snapshotURL = rootDirectory.appendingPathComponent("\(stem).json", isDirectory: false)
        let vaultURL = rootDirectory.appendingPathComponent("\(stem).vault.uc", isDirectory: false)

        var copiedVaultURL: URL?
        if let encryptedVault {
            try UniConnectAtomicFileWriter.write(encryptedVault, to: vaultURL, fileManager: fileManager)
            copiedVaultURL = vaultURL
        }

        do {
            let data = try SessionPersistenceStore.encodedSnapshotDataForPersistence(snapshot)
            try UniConnectAtomicFileWriter.write(data, to: snapshotURL, fileManager: fileManager)
        } catch {
            if copiedVaultURL != nil {
                try? fileManager.removeItem(at: vaultURL)
            }
            throw error
        }

        let entry = Entry(
            snapshotURL: snapshotURL,
            encryptedVaultURL: copiedVaultURL,
            createdAt: now,
            reason: reason
        )
        try prune(entries: try discoveredEntries(), now: now)
        return entry
    }

    func availableBackups(now: Date = Date()) throws -> [Entry] {
        let entries = try discoveredEntries()
        try prune(entries: entries, now: now)
        return try discoveredEntries()
            .sorted { $0.createdAt > $1.createdAt }
    }

    func loadSnapshot(from snapshotURL: URL) -> AppSessionSnapshot? {
        guard isImmediateArchiveSnapshot(snapshotURL),
              isRegularFileWithoutFollowingSymbolicLinks(snapshotURL) else {
            return nil
        }
        return SessionPersistenceStore.load(fileURL: snapshotURL)
    }

    func encryptedVaultURL(for snapshotURL: URL) -> URL? {
        guard isImmediateArchiveSnapshot(snapshotURL),
              isRegularFileWithoutFollowingSymbolicLinks(snapshotURL) else { return nil }
        let stem = snapshotURL.deletingPathExtension().lastPathComponent
        let candidate = rootDirectory.appendingPathComponent("\(stem).vault.uc")
        return isRegularFileWithoutFollowingSymbolicLinks(candidate) ? candidate : nil
    }

    /// Reads the exact encrypted companion bytes belonging to one discovered snapshot.
    func loadEncryptedVault(for snapshotURL: URL) throws -> Data? {
        guard let url = encryptedVaultURL(for: snapshotURL) else { return nil }
        return try UniConnectAtomicFileWriter.readPrivateFile(at: url, repairPermissions: true)
    }

    /// Returns every opaque SSH credential reference that must exist in the companion vault.
    nonisolated static func referencedSSHCredentialIDs(
        in snapshot: AppSessionSnapshot
    ) -> Set<UUID> {
        Set(snapshot.windows.flatMap { window in
            window.tabManager.workspaces.compactMap { workspace in
                guard workspace.uniConnect?.isSSH == true else { return nil }
                return workspace.uniConnect?.credentialId
            }
        })
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: rootDirectory.path
        )
    }

    private func discoveredEntries() throws -> [Entry] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { snapshotURL -> Entry? in
            guard snapshotURL.pathExtension == "json",
                  isRegularFileWithoutFollowingSymbolicLinks(snapshotURL),
                  let parsed = Self.parseSnapshotFilename(snapshotURL.lastPathComponent) else {
                return nil
            }
            let stem = snapshotURL.deletingPathExtension().lastPathComponent
            let possibleVault = rootDirectory.appendingPathComponent("\(stem).vault.uc")
            let encryptedVaultURL = isRegularFileWithoutFollowingSymbolicLinks(possibleVault)
                ? possibleVault
                : nil
            return Entry(
                snapshotURL: snapshotURL,
                encryptedVaultURL: encryptedVaultURL,
                createdAt: parsed.date,
                reason: parsed.reason
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func prune(entries: [Entry], now: Date) throws {
        let sorted = entries.sorted { $0.createdAt > $1.createdAt }
        let scheduled = sorted.filter { $0.reason == .scheduled }
        let beforeRestore = sorted.filter { $0.reason == .beforeRestore }
        let keptScheduled = policy.retainedIndices(
            for: scheduled.map(\.createdAt),
            now: now
        )
        let keptBeforeRestore = policy.retainedBeforeRestoreIndices(
            for: beforeRestore.map(\.createdAt),
            now: now
        )
        let keptURLs = Set(
            scheduled.enumerated().compactMap { index, entry in
                keptScheduled.contains(index) ? entry.snapshotURL : nil
            } + beforeRestore.enumerated().compactMap { index, entry in
                keptBeforeRestore.contains(index) ? entry.snapshotURL : nil
            }
        )

        for entry in sorted where !keptURLs.contains(entry.snapshotURL) {
            try? fileManager.removeItem(at: entry.snapshotURL)
            if let encryptedVaultURL = entry.encryptedVaultURL {
                try? fileManager.removeItem(at: encryptedVaultURL)
            }
        }
        try removeOrphanedVaultCopies()
    }

    private func removeOrphanedVaultCopies() throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for vaultURL in urls where vaultURL.lastPathComponent.hasSuffix(".vault.uc") {
            guard isRegularFileWithoutFollowingSymbolicLinks(vaultURL) else { continue }
            let stem = String(vaultURL.lastPathComponent.dropLast(".vault.uc".count))
            let snapshotURL = rootDirectory.appendingPathComponent("\(stem).json")
            if !fileManager.fileExists(atPath: snapshotURL.path) {
                try? fileManager.removeItem(at: vaultURL)
            }
        }
    }

    private func isRegularFileWithoutFollowingSymbolicLinks(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    /// Backups are flat by design. Requiring an immediate child also prevents a
    /// caller-selected `backups/link-to-outside/file.json` from escaping through a
    /// symbolic-link directory while still passing a lexical prefix check.
    private func isImmediateArchiveSnapshot(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.pathExtension == "json",
              url.deletingLastPathComponent().path == rootDirectory.path,
              Self.parseSnapshotFilename(url.lastPathComponent) != nil else {
            return false
        }
        return true
    }

    private static func parseSnapshotFilename(_ filename: String) -> (date: Date, reason: Reason)? {
        guard filename.hasPrefix("session-"), filename.hasSuffix(".json") else { return nil }
        let body = filename.dropFirst("session-".count).dropLast(".json".count)
        guard let firstDash = body.firstIndex(of: "-"),
              let millis = Int64(body[..<firstDash]) else {
            return nil
        }
        let tail = body[body.index(after: firstDash)...]
        let reason: Reason
        if tail.hasPrefix(Reason.beforeRestore.rawValue + "-") {
            reason = .beforeRestore
        } else if tail.hasPrefix(Reason.scheduled.rawValue + "-") {
            reason = .scheduled
        } else {
            return nil
        }
        return (Date(timeIntervalSince1970: TimeInterval(millis) / 1_000), reason)
    }
}
