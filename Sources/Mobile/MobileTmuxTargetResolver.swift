import CryptoKit
import Foundation

/// Resolves exact saved identities without selecting a workspace or activating Ghostty.
@MainActor
final class MobileTmuxTargetResolver {
    private let tabManagers: @MainActor () -> [TabManager]
    private let credentialRecord: @MainActor (UUID) -> UniConnectSSHCredentialRecord?
    private let isLocked: @MainActor () -> Bool

    convenience init(
        coordinator: UniConnectCoordinator,
        credentialRecord: @escaping @MainActor (UUID) -> UniConnectSSHCredentialRecord?,
        isLocked: @escaping @MainActor () -> Bool
    ) {
        self.init(
            tabManagers: { coordinator.allTabManagers() },
            credentialRecord: credentialRecord,
            isLocked: isLocked
        )
    }

    /// Constructor injection allows behavior tests to use isolated desktop models.
    init(
        tabManagers: @escaping @MainActor () -> [TabManager],
        credentialRecord: @escaping @MainActor (UUID) -> UniConnectSSHCredentialRecord?,
        isLocked: @escaping @MainActor () -> Bool
    ) {
        self.tabManagers = tabManagers
        self.credentialRecord = credentialRecord
        self.isLocked = isLocked
    }

    func resolve(workspaceID: UUID, surfaceID: UUID, geometryNonce: UUID? = nil) throws -> MobileTmuxAttachPlan {
        guard !isLocked() else { throw MobileTmuxAttachError.locked }
        var match: (TabManager, Workspace, TerminalPanel)?
        for manager in tabManagers() {
            for workspace in manager.tabs where workspace.id == workspaceID {
                guard let panel = workspace.panels[surfaceID] as? TerminalPanel,
                      panel.id == surfaceID, panel.workspaceId == workspaceID,
                      panel.surface.id == surfaceID, panel.surface.tabId == workspaceID,
                      panel.surface.canAcceptPortalBinding(expectedSurfaceId: surfaceID, expectedGeneration: nil),
                      !workspace.uniConnectPlaceholderPanelIds.contains(surfaceID),
                      match == nil else {
                    throw MobileTmuxAttachError.targetUnavailable
                }
                match = (manager, workspace, panel)
            }
        }
        guard let (manager, workspace, panel) = match else {
            throw MobileTmuxAttachError.targetUnavailable
        }
        let target: MobileTmuxAttachPlan.Target
        let command: String
        if workspace.uniConnectProfile?.isSSH == true {
            guard let credentialID = workspace.uniConnectProfile?.credentialId,
                  let session = workspace.uniConnectTmuxSessionsByPanelId[surfaceID],
                  let record = credentialRecord(credentialID),
                  let effectiveTarget = record.effectiveTarget else {
                throw MobileTmuxAttachError.invalidSSHCredential
            }
            command = try MobileTmuxAttachPlan.sshCommand(record: record, session: session, geometryNonce: geometryNonce)
            // Credential IDs represent revisions, but also detect accidental in-place
            // replacement without retaining a second plaintext credential in identity.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(record)
            target = .ssh(
                credentialID: credentialID,
                revisionDigest: Data(SHA256.hash(data: encoded)),
                target: effectiveTarget,
                session: session
            )
        } else {
            guard workspace.uniConnectTmuxSessionsByPanelId[surfaceID] == nil,
                  let record = workspace.uniConnectLocalWindowsByPanelId[surfaceID],
                  let binding = record.tmuxBinding else {
                throw MobileTmuxAttachError.legacyTerminal
            }
            command = MobileTmuxAttachPlan.localCommand(binding: binding, geometryNonce: geometryNonce)
            target = .local(recordID: record.id, binding: binding)
        }
        return MobileTmuxAttachPlan(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            command: command,
            geometryNonce: geometryNonce,
            identity: .init(
                tabManager: ObjectIdentifier(manager), workspace: ObjectIdentifier(workspace),
                panel: ObjectIdentifier(panel), surface: ObjectIdentifier(panel.surface),
                surfaceGeneration: panel.surface.uniConnectSurfaceGeneration,
                profileIdentity: workspace.uniConnectProfile?.importIdentity,
                target: target
            )
        )
    }

    /// Call before forwarding input, resize or output to reject a retired binding.
    func validate(_ plan: MobileTmuxAttachPlan) throws {
        guard try resolve(workspaceID: plan.workspaceID, surfaceID: plan.surfaceID, geometryNonce: plan.geometryNonce) == plan else {
            throw MobileTmuxAttachError.targetChanged
        }
    }
}
