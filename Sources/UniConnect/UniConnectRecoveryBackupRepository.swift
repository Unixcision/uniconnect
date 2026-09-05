import Darwin
import CryptoKit
import Foundation

/// Owns the rolling, crash-safe session recovery archive under `~/.uniconnect`.
actor UniConnectRecoveryBackupRepository {
    typealias FileWriter = @Sendable (Data, URL, FileManager) throws -> Void

    enum Reason: String, Sendable, CaseIterable {
        case scheduled
        case beforeRestore = "before-restore"
    }

    private struct ArchiveDocument: Codable {
        static let formatName = "uniconnect-recovery-backup"
        static let currentVersion = 1

        let format: String
        let version: Int
        let vaultSHA256: String?
        let snapshot: AppSessionSnapshot
    }

    struct RecoveryPoint: Sendable {
        let snapshot: AppSessionSnapshot
        let encryptedVault: Data?
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
    private let fileWriter: FileWriter

    init(
        rootDirectory: URL = UniConnectRecoveryBackupRepository.defaultRootDirectory(),
        policy: UniConnectRecoveryBackupPolicy = .standard,
        fileManager: FileManager = .default,
        fileWriter: @escaping FileWriter = { data, destination, fileManager in
            try UniConnectAtomicFileWriter.write(
                data,
                to: destination,
                fileManager: fileManager
            )
        }
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.policy = policy
        self.fileManager = fileManager
        self.fileWriter = fileWriter
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
        guard Self.everySSHWorkspaceHasCredentialReference(in: snapshot) else {
            throw UniConnectError.missingCredential
        }
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
            try fileWriter(encryptedVault, vaultURL, fileManager)
            copiedVaultURL = vaultURL
        }

        do {
            let document = ArchiveDocument(
                format: ArchiveDocument.formatName,
                version: ArchiveDocument.currentVersion,
                vaultSHA256: encryptedVault.map(Self.sha256Hex),
                snapshot: SessionPersistenceStore.sanitizedForPersistence(snapshot)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try fileWriter(data, snapshotURL, fileManager)
        } catch {
            let destinationWasCommitted = (error as? UniConnectAtomicFileWriter.WriteError)?
                .destinationWasCommitted == true
            if copiedVaultURL != nil, !destinationWasCommitted {
                try? UniConnectAtomicFileWriter.removeIfPresent(
                    at: vaultURL,
                    fileManager: fileManager
                )
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
        do {
            return try loadRecoveryPoint(from: snapshotURL)?.snapshot
        } catch {
            return nil
        }
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
        try loadRecoveryPoint(from: snapshotURL)?.encryptedVault
    }

    /// Loads a snapshot and its encrypted companion as one hash-bound generation.
    /// Legacy raw snapshots remain readable, but every newly written archive binds
    /// the companion bytes in the readable JSON before either value is returned.
    func loadRecoveryPoint(from snapshotURL: URL) throws -> RecoveryPoint? {
        guard isImmediateArchiveSnapshot(snapshotURL),
              isRegularFileWithoutFollowingSymbolicLinks(snapshotURL) else {
            return nil
        }
        let data = try UniConnectAtomicFileWriter.readPrivateFile(
            at: snapshotURL,
            repairPermissions: true
        )
        let decoder = JSONDecoder()

        if let document = try? decoder.decode(ArchiveDocument.self, from: data) {
            guard document.format == ArchiveDocument.formatName,
                  document.version == ArchiveDocument.currentVersion,
                  isValidSnapshot(document.snapshot),
                  Self.everySSHWorkspaceHasCredentialReference(in: document.snapshot),
                  Self.referencedSSHCredentialIDs(in: document.snapshot).isEmpty
                    || document.vaultSHA256 != nil else {
                return nil
            }
            let encryptedVault: Data?
            if let expectedHash = document.vaultSHA256 {
                guard let vaultURL = encryptedVaultURL(for: snapshotURL) else { return nil }
                let candidate = try UniConnectAtomicFileWriter.readPrivateFile(
                    at: vaultURL,
                    repairPermissions: true
                )
                guard Self.sha256Hex(candidate) == expectedHash else { return nil }
                encryptedVault = candidate
            } else {
                encryptedVault = nil
            }
            return RecoveryPoint(
                snapshot: SessionPersistenceStore.sanitizedForPersistence(document.snapshot),
                encryptedVault: encryptedVault
            )
        }

        // Compatibility for backups written before the hash-bound wrapper.
        guard let legacy = try? decoder.decode(AppSessionSnapshot.self, from: data),
              isValidSnapshot(legacy),
              Self.everySSHWorkspaceHasCredentialReference(in: legacy) else {
            return nil
        }
        let requiredCredentialIDs = Self.referencedSSHCredentialIDs(in: legacy)
        let encryptedVault: Data?
        if let vaultURL = encryptedVaultURL(for: snapshotURL) {
            encryptedVault = try UniConnectAtomicFileWriter.readPrivateFile(
                at: vaultURL,
                repairPermissions: true
            )
        } else {
            guard requiredCredentialIDs.isEmpty else { return nil }
            encryptedVault = nil
        }
        return RecoveryPoint(
            snapshot: SessionPersistenceStore.sanitizedForPersistence(legacy),
            encryptedVault: encryptedVault
        )
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

    /// Rejects a falsely "successful" SSH backup whose JSON cannot name any
    /// encrypted credential record during recovery.
    nonisolated static func everySSHWorkspaceHasCredentialReference(
        in snapshot: AppSessionSnapshot
    ) -> Bool {
        snapshot.windows.allSatisfy { window in
            window.tabManager.workspaces.allSatisfy { workspace in
                workspace.uniConnect?.isSSH != true || workspace.uniConnect?.credentialId != nil
            }
        }
    }

    private func ensureRootDirectory() throws {
        for directory in managedPrivateDirectoryChain() {
            try UniConnectAtomicFileWriter.ensurePrivateDirectory(
                at: directory,
                fileManager: fileManager
            )
        }
    }

    /// Returns only the repository-owned path segment, never broad ancestors such as home or `/tmp`.
    private func managedPrivateDirectoryChain() -> [URL] {
        var chain = [rootDirectory]
        var cursor = rootDirectory

        while cursor.lastPathComponent != ".uniconnect" {
            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            guard parent.path != cursor.path else { return [rootDirectory] }
            cursor = parent
            chain.append(cursor)
        }

        return Array(chain.reversed())
    }

    private func discoveredEntries() throws -> [Entry] {
        guard pathEntryExistsWithoutFollowingSymbolicLinks(rootDirectory) else { return [] }
        for directory in managedPrivateDirectoryChain() {
            try UniConnectAtomicFileWriter.verifyPrivateDirectory(
                at: directory,
                fileManager: fileManager
            )
        }
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { enumeratedSnapshotURL -> Entry? in
            let snapshotFilename = enumeratedSnapshotURL.lastPathComponent
            guard enumeratedSnapshotURL.pathExtension == "json",
                  isRegularFileWithoutFollowingSymbolicLinks(enumeratedSnapshotURL),
                  let parsed = Self.parseSnapshotFilename(snapshotFilename) else {
                return nil
            }
            // FileManager may canonicalize `/var` to `/private/var` while enumerating.
            // Keep repository-facing URLs rooted in the original, already validated
            // directory identity so immediate-child checks remain stable without
            // resolving caller-controlled symlinks.
            let snapshotURL = rootDirectory.appendingPathComponent(
                snapshotFilename,
                isDirectory: false
            )
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
            do {
                // The readable JSON is the pair's commit marker. Its durable
                // absence must be established before the credential companion
                // can be removed, otherwise a failed prune destroys recovery.
                try UniConnectAtomicFileWriter.removeIfPresent(
                    at: entry.snapshotURL,
                    fileManager: fileManager
                )
            } catch {
                continue
            }
            if let encryptedVaultURL = entry.encryptedVaultURL {
                try? UniConnectAtomicFileWriter.removeIfPresent(
                    at: encryptedVaultURL,
                    fileManager: fileManager
                )
            }
        }
        try removeOrphanedVaultCopies()
    }

    private func removeOrphanedVaultCopies() throws {
        guard pathEntryExistsWithoutFollowingSymbolicLinks(rootDirectory) else { return }
        try UniConnectAtomicFileWriter.verifyPrivateDirectory(
            at: rootDirectory,
            fileManager: fileManager
        )
        // A prior unlink may have succeeded but reported an fsync failure. Do not
        // classify any companion as orphaned until the marker directory itself is
        // durably synchronized in this pass.
        try UniConnectAtomicFileWriter.synchronizePrivateDirectory(
            at: rootDirectory,
            fileManager: fileManager
        )
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for vaultURL in urls where vaultURL.lastPathComponent.hasSuffix(".vault.uc") {
            guard isRegularFileWithoutFollowingSymbolicLinks(vaultURL) else { continue }
            let stem = String(vaultURL.lastPathComponent.dropLast(".vault.uc".count))
            let snapshotURL = rootDirectory.appendingPathComponent("\(stem).json")
            if !pathEntryExistsWithoutFollowingSymbolicLinks(snapshotURL) {
                try? UniConnectAtomicFileWriter.removeIfPresent(
                    at: vaultURL,
                    fileManager: fileManager
                )
            }
        }
    }

    /// Treats any inode (including a symlink) as present. Cleanup is intentionally
    /// conservative: only `ENOENT` proves a companion has no possible marker.
    private func pathEntryExistsWithoutFollowingSymbolicLinks(_ url: URL) -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return true }
        return errno != ENOENT
    }

    private func isRegularFileWithoutFollowingSymbolicLinks(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isValidSnapshot(_ snapshot: AppSessionSnapshot) -> Bool {
        snapshot.version == SessionSnapshotSchema.currentVersion && !snapshot.windows.isEmpty
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
            let suffix = tail.dropFirst(Reason.beforeRestore.rawValue.count + 1)
            guard UUID(uuidString: String(suffix)) != nil else { return nil }
        } else if tail.hasPrefix(Reason.scheduled.rawValue + "-") {
            reason = .scheduled
            let suffix = tail.dropFirst(Reason.scheduled.rawValue.count + 1)
            guard UUID(uuidString: String(suffix)) != nil else { return nil }
        } else {
            return nil
        }
        return (Date(timeIntervalSince1970: TimeInterval(millis) / 1_000), reason)
    }

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
