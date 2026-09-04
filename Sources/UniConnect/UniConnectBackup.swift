import Foundation
import AppKit
import CryptoKit

// MARK: - Export container
//
// Layout on disk (JSON):
// {
//   "format": "uniconnect-export", "version": 1,
//   "meta": { "app": "UniConnect", "savedAt": "...", "workspaces": 12 },   <- readable, no secrets
//   "payload": { ...AES-256-GCM envelope, PBKDF2-SHA256 key... }         <- the document
// }

struct UniConnectExportContainer: Codable {
    struct Meta: Codable {
        var app: String
        var savedAt: String
        var workspaces: Int
        var hostName: String?
    }

    var format: String
    var version: Int
    var meta: Meta
    var payload: UniConnectCrypto.Envelope

    static let formatName = "uniconnect-export"
}

@MainActor
enum UniConnectBackup {
    /// Readable commit marker whose optional companion contains only encrypted credentials.
    struct LocalBackupManifest: Codable, Equatable {
        static let formatName = "uniconnect-local-backup"
        static let currentVersion = 1
        static let backupPurpose = "manual-backup"
        static let startupSeedPurpose = "startup-seed"

        var format: String
        var version: Int
        var purpose: String?
        var vaultFile: String?
        var vaultSHA256: String?
        var document: UniConnectDocument
    }

    // MARK: Build the readable document from live state

