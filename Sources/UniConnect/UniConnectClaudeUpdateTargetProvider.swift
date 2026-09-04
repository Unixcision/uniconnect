import Foundation
import UniConnectClaudeUpdate

/// Resolves updater scopes from immutable app state and fail-closed session discovery.
actor UniConnectClaudeUpdateTargetProvider: ClaudeUpdateTargetProviding {
    typealias AgentIndexLoader = @Sendable () async -> RestorableAgentSessionIndex
    typealias CredentialSnapshotResolver = @Sendable (UUID) async -> (
        revisionID: UUID,
        endpointFingerprint: String
    )?

    private let stateReader: any UniConnectClaudeUpdateApplicationStateReading
    private let remoteResolver: any UniConnectClaudeRemoteTargetResolving
    private let agentIndexLoader: AgentIndexLoader
    private let credentialSnapshotResolver: CredentialSnapshotResolver
    private let fileManager: FileManager

    init(
        stateReader: any UniConnectClaudeUpdateApplicationStateReading,
        remoteResolver: any UniConnectClaudeRemoteTargetResolving,
        credentialSnapshotResolver: @escaping CredentialSnapshotResolver,
        agentIndexLoader: @escaping AgentIndexLoader = {
            await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
        },
        fileManager: FileManager = .default
    ) {
        self.stateReader = stateReader
        self.remoteResolver = remoteResolver
        self.credentialSnapshotResolver = credentialSnapshotResolver
        self.agentIndexLoader = agentIndexLoader
        self.fileManager = fileManager
    }

    func targets(for scope: ClaudeUpdateScope) async throws -> [ClaudeUpdateTarget] {
        let workspaces = await stateReader.workspaceSnapshots()
        let agentIndex = await agentIndexLoader()
        var targets: [ClaudeUpdateTarget] = []

        for workspace in workspaces where Self.scope(scope, includes: workspace) {
            for panel in workspace.panels where Self.scope(scope, includes: panel) {
                switch workspace.kind {
                case .local:
                    let binding = localBinding(
                        workspace: workspace,
                        panel: panel,
                        agentIndex: agentIndex
                    )
                    guard binding != nil || Self.hasPersistedLocalClaudeEvidence(panel) else {
                        continue
                    }
                    targets.append(
                        ClaudeUpdateTarget(
                            id: UniConnectClaudeUpdateTargetIdentity.targetID(panelID: panel.id),
                            boxID: workspace.boxID,
                            displayName: Self.safeDisplayName(panel.displayName),
                            host: ClaudeUpdateHostIdentity(
                                kind: .local,
                                id: UniConnectClaudeUpdateHostID.local,
                                displayName: String(
                                    localized: "claudeUpdate.host.local",
                                    defaultValue: "This Mac"
                                )
                            ),
                            binding: binding,
                            pane: nil
                        )
                    )

                case .ssh:
                    guard let tmuxSession = Self.normalized(panel.tmuxSession), !tmuxSession.isEmpty else {
                        continue
                    }
                    let credentialSnapshot: (revisionID: UUID, endpointFingerprint: String)? = if let credentialID = workspace.credentialID {
                        await credentialSnapshotResolver(credentialID)
                    } else {
                        nil
                    }
                    let frozenWorkspace = Self.workspace(
                        workspace,
                        credentialID: credentialSnapshot?.revisionID
                    )
                    let resolution = panel.isDisconnected
                        ? nil
                        : await remoteResolver.resolve(workspace: frozenWorkspace, panel: panel)
                    let hostIdentity = Self.remoteHostIdentity(
                        workspace: frozenWorkspace,
                        endpointFingerprint: credentialSnapshot?.endpointFingerprint
                    )
                    targets.append(
                        ClaudeUpdateTarget(
                            id: UniConnectClaudeUpdateTargetIdentity.targetID(panelID: panel.id),
                            boxID: workspace.boxID,
                            displayName: Self.safeDisplayName(panel.displayName),
                            host: hostIdentity,
                            binding: resolution?.binding,
                            pane: resolution?.pane
                        )
                    )
                }
            }
        }

        return targets
    }

    private func localBinding(
        workspace: UniConnectClaudeUpdateWorkspaceSnapshot,
        panel: UniConnectClaudeUpdatePanelSnapshot,
        agentIndex: RestorableAgentSessionIndex
    ) -> ClaudeSessionBinding? {
        let indexed = agentIndex.snapshot(workspaceId: workspace.id, panelId: panel.id)
        let snapshot = indexed ?? panel.restorableAgent
        guard let snapshot, snapshot.kind == .claude else { return nil }
        guard let sessionID = UUID(uuidString: snapshot.sessionId) else { return nil }

        if let persisted = Self.normalized(panel.persistedClaudeSessionID),
           UUID(uuidString: persisted) != sessionID {
            return nil
        }

        guard let workingDirectory = Self.normalizedAbsolutePath(
            snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory
        ), Self.isExistingDirectory(workingDirectory, fileManager: fileManager) else {
            return nil
        }
        guard let executablePath = Self.normalizedAbsolutePath(
            snapshot.launchCommand?.executablePath
        ), fileManager.isExecutableFile(atPath: executablePath) else {
            return nil
        }

        return ClaudeSessionBinding(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            executablePath: executablePath,
            installationID: UniConnectClaudeInstallationIdentity.identifier(
                executablePath: executablePath
            )
        )
    }

    private static func remoteHostIdentity(
        workspace: UniConnectClaudeUpdateWorkspaceSnapshot,
        endpointFingerprint: String?
    ) -> ClaudeUpdateHostIdentity {
        let fallbackID = "ssh-box:" + workspace.id.uuidString.lowercased()
        let id: String
        if let credentialID = workspace.credentialID, let endpointFingerprint {
            id = UniConnectClaudeUpdateHostID.remote(
                credentialID: credentialID,
                endpointFingerprint: endpointFingerprint
            )
        } else {
            id = fallbackID
        }
        let fallbackName = String(
            localized: "claudeUpdate.host.remote",
            defaultValue: "SSH server"
        )
        return ClaudeUpdateHostIdentity(
            kind: .remote,
            id: id,
            displayName: safeDisplayName(workspace.hostLabel ?? workspace.displayName, fallback: fallbackName)
        )
    }

    private static func workspace(
        _ workspace: UniConnectClaudeUpdateWorkspaceSnapshot,
        credentialID: UUID?
    ) -> UniConnectClaudeUpdateWorkspaceSnapshot {
        UniConnectClaudeUpdateWorkspaceSnapshot(
            id: workspace.id,
            boxID: workspace.boxID,
            displayName: workspace.displayName,
            kind: workspace.kind,
            credentialID: credentialID,
            hostLabel: workspace.hostLabel,
            panels: workspace.panels
        )
    }

    private static func hasPersistedLocalClaudeEvidence(
        _ panel: UniConnectClaudeUpdatePanelSnapshot
    ) -> Bool {
        normalized(panel.persistedClaudeSessionID) != nil || panel.restorableAgent?.kind == .claude
    }

    private static func scope(
        _ scope: ClaudeUpdateScope,
        includes workspace: UniConnectClaudeUpdateWorkspaceSnapshot
    ) -> Bool {
        switch scope {
        case .selected:
            return true
        case .box(let expectedBoxID):
            return workspace.boxID == expectedBoxID
        case .allOpen:
            return true
        }
    }

    private static func scope(
        _ scope: ClaudeUpdateScope,
        includes panel: UniConnectClaudeUpdatePanelSnapshot
    ) -> Bool {
        guard case .selected(let expectedID) = scope else { return true }
        return UniConnectClaudeUpdateTargetIdentity.targetID(panelID: panel.id) == expectedID
    }

    private static func safeDisplayName(_ value: String, fallback: String? = nil) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = singleLine.isEmpty
            ? (fallback ?? String(localized: "claudeUpdate.window.unnamed", defaultValue: "Unnamed window"))
            : singleLine
        return String(selected.prefix(160))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedAbsolutePath(_ value: String?) -> String? {
        guard let value = normalized(value), value.hasPrefix("/"), !value.contains("\0") else {
            return nil
        }
        return (value as NSString).standardizingPath
    }

    private static func isExistingDirectory(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
