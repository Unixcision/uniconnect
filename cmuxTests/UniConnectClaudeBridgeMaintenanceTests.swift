import CryptoKit
import Foundation
import Testing
import UniConnectClaudeBridge

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct UniConnectClaudeBridgeMaintenanceTests {
    private actor TokenStore: ClaudeBridgeTokenStoring {
        private var tokens: [UUID: (Data, UUID)] = [:]

        func token(for routeID: UUID, credentialID: UUID) async throws -> Data? {
            guard let entry = tokens[routeID], entry.1 == credentialID else { return nil }
            return entry.0
        }

        func store(token: Data, for routeID: UUID, credentialID: UUID) async throws {
            tokens[routeID] = (token, credentialID)
        }

        func removeToken(for routeID: UUID) async throws {
            tokens.removeValue(forKey: routeID)
        }

        func routeIDs(for credentialID: UUID) async throws -> [UUID] {
            tokens.compactMap { $0.value.1 == credentialID ? $0.key : nil }
        }
    }

    private actor Executor: UniConnectSSHCommandExecuting {
        enum StubError: Error {
            case failed
        }

        private let shouldFail: Bool
        private(set) var invocations: [UniConnectSSHProcessInvocation] = []

        init(shouldFail: Bool = false) {
            self.shouldFail = shouldFail
        }

        func execute(
            _ invocation: UniConnectSSHProcessInvocation,
            timeout: Duration
        ) async throws {
            invocations.append(invocation)
            if shouldFail { throw StubError.failed }
        }

        func lastInvocation() -> UniConnectSSHProcessInvocation? {
            invocations.last
        }
    }

    @Test
    func verifiedCleanupUsesOneShellFreeSSHRequestAndThenForgetsTokens() async throws {
        let routeA = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let routeB = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let credentialID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let tokenStore = TokenStore()
        try await tokenStore.store(
            token: Data(repeating: 0x11, count: 32),
            for: routeA,
            credentialID: credentialID
        )
        try await tokenStore.store(
            token: Data(repeating: 0x22, count: 32),
            for: routeB,
            credentialID: credentialID
        )
        let executor = Executor()
        let service = UniConnectClaudeBridgeMaintenanceService(
            tokenStore: tokenStore,
            commandExecutor: executor,
            installationKey: SymmetricKey(data: Data(repeating: 0x33, count: 32))
        )
        let effectiveTarget = try #require(UniConnectSSHEffectiveTarget(
            user: "bridge",
            host: "server-a.example",
            port: 2203
        ))
        var session = DetectedSSHSession(
            destination: "bridge-test.invalid",
            port: 22,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        session.uniConnectEffectiveTarget = effectiveTarget

        try await service.removeRemoteIntegration(
            routeIDs: [routeB, routeA, routeA],
            session: session
        )

        let capturedInvocation = await executor.lastInvocation()
        let invocation = try #require(capturedInvocation)
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.arguments.starts(with: effectiveTarget.sshPinningOptions))
        #expect(invocation.arguments.contains("bridge-test.invalid"))
        #expect(!invocation.arguments.contains(where: { $0.contains("server-b.example") }))
        let remoteCommand = try #require(invocation.arguments.last)
        #expect(remoteCommand.contains(routeA.uuidString.lowercased()))
        #expect(remoteCommand.contains(routeB.uuidString.lowercased()))
        #expect(remoteCommand.contains(" && "))
        #expect(!remoteCommand.contains("0x11"))
        let tokenA = try await tokenStore.token(for: routeA, credentialID: credentialID)
        let tokenB = try await tokenStore.token(for: routeB, credentialID: credentialID)
        #expect(tokenA == nil)
        #expect(tokenB == nil)
    }

    @Test
    func failedRemoteCleanupRetainsTheLocalAuthenticationToken() async throws {
        let routeID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let credentialID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
        let token = Data(repeating: 0x44, count: 32)
        let tokenStore = TokenStore()
        try await tokenStore.store(token: token, for: routeID, credentialID: credentialID)
        let service = UniConnectClaudeBridgeMaintenanceService(
            tokenStore: tokenStore,
            commandExecutor: Executor(shouldFail: true),
            installationKey: SymmetricKey(data: Data(repeating: 0x55, count: 32))
        )
        let session = DetectedSSHSession(
            destination: "bridge-test.invalid",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        await #expect(throws: Executor.StubError.self) {
            try await service.removeRemoteIntegration(routeIDs: [routeID], session: session)
        }
        let retained = try await tokenStore.token(for: routeID, credentialID: credentialID)
        #expect(retained == token)
    }

    @Test
    func localRouteTokenVaultIsEncryptedAndPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-bridge-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tokens.uc")
        let key = SymmetricKey(data: Data(repeating: 0x66, count: 32))
        let routeID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
        let credentialID = UUID(uuidString: "60000000-0000-4000-8000-000000000001")!
        let token = Data(repeating: 0x77, count: 32)
        let vault = UniConnectClaudeBridgeTokenVault(fileURL: fileURL, key: key)

        try await vault.store(token: token, for: routeID, credentialID: credentialID)

        let encrypted = try Data(contentsOf: fileURL)
        #expect(encrypted.range(of: token) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let reloaded = UniConnectClaudeBridgeTokenVault(fileURL: fileURL, key: key)
        let recovered = try await reloaded.token(for: routeID, credentialID: credentialID)
        #expect(recovered == token)
        let wrongCredential = try await reloaded.token(
            for: routeID,
            credentialID: UUID()
        )
        #expect(wrongCredential == nil)
    }

    @MainActor
    @Test
    func bridgeRoutingFollowsStableSurfaceAfterWorkspaceMove() throws {
        let manager = TabManager()
        let source = try #require(manager.selectedWorkspace)
        let sourcePane = try #require(source.bonsplitController.allPaneIds.first)
        let panel = try #require(source.newTerminalSurface(inPane: sourcePane, focus: false))
        let destination = manager.addWorkspace(title: "Destination", select: false)
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        let route = ClaudeBridgeRoute(
            id: panel.id,
            workspaceID: source.id,
            surfaceID: panel.id,
            credentialID: UUID(),
            hostLabel: "test-host",
            workspaceName: "Source",
            windowName: "Claude",
            tmuxSession: "claude"
        )

        let detached = try #require(source.detachSurface(panelId: panel.id))
        _ = try #require(destination.attachDetachedSurface(detached, inPane: destinationPane, focus: false))

        let resolved = UniConnectClaudeBridgeNotificationSink.workspace(for: route, in: [manager])
        #expect(resolved === destination)
        UniConnectClaudeBridgeNotificationSink.deliverStatus(.active, for: route, in: [manager])
        #expect(source.uniConnectClaudeBridgeStatusByPanelId[route.id] == nil)
        #expect(destination.uniConnectClaudeBridgeStatusByPanelId[route.id] == .active)
        UniConnectClaudeBridgeNotificationSink.deliverStatus(.inactive, for: route, in: [manager])
        #expect(destination.uniConnectClaudeBridgeStatusByPanelId[route.id] == nil)
    }

    @MainActor
    @Test
    func compatibleSSHWorkspaceMoveTransfersDurableWindowStateBeforeCleaningSource() throws {
        let target = try #require(UniConnectSSHEffectiveTarget(
            user: "deploy",
            host: "same.example.test",
            port: 2202
        ))
        let credentialID = try UniConnectVault.shared.createImmutableRevision(
            connectCommand: "ssh -p 2202 deploy@same.example.test",
            effectiveTarget: target
        )
        defer { UniConnectVault.shared.remove(id: credentialID) }

        let manager = TabManager()
        let source = try #require(manager.selectedWorkspace)
        let destination = manager.addWorkspace(title: "Same host", select: false)
        let panelID = try #require(source.focusedPanelId)
        let profile = UniConnectWorkspaceProfile(
            kind: .ssh,
            importIdentity: UUID(),
            credentialId: credentialID,
            hostLabel: "deploy@same.example.test",
            tmuxReady: true
        )
        source.uniConnectProfile = profile
        destination.uniConnectProfile = profile
        source.uniConnectTmuxSessionsByPanelId[panelID] = "claudesa"
        source.uniConnectClaudeSessionsByPanelId[panelID] = "claude-session-id"
        source.uniConnectDisconnectedPanelIds.insert(panelID)
        source.uniConnectClaudeBridgeStatusByPanelId[panelID] = .reconnecting

        #expect(source.canTransferSurface(panelId: panelID, to: destination))
        let detached = try #require(source.detachSurface(panelId: panelID))
        #expect(detached.uniConnectSSHState?.credentialRecord.effectiveTarget == target)
        #expect(detached.uniConnectSSHState?.isDisconnected == true)
        #expect(detached.isRemoteTerminal == false)
        #expect(source.uniConnectTmuxSessionsByPanelId[panelID] == "claudesa")
        #expect(source.uniConnectClaudeSessionsByPanelId[panelID] == "claude-session-id")
        #expect(source.uniConnectDisconnectedPanelIds.contains(panelID))

        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        _ = try #require(destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ))

        #expect(destination.uniConnectTmuxSessionsByPanelId[panelID] == "claudesa")
        #expect(destination.uniConnectClaudeSessionsByPanelId[panelID] == "claude-session-id")
        #expect(destination.uniConnectDisconnectedPanelIds.contains(panelID))
        #expect(destination.uniConnectClaudeBridgeStatusByPanelId[panelID] == .reconnecting)
        source.completeDetachedSurfaceTransfer(detached)
        #expect(source.uniConnectTmuxSessionsByPanelId[panelID] == nil)
        #expect(source.uniConnectClaudeSessionsByPanelId[panelID] == nil)
        #expect(!source.uniConnectDisconnectedPanelIds.contains(panelID))
        #expect(source.uniConnectClaudeBridgeStatusByPanelId[panelID] == nil)
    }

    @MainActor
    @Test
    func sshWorkspaceMoveFailsClosedForDifferentRevisionLocalOrUnresolvedTargets() throws {
        let target = try #require(UniConnectSSHEffectiveTarget(
            user: "deploy",
            host: "same.example.test",
            port: 22
        ))
        let sourceCredentialID = try UniConnectVault.shared.createImmutableRevision(
            connectCommand: "ssh deploy@same.example.test",
            effectiveTarget: target
        )
        let equivalentButDifferentRevisionID = try UniConnectVault.shared.createImmutableRevision(
            connectCommand: "ssh deploy@same.example.test",
            effectiveTarget: target
        )
        let unresolvedCredentialID = try UniConnectVault.shared.createImmutableRevision(
            connectCommand: "ssh unresolved-alias"
        )
        defer {
            UniConnectVault.shared.remove(id: sourceCredentialID)
            UniConnectVault.shared.remove(id: equivalentButDifferentRevisionID)
            UniConnectVault.shared.remove(id: unresolvedCredentialID)
        }

        let manager = TabManager()
        let source = try #require(manager.selectedWorkspace)
        let panelID = try #require(source.focusedPanelId)
        source.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: sourceCredentialID,
            hostLabel: "deploy@same.example.test",
            tmuxReady: true
        )
        source.uniConnectTmuxSessionsByPanelId[panelID] = "claudesa"

        let differentRevision = manager.addWorkspace(title: "Different revision", select: false)
        differentRevision.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: equivalentButDifferentRevisionID,
            hostLabel: "deploy@same.example.test",
            tmuxReady: true
        )
        let local = manager.addWorkspace(title: "Local", select: false)
        local.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            localRoot: "/tmp/uniconnect-local-target"
        )
        let duplicateSession = manager.addWorkspace(title: "Duplicate tmux", select: false)
        duplicateSession.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: sourceCredentialID,
            hostLabel: "deploy@same.example.test",
            tmuxReady: true
        )
        let duplicatePanelID = try #require(duplicateSession.focusedPanelId)
        duplicateSession.uniConnectTmuxSessionsByPanelId[duplicatePanelID] = "claudesa"

        #expect(!source.canTransferSurface(panelId: panelID, to: differentRevision))
        #expect(!source.canTransferSurface(panelId: panelID, to: local))
        #expect(!source.canTransferSurface(panelId: panelID, to: duplicateSession))
        #expect(source.panels[panelID] != nil)
        #expect(source.canMoveSurfaceToNewUniConnectWorkspace(panelId: panelID))

        source.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: unresolvedCredentialID,
            hostLabel: "unresolved-alias",
            tmuxReady: true
        )
        #expect(!source.canMoveSurfaceToNewUniConnectWorkspace(panelId: panelID))
        #expect(!source.canTransferSurface(panelId: panelID, to: differentRevision))
        #expect(source.panels[panelID] != nil)
    }

    @MainActor
    @Test
    func newSSHWorkspaceClonesImmutableProfileAndAdoptsWindow() throws {
        let target = try #require(UniConnectSSHEffectiveTarget(
            user: "deploy",
            host: "clone.example.test",
            port: 22
        ))
        let credentialID = try UniConnectVault.shared.createImmutableRevision(
            connectCommand: "ssh deploy@clone.example.test",
            effectiveTarget: target
        )
        defer { UniConnectVault.shared.remove(id: credentialID) }

        let source = Workspace()
        let panelID = try #require(source.focusedPanelId)
        let originalImportIdentity = UUID()
        source.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            importIdentity: originalImportIdentity,
            credentialId: credentialID,
            hostLabel: "deploy@clone.example.test",
            tmuxReady: true
        )
        source.uniConnectTmuxSessionsByPanelId[panelID] = "claudesa"
        source.uniConnectClaudeSessionsByPanelId[panelID] = "claude-session-id"

        let detached = try #require(source.detachSurface(panelId: panelID))
        let destination = Workspace(title: "Clone", initialDetachedSurface: detached)

        #expect(destination.panels[panelID] != nil)
        #expect(destination.uniConnectProfile?.credentialId == credentialID)
        #expect(destination.uniConnectProfile?.importIdentity != originalImportIdentity)
        #expect(destination.uniConnectTmuxSessionsByPanelId[panelID] == "claudesa")
        #expect(destination.uniConnectClaudeSessionsByPanelId[panelID] == "claude-session-id")
        source.completeDetachedSurfaceTransfer(detached)
        #expect(source.uniConnectTmuxSessionsByPanelId[panelID] == nil)
    }

    @MainActor
    @Test
    func localWorkspaceMovePreservesPerWindowRootAndRejectsDifferentBoxRoot() throws {
        let sourceRoot = "/tmp/uniconnect-source-box"
        let destinationRoot = "/tmp/uniconnect-other-box"
        let manager = TabManager()
        let source = try #require(manager.selectedWorkspace)
        let panelID = try #require(source.focusedPanelId)
        source.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            localRoot: sourceRoot
        )
        let record = UniConnectLocalWindowRecord(
            id: panelID,
            visibleName: "Local agent",
            boxRoot: sourceRoot,
            workingDirectory: sourceRoot + "/project"
        )
        source.uniConnectLocalWindowsByPanelId[panelID] = record

        let incompatible = manager.addWorkspace(title: "Other root", select: false)
        incompatible.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            localRoot: destinationRoot
        )
        let compatible = manager.addWorkspace(title: "Same root", select: false)
        compatible.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            localRoot: sourceRoot
        )

        #expect(!source.canTransferSurface(panelId: panelID, to: incompatible))
        #expect(source.canTransferSurface(panelId: panelID, to: compatible))
        #expect(source.canMoveSurfaceToNewUniConnectWorkspace(panelId: panelID))
        let detached = try #require(source.detachSurface(panelId: panelID))
        #expect(detached.uniConnectLocalWindow?.boxRoot == record.boxRoot)
        #expect(detached.uniConnectLocalWindow?.workingDirectory == record.workingDirectory)

        let incompatiblePane = try #require(incompatible.bonsplitController.allPaneIds.first)
        #expect(incompatible.attachDetachedSurface(
            detached,
            inPane: incompatiblePane,
            focus: false
        ) == nil)
        #expect(incompatible.uniConnectLocalWindowsByPanelId[panelID] == nil)
        #expect(source.uniConnectLocalWindowsByPanelId[panelID] == record)

        let destinationPane = try #require(compatible.bonsplitController.allPaneIds.first)
        _ = try #require(compatible.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        ))
        let adopted = try #require(compatible.uniConnectLocalWindowsByPanelId[panelID])
        #expect(adopted.boxRoot == record.boxRoot)
        #expect(adopted.workingDirectory == record.workingDirectory)
        source.completeDetachedSurfaceTransfer(detached)
        #expect(source.uniConnectLocalWindowsByPanelId[panelID] == nil)
    }
}