    static func buildDocument(
        tabManagers: [TabManager],
        reconcileLiveState: Bool = true
    ) -> UniConnectDocument {
        let agentIndex = RestorableAgentSessionIndex.load()
        var workspaces: [UniConnectDocument.Workspace] = []
        for tabManager in tabManagers {
            let groupNames = Dictionary(uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0.name) })
            for workspace in tabManager.tabs where !workspace.uniConnectShowsStarter {
                workspaces.append(documentWorkspace(
                    workspace,
                    groupNames: groupNames,
                    agentIndex: agentIndex,
                    reconcileLiveState: reconcileLiveState
                ))
            }
        }
        return UniConnectDocument(workspaces: workspaces)
    }

    static func documentWorkspace(
        _ workspace: Workspace,
        groupNames: [UUID: String],
        agentIndex: RestorableAgentSessionIndex,
        reconcileLiveState: Bool = true
    ) -> UniConnectDocument.Workspace {
        let profile = workspace.uniConnectProfile ?? .local
        let connect = profile.credentialId.flatMap { UniConnectVault.shared.connectCommand(for: $0) }
        var windows: [UniConnectDocument.Window] = []
        for panelId in workspace.uniConnectOrderedTerminalPanelIds() {
            let name = workspace.panelCustomTitles[panelId] ?? workspace.panelTitles[panelId]
            let tmux = workspace.uniConnectTmuxSessionsByPanelId[panelId]
            let detectedAgent = agentIndex.snapshot(workspaceId: workspace.id, panelId: panelId)
            if reconcileLiveState, let detectedAgent, !profile.isSSH {
                _ = workspace.uniConnectRecordLocalAgent(
                    panelId: panelId,
                    snapshot: detectedAgent
                )
            }
            let localWindow: UniConnectLocalWindowRecord?
            if profile.isSSH {
                localWindow = nil
            } else if reconcileLiveState {
                localWindow = workspace.uniConnectEnsureLocalWindowRecord(
                    panelId: panelId,
                    visibleName: name
                )
            } else {
                localWindow = projectedLocalWindow(
                    panelID: panelId,
                    name: name,
                    profile: profile,
                    workspace: workspace,
                    detectedAgent: detectedAgent
                )
            }
            let claude = localWindow?.legacyClaudeSession
                ?? detectedAgent.flatMap { $0.kind == .claude ? $0.sessionId : nil }
                ?? workspace.uniConnectClaudeSessionsByPanelId[panelId]
            let cwd = localWindow?.workingDirectory
                ?? workspace.panelDirectories[panelId]
                ?? (workspace.panels[panelId] as? TerminalPanel)?.requestedWorkingDirectory
            windows.append(UniConnectDocument.Window(
                name: name,
                tmux: tmux,
                claudeSession: claude,
                cwd: profile.isSSH ? nil : cwd,
                isPinned: workspace.isPanelPinned(panelId) ? true : nil,
                localWindow: localWindow
            ))
        }
        return UniConnectDocument.Workspace(
            id: profile.importIdentity,
            name: workspace.customTitle ?? workspace.title,
            kind: profile.kind,
            color: workspace.customColor,
            group: workspace.groupId.flatMap { groupNames[$0] },
            isPinned: workspace.isPinned ? true : nil,
            cwd: profile.isSSH ? nil : (profile.localRoot ?? workspace.currentDirectory),
            connect: connect,
            credentialId: profile.isSSH ? profile.credentialId : nil,
            windows: windows
        )
    }

    /// Produces the same local-window value as persistence without mutating the workspace.
    private static func projectedLocalWindow(
        panelID: UUID,
        name: String?,
        profile: UniConnectWorkspaceProfile,
        workspace: Workspace,
        detectedAgent: SessionRestorableAgentSnapshot?
    ) -> UniConnectLocalWindowRecord? {
        guard let root = workspace.uniConnectLocalBoxRoot else { return nil }
        let reportedWorkingDirectory = workspace.panelDirectories[panelID]
            ?? detectedAgent?.workingDirectory
            ?? (workspace.panels[panelID] as? TerminalPanel)?.requestedWorkingDirectory
        let workingDirectory = reportedWorkingDirectory.flatMap {
            UniConnectLocalWindowRecord.validatedWorkingDirectory($0, within: root)
        }
            ?? workspace.uniConnectLocalWindowsByPanelId[panelID]?.workingDirectory
            ?? root
        var record = workspace.uniConnectLocalWindowsByPanelId[panelID]
            ?? UniConnectLocalWindowRecord(
                id: panelID,
                visibleName: name,
                boxRoot: root,
                workingDirectory: workingDirectory,
                createdAt: profile.createdAt ?? 0,
                updatedAt: profile.createdAt ?? 0
            )
        let observationTime = detectedAgent?.launchCommand?.capturedAt ?? record.updatedAt
        _ = record.reconcileIdentity(
            visibleName: name,
            boxRoot: root,
            workingDirectory: workingDirectory,
            at: observationTime
        )
        if let detectedAgent {
            _ = record.record(detectedAgent, at: observationTime)
        }
        return record
    }

    // MARK: Readable local backup + encrypted credential companion ("Persistir ahora")

    @discardableResult
    static func persistNow(
        tabManagers: [TabManager],
        reconcileLiveState: Bool = true
    ) throws -> URL {
        let document = buildDocument(
            tabManagers: tabManagers,
            reconcileLiveState: reconcileLiveState
        )
        let credentialIDs = referencedCredentialIDs(in: document)
        let encryptedVault = try UniConnectVault.shared.encryptedSnapshot(
            requiring: credentialIDs
        )
        return try persistLocalBackup(
            document: document,
            encryptedVault: encryptedVault,
            to: UniConnectPaths.backupFile,
            historyDirectory: UniConnectPaths.backupHistoryDirectory,
            vault: .shared
        )
    }

    static func readLocalBackup() throws -> UniConnectDocument {
        try readLocalBackup(
            readableURL: UniConnectPaths.backupFile,
            legacyURL: UniConnectPaths.legacyBackupFile,
            historyDirectory: UniConnectPaths.backupHistoryDirectory,
            vault: .shared,
            legacyKey: UniConnectMasterKey.load()
        )
    }

    /// Writes a coherent pair for tests and the production manual-backup flow.
    ///
    /// The encrypted immutable companion is made durable first. The readable JSON is
    /// then atomically renamed into place as the commit marker, so a crash can expose
    /// either the complete old generation or the complete new generation, never a mix.
    @discardableResult
    static func persistLocalBackup(
        document: UniConnectDocument,
        encryptedVault: Data?,
        to target: URL,
        historyDirectory: URL,
        vault: UniConnectVault,
        now: Date = Date()
    ) throws -> URL {
        let readableDocument = try sanitizedReadableDocument(
            document,
            encryptedVault: encryptedVault,
            vault: vault
        )
        let targetStem = target.deletingPathExtension().lastPathComponent
        let primaryVaultName = encryptedVault.map { _ in
            "\(targetStem)-\(UUID().uuidString.lowercased()).vault.uc"
        }
        try writeReadableBackup(
            document: readableDocument,
            encryptedVault: encryptedVault,
            to: target,
            vaultFileName: primaryVaultName
        )
        removeObsoletePrimaryVaultCopies(
            beside: target,
            keeping: primaryVaultName
        )

        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let historyStem = "backup-\(stamp)-\(UUID().uuidString.lowercased())"
        let historyURL = historyDirectory.appendingPathComponent("\(historyStem).json")
        let historyVaultName = encryptedVault.map { _ in "\(historyStem).vault.uc" }
        try writeReadableBackup(
            document: readableDocument,
            encryptedVault: encryptedVault,
            to: historyURL,
            vaultFileName: historyVaultName
        )
        pruneHistory(
            at: historyDirectory,
            keep: 28,
            maximumAge: 7 * 24 * 60 * 60,
            now: now
        )
        return target
    }

    /// Reads the split format, or migrates a legacy whole-document ciphertext in place.
    static func readLocalBackup(
        readableURL: URL,
        legacyURL: URL,
        historyDirectory: URL,
        vault: UniConnectVault,
        now: Date = Date(),
        legacyKey: SymmetricKey
    ) throws -> UniConnectDocument {
        if FileManager.default.fileExists(atPath: readableURL.path) {
            return try readReadableBackup(at: readableURL, vault: vault)
        }

        let data = try UniConnectAtomicFileWriter.readPrivateFile(
            at: legacyURL,
            repairPermissions: true
        )
        let envelope = try UniConnectCrypto.parseEnvelope(data)
        let plaintext = try UniConnectCrypto.open(envelope, key: legacyKey)
        let legacyDocument = try JSONDecoder().decode(UniConnectDocument.self, from: plaintext)

        // Migration is best effort and deliberately leaves the authenticated legacy
        // ciphertext untouched. If the new pair cannot be verified, the old recovery
        // source remains usable rather than turning a format upgrade into data loss.
        do {
            let migration = try migratedLegacyBackup(
                document: legacyDocument,
                vault: vault
            )
            _ = try persistLocalBackup(
                document: migration.document,
                encryptedVault: migration.encryptedVault,
                to: readableURL,
                historyDirectory: historyDirectory,
                vault: vault,
                now: now
            )
            return try readReadableBackup(at: readableURL, vault: vault)
        } catch {
            removeReadableBackupPair(at: readableURL)
            removeObsoletePrimaryVaultCopies(beside: readableURL, keeping: nil)
            NSLog("[UniConnect] legacy backup migration deferred: \(error)")
            return legacyDocument
        }
    }

    static func readReadableBackup(
        at url: URL,
        vault: UniConnectVault
    ) throws -> UniConnectDocument {
        let data = try UniConnectAtomicFileWriter.readPrivateFile(
            at: url,
            repairPermissions: true
        )
        let manifest = try JSONDecoder().decode(LocalBackupManifest.self, from: data)
        guard manifest.format == LocalBackupManifest.formatName,
              manifest.version == LocalBackupManifest.currentVersion,
              manifest.purpose == LocalBackupManifest.backupPurpose
                || manifest.purpose == LocalBackupManifest.startupSeedPurpose,
              (manifest.vaultFile == nil) == (manifest.vaultSHA256 == nil),
              manifest.document.workspaces.allSatisfy({ $0.connect == nil }) else {
            throw unrecognizedLocalBackupError()
        }
        try validateVersion(manifest.document)

        let encryptedVault: Data?
        if let vaultFile = manifest.vaultFile {
            guard isSafeCompanionFileName(vaultFile) else {
                throw unrecognizedLocalBackupError()
            }
            encryptedVault = try UniConnectAtomicFileWriter.readPrivateFile(
                at: url.deletingLastPathComponent().appendingPathComponent(vaultFile),
                repairPermissions: true
            )
            guard manifest.vaultSHA256 == encryptedVault.map(sha256Hex) else {
                throw unrecognizedLocalBackupError()
            }
        } else {
            encryptedVault = nil
        }

        var restored = manifest.document
        let credentialIDs = referencedCredentialIDs(in: restored)
        let commands = try vault.connectCommands(
            fromEncryptedSnapshot: encryptedVault,
            requiring: credentialIDs
        )
        for index in restored.workspaces.indices {
            if restored.workspaces[index].kind == .ssh {
                guard let credentialID = restored.workspaces[index].credentialId else {
                    if manifest.purpose == LocalBackupManifest.startupSeedPurpose {
                        continue
                    }
                    throw UniConnectError.missingCredential
                }
                guard let connect = commands[credentialID] else {
                    throw UniConnectError.missingCredential
                }
                restored.workspaces[index].connect = connect
            } else {
                restored.workspaces[index].credentialId = nil
            }
        }
        return restored
    }

    /// Replaces an app-owned plaintext startup seed with the same readable split format.
    ///
    /// The companion is committed first and the source path is replaced only after every
    /// SSH command has an opaque revision. The returned bytes are the new marker input.
    static func securePlainStartupSeed(
        document: UniConnectDocument,
        at target: URL,
        vault: UniConnectVault
    ) throws -> Data {
        let migration = try migratedLegacyBackup(
            document: document,
            vault: vault,
            allowMissingSSHCommands: true
        )
        let readableDocument = try sanitizedReadableDocument(
            migration.document,
            encryptedVault: migration.encryptedVault,
            vault: vault,
            preserveSSHDirectories: true,
            allowMissingSSHCredentials: true
        )
        let stem = target.deletingPathExtension().lastPathComponent
        let companionName = migration.encryptedVault.map { _ in
            "\(stem)-\(UUID().uuidString.lowercased()).vault.uc"
        }
        try writeReadableBackup(
            document: readableDocument,
            encryptedVault: migration.encryptedVault,
            to: target,
            vaultFileName: companionName,
            purpose: LocalBackupManifest.startupSeedPurpose
        )
        _ = try readReadableBackup(at: target, vault: vault)
        removeObsoletePrimaryVaultCopies(beside: target, keeping: companionName)
        return try UniConnectAtomicFileWriter.readPrivateFile(
            at: target,
            repairPermissions: true
        )
    }

    static func isReadableLocalBackupManifest(_ data: Data) -> Bool {
        guard let manifest = try? JSONDecoder().decode(LocalBackupManifest.self, from: data) else {
            return false
        }
        return manifest.format == LocalBackupManifest.formatName
    }

    private static func sanitizedReadableDocument(
        _ document: UniConnectDocument,
        encryptedVault: Data?,
        vault: UniConnectVault,
        preserveSSHDirectories: Bool = false,
        allowMissingSSHCredentials: Bool = false
    ) throws -> UniConnectDocument {
        var readable = document
        for index in readable.workspaces.indices {
            readable.workspaces[index].connect = nil
            if readable.workspaces[index].kind == .ssh {
                guard readable.workspaces[index].credentialId != nil
                        || allowMissingSSHCredentials else {
                    throw UniConnectError.missingCredential
                }
                if !preserveSSHDirectories {
                    readable.workspaces[index].cwd = nil
                }
                for windowIndex in readable.workspaces[index].windows.indices {
                    if !preserveSSHDirectories {
                        readable.workspaces[index].windows[windowIndex].cwd = nil
                    }
                    readable.workspaces[index].windows[windowIndex].claudeSession = nil
                    readable.workspaces[index].windows[windowIndex].localWindow = nil
                }
            } else {
                readable.workspaces[index].credentialId = nil
            }
        }
        _ = try vault.connectCommands(
            fromEncryptedSnapshot: encryptedVault,
            requiring: referencedCredentialIDs(in: readable)
        )
        return readable
    }

    private static func writeReadableBackup(
        document: UniConnectDocument,
        encryptedVault: Data?,
        to target: URL,
        vaultFileName: String?,
        purpose: String = LocalBackupManifest.backupPurpose
    ) throws {
        guard (encryptedVault == nil) == (vaultFileName == nil),
              vaultFileName.map(isSafeCompanionFileName) ?? true else {
            throw unrecognizedLocalBackupError()
        }
        let companionURL = vaultFileName.map {
            target.deletingLastPathComponent().appendingPathComponent($0)
        }
        if let encryptedVault, let companionURL {
            try UniConnectAtomicFileWriter.write(encryptedVault, to: companionURL)
        }

        let manifest = LocalBackupManifest(
            format: LocalBackupManifest.formatName,
            version: LocalBackupManifest.currentVersion,
            purpose: purpose,
            vaultFile: vaultFileName,
            vaultSHA256: encryptedVault.map(sha256Hex),
            document: document
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Retain the new companion if the manifest write reports an error: directory
        // fsync can fail after rename has already committed the JSON. Deleting the
        // companion in that state would turn a recoverable pair into a broken one.
        try UniConnectAtomicFileWriter.write(try encoder.encode(manifest), to: target)
    }

    private static func migratedLegacyBackup(
        document: UniConnectDocument,
        vault: UniConnectVault,
        allowMissingSSHCommands: Bool = false
    ) throws -> (document: UniConnectDocument, encryptedVault: Data?) {
        var migrated = document
        var idByCommand: [String: UUID] = [:]
        var additionalEntries: [UUID: String] = [:]
        for index in migrated.workspaces.indices {
            guard migrated.workspaces[index].kind == .ssh else {
                migrated.workspaces[index].credentialId = nil
                continue
            }
            guard let rawCommand = migrated.workspaces[index].connect else {
                if allowMissingSSHCommands {
                    migrated.workspaces[index].credentialId = nil
                    continue
                }
                throw UniConnectError.missingCredential
            }
            let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                if allowMissingSSHCommands {
                    migrated.workspaces[index].credentialId = nil
                    continue
                }
                throw UniConnectError.missingCredential
            }
            let credentialID = migrated.workspaces[index].credentialId
                ?? idByCommand[command]
                ?? vault.credentialID(matching: command, excluding: nil)
                ?? UUID()
            if let existing = additionalEntries[credentialID], existing != command {
                throw unrecognizedLocalBackupError()
            }
            migrated.workspaces[index].credentialId = credentialID
            idByCommand[command] = credentialID
            additionalEntries[credentialID] = command
        }
        let encryptedVault = try vault.encryptedSnapshot(including: additionalEntries)
        return (migrated, encryptedVault)
    }

    private static func referencedCredentialIDs(
        in document: UniConnectDocument
    ) -> Set<UUID> {
        Set(document.workspaces.compactMap { workspace in
            workspace.kind == .ssh ? workspace.credentialId : nil
        })
    }

    private static func isSafeCompanionFileName(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename == URL(fileURLWithPath: filename).lastPathComponent
            && filename.hasSuffix(".vault.uc")
            && !filename.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func unrecognizedLocalBackupError() -> UniConnectError {
        .corruptFile(String(
            localized: "uniconnect.backup.error.unrecognizedImport",
            defaultValue: "not a UniConnect export, JSON seed, or Markdown connection map"
        ))
    }

    private static func removeReadableBackupPair(at manifestURL: URL) {
        let manifest: LocalBackupManifest?
        if let data = try? UniConnectAtomicFileWriter.readPrivateFile(
            at: manifestURL,
            repairPermissions: true
        ) {
            manifest = try? JSONDecoder().decode(LocalBackupManifest.self, from: data)
        } else {
            manifest = nil
        }
        try? UniConnectAtomicFileWriter.removeIfPresent(at: manifestURL)
        guard let companionName = manifest?.vaultFile,
              isSafeCompanionFileName(companionName) else { return }
        try? UniConnectAtomicFileWriter.removeIfPresent(
            at: manifestURL.deletingLastPathComponent().appendingPathComponent(companionName)
        )
    }

    private static func removeObsoletePrimaryVaultCopies(
        beside target: URL,
        keeping retainedName: String?
    ) {
        let fileManager = FileManager.default
        let directory = target.deletingLastPathComponent()
        let prefix = target.deletingPathExtension().lastPathComponent + "-"
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for item in items where item.lastPathComponent != retainedName {
            let name = item.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".vault.uc") else { continue }
            let uuidStart = name.index(name.startIndex, offsetBy: prefix.count)
            let uuidEnd = name.index(name.endIndex, offsetBy: -".vault.uc".count)
            guard uuidStart < uuidEnd,
                  UUID(uuidString: String(name[uuidStart..<uuidEnd])) != nil,
                  let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            try? UniConnectAtomicFileWriter.removeIfPresent(at: item)
        }
    }

    private static func pruneHistory(
        at historyDirectory: URL,
        keep: Int,
        maximumAge: TimeInterval,
        now: Date
    ) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        let cutoff = now.addingTimeInterval(-maximumAge)
        let sorted = items
            .filter { url in
                let isReadable = url.pathExtension == "json" && url.lastPathComponent.hasPrefix("backup-")
                let isLegacy = url.pathExtension == "uc"
                    && url.lastPathComponent.hasPrefix("backup-")
                    && !url.lastPathComponent.hasSuffix(".vault.uc")
                guard (isReadable || isLegacy),
                      let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for (index, item) in sorted.enumerated() {
            let modifiedAt = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if index >= keep || modifiedAt < cutoff {
                do {
                    // Make the commit marker's absence durable before deleting its
                    // companion; the reverse order could expose a dangling JSON after
                    // a crash during pruning.
                    try UniConnectAtomicFileWriter.removeIfPresent(at: item)
                } catch {
                    continue
                }
                if item.pathExtension == "json" {
                    let stem = item.deletingPathExtension().lastPathComponent
                    let companion = historyDirectory.appendingPathComponent("\(stem).vault.uc")
                    try? UniConnectAtomicFileWriter.removeIfPresent(at: companion)
                }
            }
        }
        removeOrphanedHistoryVaultCopies(at: historyDirectory)
    }

    private static func removeOrphanedHistoryVaultCopies(at historyDirectory: URL) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for item in items where item.lastPathComponent.hasSuffix(".vault.uc") {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let stem = String(item.lastPathComponent.dropLast(".vault.uc".count))
            let manifest = historyDirectory.appendingPathComponent("\(stem).json")
            if !fileManager.fileExists(atPath: manifest.path) {
                try? UniConnectAtomicFileWriter.removeIfPresent(at: item)
            }
        }
    }

    // MARK: Export / import with passphrase

    static func exportData(document: UniConnectDocument, passphrase: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let plaintext = try encoder.encode(document)
        let sealedData = try UniConnectCrypto.sealWithPassphrase(plaintext, passphrase: passphrase)
        let envelope = try JSONDecoder().decode(UniConnectCrypto.Envelope.self, from: sealedData)
        let container = UniConnectExportContainer(
            format: UniConnectExportContainer.formatName,
            version: 1,
            meta: .init(
                app: "UniConnect",
                savedAt: document.savedAt,
                workspaces: document.workspaces.count,
                hostName: Host.current().localizedName
            ),
            payload: envelope
        )
        return try encoder.encode(container)
    }

    enum ImportSource {
        case encrypted(UniConnectExportContainer)
        case plainSeed(UniConnectDocument)
    }

    enum DetailedImportSource {
        case encrypted(UniConnectExportContainer)
        case plain(UniConnectImportSourceDocument)
    }

    /// Inspects a file without decrypting it. Plain JSON seeds (the bootstrap
    /// template) are accepted as-is; anything else must be a valid container.
    static func inspect(data: Data) throws -> ImportSource {
        switch try inspectDetailed(data: data) {
        case .encrypted(let container):
            return .encrypted(container)
        case .plain(let source):
            return .plainSeed(source.document)
        }
    }

    /// Inspects an import while retaining row-level JSON or Markdown diagnostics.
    static func inspectDetailed(data: Data) throws -> DetailedImportSource {
        let decoder = JSONDecoder()
        if let container = try? decoder.decode(UniConnectExportContainer.self, from: data) {
            guard container.format == UniConnectExportContainer.formatName else {
                throw UniConnectError.corruptFile(String(
                    format: String(
                        localized: "uniconnect.backup.error.unsupportedExportFormat",
                        defaultValue: "unsupported export format: %@"
                    ),
                    container.format
                ))
            }
            guard container.version == 1 else {
                throw UniConnectError.corruptFile(String(
                    format: String(
                        localized: "uniconnect.backup.error.unsupportedContainerVersion",
                        defaultValue: "unsupported container version: %d"
                    ),
                    container.version
                ))
            }
            return .encrypted(container)
        }
        if let source = try? UniConnectJSONImportParser.parseDetailed(data) {
            try validateVersion(source.document)
            return .plain(source)
        }
        // A hand-written Markdown map of boxes (CONNECT.md) is a first-class import format.
        if let text = String(data: data, encoding: .utf8), UniConnectMarkdown.looksLikeConnectionMap(text) {
            let source = try UniConnectMarkdown.parseDetailed(text)
            try validateVersion(source.document)
            return .plain(source)
        }
        throw UniConnectError.corruptFile(String(
            localized: "uniconnect.backup.error.unrecognizedImport",
            defaultValue: "not a UniConnect export, JSON seed, or Markdown connection map"
        ))
    }

    /// Opens every file accepted by the import picker, including a readable local
    /// backup/history manifest whose encrypted vault lives beside the selected JSON.
    static func inspectDetailed(
        at url: URL,
        vault: UniConnectVault = .shared
    ) throws -> DetailedImportSource {
        let data = try Data(contentsOf: url)
        if isReadableLocalBackupManifest(data) {
            return .plain(UniConnectImportSourceDocument(
                document: try readReadableBackup(at: url, vault: vault),
                sourceMap: .empty
            ))
        }
        return try inspectDetailed(data: data)
    }

    static func decrypt(container: UniConnectExportContainer, passphrase: String) throws -> UniConnectDocument {
        let payloadData = try JSONEncoder().encode(container.payload)
        let plaintext = try UniConnectCrypto.openWithPassphrase(payloadData, passphrase: passphrase)
        let document = try JSONDecoder().decode(UniConnectDocument.self, from: plaintext)
        try validateVersion(document)
        return document
    }

    static func validate(_ document: UniConnectDocument) throws {
        try validateVersion(document)
        for workspace in document.workspaces {
            let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw UniConnectError.corruptFile(String(
                    localized: "uniconnect.backup.error.workspaceMissingName",
                    defaultValue: "box without a name"
                ))
            }
            if workspace.kind == .ssh {
                guard let connect = workspace.connect?.trimmingCharacters(in: .whitespacesAndNewlines), !connect.isEmpty else {
                    throw UniConnectError.corruptFile(String(
                        format: String(
                            localized: "uniconnect.backup.error.sshMissingConnection",
                            defaultValue: "SSH box “%@” has no connection command"
                        ),
                        name
                    ))
                }
                guard !connect.contains("\n") else {
                    throw UniConnectError.corruptFile(String(
                        format: String(
                            localized: "uniconnect.backup.error.connectionLineBreak",
                            defaultValue: "the connection command for “%@” contains line breaks"
                        ),
                        name
                    ))
                }
                // An imported file must not be able to run arbitrary commands: the same rule
                // as the "Nueva caja" form applies here (only ssh / sshpass).
                if let message = UniConnectSSH.validateConnectCommand(connect) {
                    throw UniConnectError.corruptFile(String(
                        format: String(
                            localized: "uniconnect.backup.error.unsafeWorkspace",
                            defaultValue: "box “%@” is not accepted: %@"
                        ),
                        name,
                        message
                    ))
                }
            }
            for window in workspace.windows {
                if workspace.kind == .ssh, window.localWindow != nil {
                    throw UniConnectError.corruptFile(String(
                        format: String(
                            localized: "uniconnect.backup.error.remoteContainsLocalState",
                            defaultValue: "the SSH window in “%@” contains local state"
                        ),
                        name
                    ))
                }
                if let tmux = window.tmux, UniConnectSSH.sanitizedTmuxName(tmux) != tmux {
                    throw UniConnectError.corruptFile(String(
                        format: String(
                            localized: "uniconnect.backup.error.invalidTmuxID",
                            defaultValue: "invalid tmux ID in “%@”: %@"
                        ),
                        name,
                        tmux
                    ))
                }
            }
        }
    }

    /// Structural validation happens before preview; row-level failures stay visible in the plan.
    private static func validateVersion(_ document: UniConnectDocument) throws {
        guard document.version >= 1, document.version <= UniConnectDocument.currentVersion else {
            throw UniConnectError.corruptFile(String(
                format: String(
                    localized: "uniconnect.backup.error.unsupportedDocumentVersion",
                    defaultValue: "unsupported document version: %d"
                ),
                document.version
            ))
        }
    }

    // MARK: Seed template (what Dani fills in later)

    static func seedTemplate() -> String {
        let doc = UniConnectDocument(workspaces: [
            .init(
                name: String(localized: "uniconnect.backup.seed.localName", defaultValue: "LOCAL EXAMPLE"),
                kind: .local,
                color: "#3B82F6",
                group: nil,
                isPinned: nil,
                cwd: "~/Desktop/PROYECTOS/EJEMPLO",
                connect: nil,
                windows: [
                    .init(name: "claude", tmux: nil, claudeSession: nil, cwd: nil, isPinned: nil),
                    .init(name: "shell", tmux: nil, claudeSession: nil, cwd: nil, isPinned: nil)
                ]
            ),
            .init(
                name: String(localized: "uniconnect.backup.seed.sshName", defaultValue: "SSH EXAMPLE"),
                kind: .ssh,
                color: "#EF4444",
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: "sshpass -p 'PASSWORD' ssh root@1.2.3.4",
                windows: [
                    .init(name: "claude", tmux: "uc-claude", claudeSession: nil, cwd: nil, isPinned: nil),
                    .init(name: "logs", tmux: "uc-logs", claudeSession: nil, cwd: nil, isPinned: nil)
                ]
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(doc)) ?? Data(), as: UTF8.self)
    }
}
