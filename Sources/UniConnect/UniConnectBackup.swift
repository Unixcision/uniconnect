import Foundation
import AppKit

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
    // MARK: Build the readable document from live state

    static func buildDocument(tabManagers: [TabManager]) -> UniConnectDocument {
        let agentIndex = RestorableAgentSessionIndex.load()
        var workspaces: [UniConnectDocument.Workspace] = []
        for tabManager in tabManagers {
            let groupNames = Dictionary(uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0.name) })
            for workspace in tabManager.tabs {
                workspaces.append(documentWorkspace(workspace, groupNames: groupNames, agentIndex: agentIndex))
            }
        }
        return UniConnectDocument(workspaces: workspaces)
    }

    static func documentWorkspace(
        _ workspace: Workspace,
        groupNames: [UUID: String],
        agentIndex: RestorableAgentSessionIndex
    ) -> UniConnectDocument.Workspace {
        let profile = workspace.uniConnectProfile ?? .local
        let connect = profile.credentialId.flatMap { UniConnectVault.shared.connectCommand(for: $0) }
        var windows: [UniConnectDocument.Window] = []
        for panelId in workspace.uniConnectOrderedTerminalPanelIds() {
            let name = workspace.panelCustomTitles[panelId] ?? workspace.panelTitles[panelId]
            let tmux = workspace.uniConnectTmuxSessionsByPanelId[panelId]
            let claude = agentIndex.snapshot(workspaceId: workspace.id, panelId: panelId)
                .flatMap { $0.kind == .claude ? $0.sessionId : nil }
            let cwd = workspace.panelDirectories[panelId] ?? (workspace.panels[panelId] as? TerminalPanel)?.requestedWorkingDirectory
            windows.append(UniConnectDocument.Window(
                name: name,
                tmux: tmux,
                claudeSession: claude,
                cwd: profile.isSSH ? nil : cwd,
                isPinned: nil
            ))
        }
        return UniConnectDocument.Workspace(
            name: workspace.customTitle ?? workspace.title,
            kind: profile.kind,
            color: workspace.customColor,
            group: workspace.groupId.flatMap { groupNames[$0] },
            isPinned: workspace.isPinned ? true : nil,
            cwd: profile.isSSH ? nil : workspace.currentDirectory,
            connect: connect,
            windows: windows
        )
    }

    // MARK: Local encrypted backup ("Persistir ahora")

    @discardableResult
    static func persistNow(tabManagers: [TabManager]) throws -> URL {
        let document = buildDocument(tabManagers: tabManagers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let plaintext = try encoder.encode(document)
        let sealed = try UniConnectCrypto.seal(plaintext, key: UniConnectMasterKey.load())
        let target = UniConnectPaths.backupFile
        try sealed.write(to: target, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let history = UniConnectPaths.backupHistoryDirectory.appendingPathComponent("backup-\(stamp).uc")
        try? sealed.write(to: history, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
        pruneHistory(keep: 30)
        return target
    }

    static func readLocalBackup() throws -> UniConnectDocument {
        let data = try Data(contentsOf: UniConnectPaths.backupFile)
        let envelope = try UniConnectCrypto.parseEnvelope(data)
        let plaintext = try UniConnectCrypto.open(envelope, key: UniConnectMasterKey.load())
        return try JSONDecoder().decode(UniConnectDocument.self, from: plaintext)
    }

    private static func pruneHistory(keep: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: UniConnectPaths.backupHistoryDirectory, includingPropertiesForKeys: nil) else { return }
        let sorted = items.filter { $0.pathExtension == "uc" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for item in sorted.dropFirst(keep) { try? fm.removeItem(at: item) }
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

    /// Inspects a file without decrypting it. Plain JSON seeds (the bootstrap
    /// template) are accepted as-is; anything else must be a valid container.
    static func inspect(data: Data) throws -> ImportSource {
        let decoder = JSONDecoder()
        if let container = try? decoder.decode(UniConnectExportContainer.self, from: data) {
            guard container.format == UniConnectExportContainer.formatName else {
                throw UniConnectError.corruptFile("formato \(container.format)")
            }
            guard container.version == 1 else {
                throw UniConnectError.corruptFile("versión de contenedor \(container.version) no soportada")
            }
            return .encrypted(container)
        }
        if let document = try? decoder.decode(UniConnectDocument.self, from: data) {
            try validate(document)
            return .plainSeed(document)
        }
        // A hand-written Markdown map of boxes (CONNECT.md) is a first-class import format.
        if let text = String(data: data, encoding: .utf8), UniConnectMarkdown.looksLikeConnectionMap(text) {
            let document = try UniConnectMarkdown.parse(text)
            try validate(document)
            return .plainSeed(document)
        }
        throw UniConnectError.corruptFile("no es un export de UniConnect, ni una semilla JSON, ni un mapa de conexiones en Markdown")
    }

    static func decrypt(container: UniConnectExportContainer, passphrase: String) throws -> UniConnectDocument {
        let payloadData = try JSONEncoder().encode(container.payload)
        let plaintext = try UniConnectCrypto.openWithPassphrase(payloadData, passphrase: passphrase)
        let document = try JSONDecoder().decode(UniConnectDocument.self, from: plaintext)
        try validate(document)
        return document
    }

    static func validate(_ document: UniConnectDocument) throws {
        guard document.version >= 1, document.version <= UniConnectDocument.currentVersion else {
            throw UniConnectError.corruptFile("versión de documento \(document.version) no soportada")
        }
        for workspace in document.workspaces {
            let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw UniConnectError.corruptFile("caja sin nombre") }
            if workspace.kind == .ssh {
                guard let connect = workspace.connect?.trimmingCharacters(in: .whitespacesAndNewlines), !connect.isEmpty else {
                    throw UniConnectError.corruptFile("la caja SSH \(name) no tiene comando de conexión")
                }
                guard !connect.contains("\n") else {
                    throw UniConnectError.corruptFile("el comando de conexión de \(name) tiene saltos de línea")
                }
                // An imported file must not be able to run arbitrary commands: the same rule
                // as the "Nueva caja" form applies here (only ssh / sshpass).
                if let message = UniConnectSSH.validateConnectCommand(connect) {
                    throw UniConnectError.corruptFile("la caja \(name) no es aceptable: \(message)")
                }
            }
            for window in workspace.windows {
                if let tmux = window.tmux, UniConnectSSH.sanitizedTmuxName(tmux) != tmux {
                    throw UniConnectError.corruptFile("ID tmux inválido en \(name): \(tmux)")
                }
            }
        }
    }

    // MARK: Seed template (what Dani fills in later)

    static func seedTemplate() -> String {
        let doc = UniConnectDocument(workspaces: [
            .init(
                name: "EJEMPLO LOCAL",
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
                name: "EJEMPLO SSH",
                kind: .ssh,
                color: "#EF4444",
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: "sshpass -p 'CONTRASEÑA' ssh root@1.2.3.4",
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
