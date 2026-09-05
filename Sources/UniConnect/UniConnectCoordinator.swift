import AppKit
import SwiftUI
import CryptoKit
import UniConnectClaudeBridge
import UniConnectClaudeUpdate

// MARK: - Coordinator
//
// Glue between the UniConnect screens and cmux's TabManager/Workspace model.
// Everything that touches AppKit windows or the model runs on the main actor.

@MainActor
final class UniConnectCoordinator: ObservableObject {
    static let shared = UniConnectCoordinator()

    /// Per-workspace SSH setup state (probe/install progress) for the welcome page.
    private var setupStates: [UUID: UniConnectSSHSetupState] = [:]
    private var probes: [UUID: UniConnectTmuxProbe] = [:]
    private var claudeBridgeRuntime: UniConnectClaudeBridgeRuntime?
    private var claudeBridgeMaintenance: (any UniConnectClaudeBridgeMaintaining)?
    private var claudeBridgeListenerUnavailable = false
    private var bridgeCleanupRecordIDs: Set<UUID> = []
    private var claudeUpdateCoordinator: UniConnectClaudeUpdateCoordinator?
    private var claudeUpdateShutdown: (@MainActor () -> Void)?
    private typealias LocalAgentOwner = UniConnectLocalAgentRestoreClaimPolicy.Owner
    private typealias LocalAgentLease = UniConnectLocalAgentClaimRegistry.Lease

    private struct LocalAgentLaunchAttempt {
        let token: UUID
        let owner: LocalAgentOwner
        let lease: LocalAgentLease?
        let hasPreparedResume: Bool
    }

    private let localAgentClaimRegistry = UniConnectLocalAgentClaimRegistry()
    private var localAgentLaunchAttempts: [LocalAgentOwner: LocalAgentLaunchAttempt] = [:]
    private var localAgentLaunchTimeouts: [LocalAgentOwner: Task<Void, Never>] = [:]
    private var rejectedLocalAgentObservations: [LocalAgentOwner: UniConnectLocalAgentRestoreClaimPolicy.Claim] = [:]
    private var localAgentObservers: [NSObjectProtocol] = []
    private var sshCommandExecutor: (any UniConnectSSHCommandExecuting)?
    private var sshTargetResolver: (any UniConnectSSHTargetResolving)?
    private var localTmuxInspector: (any UniConnectLocalTmuxInspecting)?
    private var sshWorkspaceCreationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var sshWorkspaceCreationTokens: [ObjectIdentifier: UUID] = [:]
    private var sshCredentialEditTasks: [UUID: Task<Void, Never>] = [:]
    private var importTransaction: UniConnectImportTransaction?
    private var importCheckpoints: (any UniConnectImportCheckpointing)?
    private var importTask: Task<Void, Never>?
    private var manualSaveTask: Task<Void, Never>?
    private var didRecoverInterruptedImport = false
    private var isRestoringImportCheckpoint = false
    private(set) var importMutationGate: UniConnectImportMutationGate?

    private enum ImportApplicationError: Error {
        case runtimeUnavailable
        case invalidMutation
        case workspaceNotFound
        case workspaceAmbiguous
        case workspaceKindMismatch
        case windowNotFound
        case windowCreationFailed
        case trustedFolderUnavailable
        case activeAgentConflict
        case persistenceFailed
        case rollbackMismatch
    }

    private struct LiveImportWorkspace {
        let tabManager: TabManager
        let workspace: Workspace
        let document: UniConnectDocument.Workspace
    }

    /// Only reads the environment, so it is safe from any actor (menu builders, hit-test
    /// helpers and other nonisolated code ask for it).
    nonisolated static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        // Keep XCTest stock-compatible by default, while allowing focused tests to
        // exercise the real UniConnect branch without changing production behavior.
        if env["XCTestConfigurationFilePath"] != nil,
           env["UNICONNECT_TEST_ENABLE"] == "1" {
            return true
        }
        // Off under XCTest so the inherited cmux test-suite (shortcut routing, workspace
        // creation, CLI) keeps exercising stock behaviour; off on demand for dogfooding.
        if env["XCTestConfigurationFilePath"] != nil { return false }
        return env["UNICONNECT_DISABLE"] != "1"
    }

    private init() {
        let center = NotificationCenter.default
        localAgentObservers.append(
            center.addObserver(
                forName: .uniConnectClaudeSessionSignal,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let signal = notification.object as? UniConnectClaudeSessionSignal else { return }
                Task { @MainActor [weak self] in
                    self?.handleLocalAgentSignal(signal)
                }
            }
        )
        localAgentObservers.append(
            center.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleLocalAgentSurfaceReady(notification.object)
                }
            }
        )
    }

    /// Receives the transactional import graph from the executable composition root.
    func configureImportRuntime(
        transaction: UniConnectImportTransaction,
        checkpoints: any UniConnectImportCheckpointing,
        mutationGate: UniConnectImportMutationGate
    ) {
        importTransaction = transaction
        importCheckpoints = checkpoints
        importMutationGate = mutationGate
    }

    /// Receives bounded SSH services from the executable composition root.
    func configureSSHCommandExecutor(
        _ executor: any UniConnectSSHCommandExecuting,
        targetResolver: any UniConnectSSHTargetResolving
    ) {
        sshCommandExecutor = executor
        sshTargetResolver = targetResolver
    }

    /// Receives the read-only local tmux inspector from the executable composition root.
    func configureLocalTmuxInspector(_ inspector: any UniConnectLocalTmuxInspecting) {
        localTmuxInspector = inspector
    }

    func localTmuxGeneration(
        binding: UniConnectLocalTmuxBinding, workspaceID: UUID, panelID: UUID
    ) async -> UUID? {
        await localTmuxInspector?.generation(for: binding, workspaceID: workspaceID, panelID: panelID)
    }

    /// Reuses the injected inspector before a durable pane's socket client is dispatched.
    func verifiedLocalTmuxSocketOwner(
        peer: UniConnectLocalTmuxProcessIdentity,
        owners: [UniConnectLocalTmuxOwner]
    ) async -> UniConnectLocalTmuxOwner? {
        await localTmuxInspector?.verifiedOwner(of: peer, among: owners)
    }

    /// Receives the direct-SSH bridge graph from the executable composition root.
    func configureClaudeBridge(
        _ runtime: UniConnectClaudeBridgeRuntime?,
        maintenance: (any UniConnectClaudeBridgeMaintaining)? = nil,
        listenerUnavailable: Bool = false
    ) {
        claudeBridgeRuntime = runtime
        claudeBridgeMaintenance = maintenance
        claudeBridgeListenerUnavailable = listenerUnavailable
    }

    /// Stops the loopback listener and all one-shot enrollment timeouts at app exit.
    func shutdownClaudeBridge() {
        claudeBridgeRuntime?.shutdown()
        claudeBridgeRuntime = nil
        claudeBridgeMaintenance = nil
        claudeBridgeListenerUnavailable = false
    }

    /// Receives the Claude updater graph from the executable composition root.
    func configureClaudeUpdater(
        _ coordinator: UniConnectClaudeUpdateCoordinator,
        shutdown: @escaping @MainActor () -> Void
    ) {
        claudeUpdateCoordinator = coordinator
        claudeUpdateShutdown = shutdown
    }

    /// Presents the updater for the exact selected terminal window.
    func requestClaudeUpdateInWindow(panelID: UUID, workspace: Workspace) {
        guard Self.isEnabled, workspace.panels[panelID] is TerminalPanel else { return }
        claudeUpdateCoordinator?.request(
            .selected(UniConnectClaudeUpdateTargetIdentity.targetID(panelID: panelID))
        )
    }

    /// Presents the updater for every Claude window in one UniConnect box.
    func requestClaudeUpdateInBox(_ workspace: Workspace) {
        guard Self.isEnabled else { return }
        claudeUpdateCoordinator?.request(.box(id: workspace.id.uuidString.lowercased()))
    }

    /// Presents the updater for every open Claude window across all boxes.
    func requestClaudeUpdateEverywhere() {
        guard Self.isEnabled else { return }
        claudeUpdateCoordinator?.request(.allOpen)
    }

    /// Reconciles durable updater obligations left by a previous termination.
    func recoverPendingClaudeUpdateSessions() {
        claudeUpdateCoordinator?.recoverPendingSessions()
    }

    /// Cancels discovery and updater-owned processes while preserving durable recovery records.
    func shutdownClaudeUpdater() {
        claudeUpdateCoordinator?.shutdown()
        claudeUpdateShutdown?()
        claudeUpdateCoordinator = nil
        claudeUpdateShutdown = nil
    }

    /// Drops local runtime state for a closed panel while retaining its encrypted token
    /// so reopening from Cerradas can authenticate the existing remote route.
    func unregisterClaudeBridgeRoute(_ routeID: UUID, removeToken: Bool = false) {
        claudeBridgeRuntime?.unregister(routeID: routeID, removeToken: removeToken)
    }

    /// Keeps a live bridge route aligned with the workspace that adopted its stable panel.
    func rebindClaudeBridgeRoute(_ routeID: UUID, to workspace: Workspace) {
        guard workspace.panels[routeID] != nil,
              let tmuxSession = workspace.uniConnectTmuxSessionsByPanelId[routeID] else {
            return
        }
        claudeBridgeRuntime?.rebindRoute(
            routeID,
            workspaceID: workspace.id,
            workspaceName: workspace.customTitle ?? workspace.title,
            windowName: workspace.panelTitle(panelId: routeID) ?? tmuxSession
        )
    }

    // MARK: Window helpers

    private func hostWindow(for tabManager: TabManager?) -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
    }

    private func permitsImportSensitiveMutation() -> Bool {
        importMutationGate?.registerMutation() ?? true
    }

    private func presentError(_ message: String, title: String = "UniConnect") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    // MARK: "+" → Local / SSH

    /// Returns true when UniConnect handled the request (a sheet is showing or a
    /// workspace was created). False lets cmux fall back to its stock behaviour.
    func interceptNewWorkspace(tabManager: TabManager) -> Bool {
        guard Self.isEnabled else { return false }
        guard importMutationGate?.allowsMutation ?? true else { return true }
        let window = hostWindow(for: tabManager)
        UniConnectSheet.present(on: window, size: CGSize(width: 480, height: 400)) { dismiss in
            UniConnectNewWorkspaceView(
                onLocal: { [weak self, weak tabManager] result in
                    dismiss()
                    guard let self, let tabManager else { return }
                    // Two-step creation: the box first, then an explicit choice for its
                    // first window instead of a silently spawned plain terminal.
                    let workspace = self.createLocalWorkspace(
                        name: result.name,
                        folder: result.folder,
                        color: result.color,
                        in: tabManager,
                        initialTerminal: false
                    )
                    self.presentFirstLocalWindowChooser(for: workspace, boxRoot: result.folder)
                },
                onSSH: { [weak self, weak tabManager] result in
                    dismiss()
                    guard let self, let tabManager else { return }
                    self.beginSSHWorkspaceCreation(
                        name: result.name,
                        color: result.color,
                        connectCommand: result.connect,
                        in: tabManager
                    )
                },
                onCancel: { dismiss() }
            )
        }
        return true
    }

    /// Second step of "New box": asks how the first window should open. Dismissing the
    /// chooser falls back to the plain terminal the box used to receive automatically,
    /// so a local box is never left without a usable window.
    func presentFirstLocalWindowChooser(for workspace: Workspace, boxRoot: String) {
        guard UniConnectLocalBoxRootPolicy.isAvailableDirectory(boxRoot) else { return }
        let title = workspace.customTitle ?? workspace.title
        let registry = CmuxVaultAgentRegistry.load(workingDirectory: boxRoot)
        let customTargets = UniConnectLocalWindowLaunchTarget.customTargets(from: registry)
        let window = hostWindow(for: workspace.owningTabManager)
        let openPlainTerminal: (Workspace) -> Void = { [weak self] workspace in
            guard let self,
                  let request = UniConnectNewLocalWindowRequest(
                      visibleName: nil, boxRoot: boxRoot, launchTarget: .terminal
                  ) else { return }
            _ = self.createLocalWindow(in: workspace, request: request)
        }
        // Let the first sheet finish ending before the same parent begins another one.
        Task { @MainActor [weak self, weak workspace] in
            guard self != nil, let workspace else { return }
            UniConnectSheet.present(on: window, size: CGSize(width: 620, height: 700)) { dismiss in
                UniConnectNewLocalWindowView(
                    workspaceName: title,
                    boxRoot: boxRoot,
                    availableCustomTargets: customTargets,
                    isFirstWindow: true,
                    onCreate: { [weak self, weak workspace] request in
                        dismiss()
                        guard let self, let workspace else { return }
                        _ = self.createLocalWindow(in: workspace, request: request)
                    },
                    onCancel: { [weak workspace] in
                        dismiss()
                        guard let workspace else { return }
                        openPlainTerminal(workspace)
                    }
                )
            }
        }
    }

    private func beginSSHWorkspaceCreation(
        name: String,
        color: String?,
        connectCommand: String,
        in tabManager: TabManager
    ) {
        let owner = ObjectIdentifier(tabManager)
        guard sshWorkspaceCreationTasks[owner] == nil,
              let targetResolver = sshTargetResolver else {
            if sshWorkspaceCreationTasks[owner] == nil {
                presentError(String(
                    localized: "uniconnect.ssh.probe.error.launchUnavailable",
                    defaultValue: "The SSH connection could not be started."
                ))
            }
            return
        }
        let token = UUID()
        let expectedMutationRevision = importMutationGate?.externalMutationRevision
        sshWorkspaceCreationTokens[owner] = token
        let transaction = UniConnectSSHWorkspaceCreationTransaction(
            targetResolver: targetResolver
        )
        let task = Task { @MainActor [weak self, weak tabManager] in
            guard let self else { return }
            defer {
                if self.sshWorkspaceCreationTokens[owner] == token {
                    self.sshWorkspaceCreationTasks.removeValue(forKey: owner)
                    self.sshWorkspaceCreationTokens.removeValue(forKey: owner)
                }
            }
            guard let tabManager else { return }
            do {
                let record = try await transaction.prepare(
                    connectCommand: connectCommand,
                    isCurrentSubmission: { [weak self, weak tabManager] in
                        guard let self, let tabManager,
                              self.sshWorkspaceCreationTokens[owner] == token,
                              self.allTabManagers().contains(where: { $0 === tabManager }),
                              self.importMutationGate?.isLocked != true else {
                            return false
                        }
                        guard let expectedMutationRevision else { return true }
                        return self.importMutationGate?.externalMutationRevision
                            == expectedMutationRevision
                    }
                )
                guard self.sshWorkspaceCreationTokens[owner] == token else { return }
                _ = self.createSSHWorkspace(
                    name: name,
                    color: color,
                    credentialRecord: record,
                    in: tabManager
                )
            } catch let failure as UniConnectSSHWorkspaceCreationTransaction.Failure {
                switch failure {
                case .invalidConnection:
                    self.presentError(
                        String(
                            localized: "uniconnect.ssh.edit.error.invalid",
                            defaultValue: "The SSH command is not a supported safe connection command."
                        ),
                        title: String(
                            localized: "uniconnect.ssh.edit.invalid.title",
                            defaultValue: "Invalid SSH Connection"
                        )
                    )
                case .staleSubmission, .cancelled:
                    break
                }
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
        sshWorkspaceCreationTasks[owner] = task
    }

    @discardableResult
    /// Creates a local box. With `initialTerminal == false` the box keeps only its
    /// placeholder so the caller can ask how the first window should open; every
    /// other caller keeps the historical behaviour of one plain terminal window.
    func createLocalWorkspace(
        name: String,
        folder: String,
        color: String?,
        in tabManager: TabManager,
        select: Bool = true,
        finalizeCreation: Bool = true,
        stableIdentity: UUID? = nil,
        initialTerminal: Bool = true
    ) -> Workspace {
        guard permitsImportSensitiveMutation() else {
            return tabManager.selectedWorkspace ?? tabManager.tabs[0]
        }
        let workspace = tabManager.addWorkspace(
            title: name,
            workingDirectory: folder,
            initialTerminalCommand: UniConnectLocalBoxRootPolicy.isAvailableDirectory(folder) ? "/usr/bin/false" : nil,
            inheritWorkingDirectory: false,
            select: select,
            autoWelcomeIfNeeded: false
        )
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local,
            importIdentity: stableIdentity ?? UUID(),
            localRoot: folder
        )
        workspace.uniConnectConfigureLocalRoot(folder)
        workspace.setCustomColor(color)
        if UniConnectLocalBoxRootPolicy.isAvailableDirectory(folder) {
            installPlaceholder(in: workspace)
            if initialTerminal,
               let request = UniConnectNewLocalWindowRequest(
                   visibleName: nil, boxRoot: folder, launchTarget: .terminal
               ) {
                _ = createLocalWindow(
                    in: workspace, request: request, focus: select, requestPersistence: false
                )
            }
        }
        if (workspace.customDescription ?? "").isEmpty {
            workspace.setCustomDescription("Local · \((folder as NSString).abbreviatingWithTildeInPath)")
        }
        if finalizeCreation {
            closeUntouchedInitialWorkspaces()
            requestSave()
        }
        return workspace
    }

    @discardableResult
    func createSSHWorkspace(
        name: String,
        color: String?,
        connectCommand: String,
        in tabManager: TabManager,
        select: Bool = true,
        probeImmediately: Bool = true,
        finalizeCreation: Bool = true,
        stableIdentity: UUID? = nil
    ) -> Workspace? {
        guard permitsImportSensitiveMutation() else { return nil }
        let credentialId: UUID
        do {
            credentialId = try UniConnectVault.shared.storeOrThrow(connectCommand: connectCommand)
        } catch {
            presentError(error.localizedDescription)
            return nil
        }
        return installSSHWorkspace(
            name: name,
            color: color,
            connectCommand: connectCommand,
            credentialID: credentialId,
            in: tabManager,
            select: select,
            probeImmediately: probeImmediately,
            finalizeCreation: finalizeCreation,
            stableIdentity: stableIdentity
        )
    }

    @discardableResult
    private func createSSHWorkspace(
        name: String,
        color: String?,
        credentialRecord: UniConnectSSHCredentialRecord,
        in tabManager: TabManager,
        select: Bool = true,
        probeImmediately: Bool = true,
        finalizeCreation: Bool = true,
        stableIdentity: UUID? = nil
    ) -> Workspace? {
        guard permitsImportSensitiveMutation(),
              credentialRecord.effectiveTarget != nil else {
            return nil
        }
        let credentialID: UUID
        do {
            credentialID = try UniConnectVault.shared.storeOrThrow(
                connectCommand: credentialRecord.connectCommand,
                effectiveTarget: credentialRecord.effectiveTarget
            )
        } catch {
            presentError(error.localizedDescription)
            return nil
        }
        return installSSHWorkspace(
            name: name,
            color: color,
            connectCommand: credentialRecord.connectCommand,
            credentialID: credentialID,
            in: tabManager,
            select: select,
            probeImmediately: probeImmediately,
            finalizeCreation: finalizeCreation,
            stableIdentity: stableIdentity
        )
    }

    /// Creates a new box using an already configured host; connection secrets never leave the desktop.
    func createSSHWorkspace(
        name: String, inheriting source: Workspace, in tabManager: TabManager, select: Bool = false
    ) -> Workspace? {
        guard permitsImportSensitiveMutation(), let profile = source.uniConnectProfile, profile.isSSH,
              let credentialID = profile.credentialId,
              let record = UniConnectVault.shared.credentialRecord(for: credentialID),
              record.effectiveTarget != nil else { return nil }
        let workspace = installSSHWorkspace(
            name: name, color: source.customColor, connectCommand: record.connectCommand,
            credentialID: credentialID, in: tabManager, select: select, probeImmediately: false,
            finalizeCreation: false, stableIdentity: nil
        )
        workspace.uniConnectProfile?.tmuxReady = profile.tmuxReady
        requestSave()
        return workspace
    }

    private func installSSHWorkspace(
        name: String,
        color: String?,
        connectCommand: String,
        credentialID: UUID,
        in tabManager: TabManager,
        select: Bool,
        probeImmediately: Bool,
        finalizeCreation: Bool,
        stableIdentity: UUID?
    ) -> Workspace {
        let workspace = tabManager.addWorkspace(
            title: name,
            workingDirectory: nil,
            inheritWorkingDirectory: false,
            select: select,
            autoWelcomeIfNeeded: false
        )
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            importIdentity: stableIdentity ?? UUID(),
            credentialId: credentialID,
            hostLabel: UniConnectSSH.hostLabel(from: connectCommand),
            tmuxReady: false
        )
        // cmux always keeps one panel per workspace. Swap the stock terminal for a
        // markdown panel: no PTY, nothing that can steal keyboard focus from the welcome
        // page, and it disappears with the first tmux window.
        installPlaceholder(in: workspace)
        workspace.setCustomColor(color)
        if (workspace.customDescription ?? "").isEmpty {
            workspace.setCustomDescription("SSH · \(UniConnectSSH.hostLabel(from: connectCommand)) · tmux")
        }
        if finalizeCreation {
            closeUntouchedInitialWorkspaces()
            requestSave()
        }
        if probeImmediately {
            startProbe(for: workspace)
        }
        return workspace
    }

    // MARK: SSH setup (welcome page)

    func setupState(for workspace: Workspace) -> UniConnectSSHSetupState {
        if let state = setupStates[workspace.id] { return state }
        let state = UniConnectSSHSetupState(workspaceId: workspace.id)
        if workspace.uniConnectProfile?.tmuxReady == true {
            state.phase = .ready
        }
        setupStates[workspace.id] = state
        return state
    }

    func startProbe(for workspace: Workspace) {
        guard permitsImportSensitiveMutation() else { return }
        guard let profile = workspace.uniConnectProfile, profile.isSSH,
              let credentialId = profile.credentialId,
              let credentialRecord = UniConnectVault.shared.credentialRecord(for: credentialId),
              credentialRecord.effectiveTarget != nil else {
            let state = setupState(for: workspace)
            state.phase = .failed(String(
                localized: "uniconnect.ssh.setup.error.missingConnection",
                defaultValue: "The saved connection command could not be found."
            ))
            return
        }
        probes[workspace.id]?.cancel()
        let state = setupState(for: workspace)
        state.phase = .connecting
        let checkingMessage = String(
            localized: "uniconnect.ssh.setup.checking",
            defaultValue: "Connecting and checking tmux…"
        )
        state.log = ["$ \(UniConnectSSH.hostLabel(from: credentialRecord.connectCommand)) — \(checkingMessage)"]
        runProbe(
            for: workspace,
            credentialRecord: credentialRecord,
            state: state,
            install: false
        )
    }

    /// Second step of the welcome flow: the user confirmed the tmux installation.
    func installTmux(for workspace: Workspace) {
        guard permitsImportSensitiveMutation() else { return }
        guard let profile = workspace.uniConnectProfile, profile.isSSH,
              let credentialId = profile.credentialId,
              let credentialRecord = UniConnectVault.shared.credentialRecord(for: credentialId),
              credentialRecord.effectiveTarget != nil else {
            let state = setupState(for: workspace)
            state.phase = .failed(String(
                localized: "uniconnect.ssh.setup.error.missingConnection",
                defaultValue: "The saved connection command could not be found."
            ))
            return
        }
        let state = setupState(for: workspace)
        state.phase = .installing
        state.log.append(String(
            localized: "uniconnect.ssh.setup.log.installing",
            defaultValue: "⏳ Installing tmux…"
        ))
        runProbe(
            for: workspace,
            credentialRecord: credentialRecord,
            state: state,
            install: true
        )
    }

    private func runProbe(
        for workspace: Workspace,
        credentialRecord: UniConnectSSHCredentialRecord,
        state: UniConnectSSHSetupState,
        install: Bool
    ) {
        probes[workspace.id]?.cancel()
        let workspaceId = workspace.id
        let probe = UniConnectTmuxProbe(
            mode: install ? .install : .check,
            onLine: { [weak state] line in
                guard let state else { return }
                state.log.append(line)
                if state.log.count > 400 { state.log.removeFirst(state.log.count - 400) }
            },
            onFinish: { [weak self, weak workspace, weak state] outcome in
                guard let self else { return }
                self.probes.removeValue(forKey: workspaceId)
                guard let state else { return }
                switch outcome {
                case .ready:
                    state.phase = .ready
                    if let workspace, var profile = workspace.uniConnectProfile {
                        profile.tmuxReady = true
                        workspace.uniConnectProfile = profile
                        self.requestSave()
                    }
                case .needsInstall(let detail):
                    state.phase = .needsInstall(detail)
                case .failed(let message):
                    state.phase = .failed(Self.humanizeSSHFailure(message, log: state.log))
                }
            }
        )
        probes[workspace.id] = probe
        probe.start(credentialRecord: credentialRecord)
    }

    /// Pure string matching, no actor state: callable from background work (the remote
    /// updater runs its ssh script off the main actor).
    nonisolated static func humanizeSSHFailure(_ message: String, log: [String]) -> String {
        let joined = log.joined(separator: "\n").lowercased()
        if joined.contains("permission denied") || joined.contains("authentication fail") {
            return String(
                localized: "uniconnect.ssh.failure.authentication",
                defaultValue: "Authentication was rejected. Check the user, password, or key in the connection command."
            )
        }
        if joined.contains("could not resolve") || joined.contains("name or service not known") {
            return String(
                localized: "uniconnect.ssh.failure.hostResolution",
                defaultValue: "The host could not be resolved. Check the server name or IP address."
            )
        }
        if joined.contains("connection refused") || joined.contains("timed out") || joined.contains("no route") {
            return String(
                localized: "uniconnect.ssh.failure.connection",
                defaultValue: "The server could not be reached (connection refused or no response). Check the firewall, port, and network."
            )
        }
        if joined.contains("sudo") && (joined.contains("password") || joined.contains("not allowed")) {
            return String(
                localized: "uniconnect.ssh.failure.sudo",
                defaultValue: "This user does not have passwordless sudo, so tmux cannot be installed. Install it manually or connect as root."
            )
        }
        if joined.contains("gestor de paquetes desconocido") {
            return String(
                localized: "uniconnect.ssh.failure.packageManager",
                defaultValue: "No supported package manager was found. Install tmux manually and try again."
            )
        }
        if joined.contains("sshpass: command not found") || joined.contains("sshpass: not found") {
            return String(
                localized: "uniconnect.ssh.failure.sshpassMissing",
                defaultValue: "sshpass is not installed on this Mac (brew install hudochenkov/sshpass/sshpass)."
            )
        }
        return message
    }

    func editConnection(for workspace: Workspace) {
        guard permitsImportSensitiveMutation() else { return }
        guard let profile = workspace.uniConnectProfile, profile.isSSH else { return }
        UniConnectAppLock.shared.authenticateForSensitiveAction(
            reason: String(
                localized: "uniconnect.ssh.edit.authenticationReason",
                defaultValue: "Show and edit the encrypted SSH connection"
            )
        ) { [weak self, weak workspace] ok in
            guard ok, let self, let workspace else { return }
            self.editConnectionAuthenticated(for: workspace, profile: profile)
        }
    }

    private func editConnectionAuthenticated(for workspace: Workspace, profile: UniConnectWorkspaceProfile) {
        guard sshCredentialEditTasks[workspace.id] == nil,
              let oldCredentialID = profile.credentialId,
              let oldCredentialRecord = UniConnectVault.shared.credentialRecord(
                  for: oldCredentialID
              ),
              let executor = sshCommandExecutor,
              let targetResolver = sshTargetResolver else {
            presentError(
                String(
                    localized: "uniconnect.ssh.edit.unavailable",
                    defaultValue: "This SSH connection cannot be edited right now. Try again in a moment."
                )
            )
            return
        }
        let current = oldCredentialRecord.connectCommand
        let alert = NSAlert()
        alert.messageText = String(
            localized: "uniconnect.ssh.edit.title",
            defaultValue: "Edit SSH Connection"
        )
        alert.informativeText = String(
            localized: "uniconnect.ssh.edit.detail",
            defaultValue: "Enter the complete connection command. UniConnect encrypts it on this Mac and verifies every open tmux window before switching."
        )
        let input = NSTextField(string: current)
        input.frame = NSRect(x: 0, y: 0, width: 420, height: 22)
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = input
        alert.addButton(
            withTitle: String(
                localized: "uniconnect.ssh.edit.save",
                defaultValue: "Verify and Apply"
            )
        )
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let command = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.contains("\n") else { return }
        if let message = UniConnectSSH.validateConnectCommand(command) {
            presentError(
                message,
                title: String(
                    localized: "uniconnect.ssh.edit.invalid.title",
                    defaultValue: "Invalid SSH Connection"
                )
            )
            return
        }

        let windows = workspace.uniConnectTmuxSessionsByPanelId.compactMap { panelID, tmuxSession in
            workspace.panels[panelID] == nil
                ? nil
                : UniConnectSSHCredentialEditTransaction.Window(
                    workspaceID: workspace.id,
                    panelID: panelID,
                    tmuxSession: tmuxSession
                )
        }
        let transaction = UniConnectSSHCredentialEditTransaction(
            executor: executor,
            targetResolver: targetResolver
        )
        let task = Task { @MainActor [weak self, weak workspace] in
            guard let self, let workspace else { return }
            defer { self.sshCredentialEditTasks.removeValue(forKey: workspace.id) }
            do {
                var didBeginRuntimeMutation = false
                _ = try await transaction.execute(
                    oldCredentialID: oldCredentialID,
                    newConnectCommand: command,
                    windows: windows,
                    conflictingTarget: { [weak self] targets, editedWindows in
                        guard let self else { return targets.first }
                        let excluded = Set(editedWindows.map {
                            UniConnectSSHReconnectPolicy.Owner(
                                workspaceID: $0.workspaceID,
                                panelID: $0.panelID
                            )
                        })
                        return targets.compactMap { target in
                            UniConnectSSHReconnectPolicy.conflictingCandidate(
                                for: target,
                                excluding: excluded,
                                in: self.liveSSHReconnectCandidates()
                            )?.targetKey
                        }.sorted(by: Self.sshTargetSort).first
                    },
                    createCredentialRevision: { value, effectiveTarget in
                        try UniConnectVault.shared.createImmutableRevision(
                            connectCommand: value,
                            effectiveTarget: effectiveTarget
                        )
                    },
                    removeCredentialRevision: { credentialID in
                        try UniConnectVault.shared.removeOrThrow(id: credentialID)
                    },
                    commit: { [weak self, weak workspace] credentialID, effectiveTarget, editedWindows in
                        guard let self, let workspace,
                              Self.sshCredentialEditWorkspaceIsCurrent(
                                  expected: workspace,
                                  liveWorkspace: self.workspace(for: workspace.id)
                              ),
                              workspace.uniConnectProfile == profile else { return false }
                        guard Self.sshCredentialEditWindowSetMatches(
                            expected: editedWindows,
                            workspaceID: workspace.id,
                            liveTmuxSessions: workspace.uniConnectTmuxSessionsByPanelId,
                            livePanelIDs: Set(workspace.panels.keys)
                        ) else {
                            return false
                        }
                        didBeginRuntimeMutation = true
                        var updatedProfile = profile
                        updatedProfile.credentialId = credentialID
                        updatedProfile.hostLabel = UniConnectSSH.hostLabel(from: command)
                        updatedProfile.tmuxReady = true
                        updatedProfile.touch()
                        return self.applySSHConnectionRevision(
                            command: command,
                            effectiveTarget: effectiveTarget,
                            credentialID: credentialID,
                            profile: updatedProfile,
                            windows: editedWindows,
                            workspace: workspace
                        )
                    },
                    rollback: { [weak self, weak workspace] credentialID, editedWindows in
                        guard let self, let workspace,
                              credentialID == oldCredentialID else {
                            return false
                        }
                        guard didBeginRuntimeMutation else { return true }
                        return self.applySSHConnectionRevision(
                            command: oldCredentialRecord.connectCommand,
                            effectiveTarget: oldCredentialRecord.effectiveTarget,
                            credentialID: credentialID,
                            profile: profile,
                            windows: editedWindows,
                            workspace: workspace
                        )
                    },
                    persist: {
                        guard AppDelegate.shared?.uniConnectPersistSessionNow() == true else {
                            throw ImportApplicationError.persistenceFailed
                        }
                    }
                )
                self.requestSave()
            } catch let failure as UniConnectSSHCredentialEditTransaction.Failure {
                self.presentSSHCredentialEditFailure(failure)
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
        sshCredentialEditTasks[workspace.id] = task
    }

    /// Confirms an async SSH edit still targets the exact live workspace object.
    static func sshCredentialEditWorkspaceIsCurrent(
        expected: Workspace,
        liveWorkspace: Workspace?
    ) -> Bool {
        liveWorkspace === expected
    }

    /// Rejects a credential commit if a window changed while SSH preflight was suspended.
    static func sshCredentialEditWindowSetMatches(
        expected: [UniConnectSSHCredentialEditTransaction.Window],
        workspaceID: UUID,
        liveTmuxSessions: [UUID: String],
        livePanelIDs: Set<UUID>
    ) -> Bool {
        let live: Set<UniConnectSSHCredentialEditTransaction.Window> = Set(
            liveTmuxSessions.compactMap { panelID, tmuxSession in
            guard livePanelIDs.contains(panelID) else { return nil }
            return UniConnectSSHCredentialEditTransaction.Window(
                workspaceID: workspaceID,
                panelID: panelID,
                tmuxSession: tmuxSession
            )
            }
        )
        return live == Set(expected)
    }

    private func applySSHConnectionRevision(
        command: String,
        effectiveTarget: UniConnectSSHEffectiveTarget?,
        credentialID: UUID,
        profile: UniConnectWorkspaceProfile,
        windows: [UniConnectSSHCredentialEditTransaction.Window],
        workspace: Workspace
    ) -> Bool {
        struct PreparedWindow {
            let panelID: UUID
            let tmuxSession: String
            let title: String
            let launcher: String
        }

        // A legacy command-only revision cannot safely respawn remote windows during
        // rollback: ssh_config may now point its alias at a different machine.
        guard windows.isEmpty || effectiveTarget != nil else { return false }
        var prepared: [PreparedWindow] = []
        for window in windows {
            guard window.workspaceID == workspace.id,
                  workspace.panels[window.panelID] is TerminalPanel,
                  workspace.uniConnectTmuxSessionsByPanelId[window.panelID] == window.tmuxSession else {
                workspace.uniConnectProfile = profile
                return false
            }
            let title = workspace.panelCustomTitles[window.panelID]
                ?? workspace.panelTitles[window.panelID]
                ?? window.tmuxSession
            let bridge = claudeBridgePlan(
                workspace: workspace,
                panelID: window.panelID,
                credentialID: credentialID,
                windowName: title,
                tmuxSession: window.tmuxSession,
                hostLabelOverride: profile.hostLabel
            )
            guard let commandLine = UniConnectSSH.attachCommandLine(
                connectCommand: command,
                session: window.tmuxSession,
                directory: nil,
                bridge: bridge,
                existingSessionOnly: true,
                recoverMissingSession: true,
                effectiveTarget: effectiveTarget
            ), let launcher = UniConnectSSH.writeLauncherScript(
                commandLine: commandLine,
                label: window.tmuxSession
            ) else {
                workspace.uniConnectProfile = profile
                return false
            }
            prepared.append(
                PreparedWindow(
                    panelID: window.panelID,
                    tmuxSession: window.tmuxSession,
                    title: title,
                    launcher: launcher
                )
            )
        }

        workspace.uniConnectProfile = profile
        var allRespawned = true
        for window in prepared {
            let panel = workspace.respawnTerminalSurface(
                panelId: window.panelID,
                command: window.launcher,
                inheritExistingWorkingDirectory: false,
                tmuxStartCommand: window.launcher,
                focus: false,
                forceTerminateForegroundProcess: true
            )
            guard panel?.id == window.panelID else {
                allRespawned = false
                continue
            }
            workspace.uniConnectTmuxSessionsByPanelId[window.panelID] = window.tmuxSession
            workspace.uniConnectDisconnectedPanelIds.remove(window.panelID)
            workspace.setPanelCustomTitle(panelId: window.panelID, title: window.title)
        }
        return allRespawned
    }

    private static func sshTargetSort(
        _ lhs: UniConnectSSHTargetKey,
        _ rhs: UniConnectSSHTargetKey
    ) -> Bool {
        if lhs.host != rhs.host { return lhs.host < rhs.host }
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        if lhs.username != rhs.username { return (lhs.username ?? "") < (rhs.username ?? "") }
        return lhs.tmuxSession < rhs.tmuxSession
    }

    private func presentSSHCredentialEditFailure(
        _ failure: UniConnectSSHCredentialEditTransaction.Failure
    ) {
        let message: String
        switch failure {
        case .invalidConnection:
            message = String(
                localized: "uniconnect.ssh.edit.error.invalid",
                defaultValue: "The SSH command is not a supported safe connection command."
            )
        case .duplicateTarget:
            message = String(
                localized: "uniconnect.ssh.edit.error.duplicate",
                defaultValue: "Another UniConnect window already owns one of those SSH/tmux targets. Nothing was changed."
            )
        case .remoteSessionUnavailable(let session):
            message = String(
                localized: "uniconnect.ssh.edit.error.tmuxUnavailable",
                defaultValue: "tmux session \"\(session)\" is not available through the new connection. Nothing was changed."
            )
        case .credentialWriteFailed:
            message = String(
                localized: "uniconnect.ssh.edit.error.vault",
                defaultValue: "The encrypted credential revision could not be saved. Nothing was changed."
            )
        case .commitFailed, .persistenceFailed:
            message = String(
                localized: "uniconnect.ssh.edit.error.commit",
                defaultValue: "UniConnect could not switch every open window, so it restored the previous connection."
            )
        case .rollbackFailed:
            message = String(
                localized: "uniconnect.ssh.edit.error.rollback",
                defaultValue: "The connection rollback could not be completed. Keep UniConnect open and reconnect the affected windows before quitting."
            )
        case .cancelled:
            return
        }
        presentError(
            message,
            title: String(
                localized: "uniconnect.ssh.edit.error.title",
                defaultValue: "SSH Connection Was Not Changed"
            )
        )
    }

    // MARK: Windows (tabs) inside a UniConnect workspace

    /// Presents the workspace-aware chooser for every generic terminal creation action.
    func interceptNewSurface(
        in workspace: Workspace,
        placement requestedPlacement: UniConnectNewWindowPlacement? = nil
    ) -> Bool {
        guard Self.isEnabled, let profile = workspace.uniConnectProfile else { return false }
        guard permitsImportSensitiveMutation() else { return true }
        guard let placement = requestedPlacement ?? .focusedPane(in: workspace),
              placement.isAvailable(in: workspace) else { return true }
        let window = workspace.focusedTerminalPanel?.surface.uiWindow
            ?? workspace.panels.values.compactMap { ($0 as? TerminalPanel)?.surface.uiWindow }.first
            ?? hostWindow(for: workspace.owningTabManager)
        let title = workspace.customTitle ?? workspace.title
        if !profile.isSSH {
            guard let boxRoot = workspace.uniConnectLocalBoxRoot else {
                presentError(
                    String(
                        localized: "uniconnect.localWindow.new.error.missingRoot",
                        defaultValue: "This box does not have a trusted folder."
                    )
                )
                return true
            }
            let registry = CmuxVaultAgentRegistry.load(workingDirectory: boxRoot)
            let customTargets = UniConnectLocalWindowLaunchTarget.customTargets(from: registry)
            UniConnectSheet.present(on: window, size: CGSize(width: 620, height: 700)) { dismiss in
                UniConnectNewLocalWindowView(
                    workspaceName: title,
                    boxRoot: boxRoot,
                    availableCustomTargets: customTargets,
                    onCreate: { [weak self, weak workspace] request in
                        dismiss()
                        guard let self, let workspace else { return }
                        self.createLocalWindow(in: workspace, request: request, placement: placement)
                    },
                    onCancel: { dismiss() }
                )
            }
            return true
        }

        UniConnectSheet.present(on: window, size: CGSize(width: 440, height: 250)) { dismiss in
            UniConnectNewWindowView(
                workspaceName: title,
                onCreate: { [weak self, weak workspace] name, tmux in
                    dismiss()
                    guard let self, let workspace else { return }
                    self.createSSHWindow(in: workspace, name: name, tmuxSession: tmux, placement: placement)
                },
                onCancel: { dismiss() }
            )
        }
        return true
    }

    /// Creates a durable local window in its chosen folder, without changing the workspace default.
    @discardableResult
    func createLocalWindow(
        in workspace: Workspace,
        request: UniConnectNewLocalWindowRequest,
        focus: Bool = true,
        requestPersistence: Bool = true,
        placement requestedPlacement: UniConnectNewWindowPlacement? = nil
    ) -> TerminalPanel? {
        guard permitsImportSensitiveMutation() else { return nil }
        let root = workspace.uniConnectProfile == nil
            ? UniConnectLocalWindowRecord.validatedBoxRoot(request.boxRoot)
            : workspace.uniConnectLocalBoxRoot
        guard workspace.uniConnectProfile?.isSSH != true,
              let boxRoot = root,
              let placement = requestedPlacement ?? .focusedPane(in: workspace),
              placement.isAvailable(in: workspace) else {
            return nil
        }

        // The box root is its default, not a boundary around independent window folders.
        // Reassign a missing default only when no explicit folder was chosen.
        if request.workingDirectory == nil,
           !UniConnectLocalBoxRootPolicy.isAvailableDirectory(boxRoot) {
            resolveMissingLocalBoxRoot(in: workspace, missingRoot: boxRoot) { [weak self, weak workspace] in
                guard let self, let workspace else { return }
                _ = self.createLocalWindow(
                    in: workspace,
                    request: request,
                    focus: focus,
                    requestPersistence: requestPersistence,
                    placement: placement
                )
            }
            return nil
        }

        guard let workingDirectory = UniConnectLocalWindowRecord.validatedWorkingDirectory(
            request.workingDirectory ?? boxRoot,
            within: boxRoot
        ), UniConnectLocalBoxRootPolicy.isAvailableDirectory(workingDirectory) else {
            presentError(String(
                localized: "uniconnect.workspace.error.folderMissing",
                defaultValue: "Choose an existing folder."
            ))
            return nil
        }

        // Preserve the authoritative workspace identity, while launching in this window's folder.
        let initialAgentCommand = request.launchTarget
            .startupCommand(boxRoot: boxRoot, workingDirectory: workingDirectory)
        let panelID = UUID()
        let tmuxBinding = UniConnectLocalTmuxBinding.newWindow(
            panelID: panelID,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "uniconnect-development"
        )
        let tmuxLaunch = UniConnectLocalTmuxLaunchPlan(
            binding: tmuxBinding,
            workingDirectory: workingDirectory,
            initialCommand: initialAgentCommand
        )
        let launchAttempt: LocalAgentLaunchAttempt?
        if initialAgentCommand != nil {
            guard let attempt = beginLocalAgentLaunch(
                owner: .init(workspaceID: workspace.id, panelID: panelID),
                snapshot: nil,
                hasPreparedResume: false
            ) else {
                return nil
            }
            launchAttempt = attempt
        } else {
            launchAttempt = nil
        }
        guard let panel = placement.createPanel(
            in: workspace,
            panelID: panelID,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: tmuxLaunch.startupCommand()
        ) else {
            if let launchAttempt {
                failLocalAgentLaunch(launchAttempt, workspace: workspace)
            }
            presentError(
                String(
                    localized: "uniconnect.localWindow.error.createFailed",
                    defaultValue: "The local window could not be created."
                )
            )
            return nil
        }
        // Adopt a generic local workspace only after a successful explicit creation.
        // Reconcile metadata in place; existing panels and live PTYs are not replaced.
        if workspace.uniConnectProfile == nil {
            workspace.uniConnectProfile = UniConnectWorkspaceProfile(
                kind: .local, importIdentity: workspace.id, localRoot: boxRoot
            )
            workspace.uniConnectIsStarter = false
            workspace.uniConnectConfigureLocalRoot(boxRoot)
        }
        workspace.setPanelCustomTitle(panelId: panel.id, title: request.visibleName)
        workspace.uniConnectInstallLocalWindowRecord(
            UniConnectLocalWindowRecord(
                id: panel.id,
                visibleName: request.visibleName,
                boxRoot: boxRoot,
                workingDirectory: workingDirectory,
                tmuxBinding: tmuxBinding
            ),
            panelId: panel.id,
            visibleName: request.visibleName
        )
        removePlaceholders(from: workspace, keeping: panel.id)
        workspace.uniConnectProfile?.touch()
        if requestPersistence { requestSave() }
        return panel
    }

    /// Returns one immutable action projection for context menus, the rail, and recovery UI.
    func localWindowActionMenuSnapshot(
        panelID: UUID,
        workspace: Workspace
    ) -> UniConnectLocalWindowActionMenuSnapshot? {
        guard workspace.uniConnectProfile?.isSSH == false,
              let record = workspace.uniConnectLocalWindowsByPanelId[panelID] else {
            return nil
        }
        let registry = CmuxVaultAgentRegistry.load(workingDirectory: record.workingDirectory)
        return UniConnectLocalWindowActionPolicy.menuSnapshot(
            record: record,
            customTargets: UniConnectLocalWindowLaunchTarget.customTargets(from: registry),
            boxRootIsAvailable: UniConnectLocalBoxRootPolicy.hasAvailableLaunchDirectory(
                savedWorkingDirectory: record.workingDirectory,
                boxRoot: record.boxRoot
            )
        )
    }

    /// Executes the shared local-window intent used by every presentation surface.
    func performLocalWindowAction(
        _ action: UniConnectLocalWindowAction,
        panelID: UUID,
        workspace: Workspace
    ) {
        guard permitsImportSensitiveMutation() else { return }
        guard workspace.uniConnectProfile?.isSSH == false,
              let originalRecord = workspace.uniConnectLocalWindowsByPanelId[panelID] else {
            return
        }

        if action == .reopenTerminal, originalRecord.tmuxBinding != nil {
            _ = reconnectLocalWindow(panelID: panelID, in: workspace)
            return
        }

        if action == .reassignBoxRoot {
            resolveMissingLocalBoxRoot(
                in: workspace,
                missingRoot: originalRecord.boxRoot,
                showsMissingFolderAlert: false,
                onReassigned: {}
            )
            return
        }

        guard UniConnectLocalBoxRootPolicy.hasAvailableLaunchDirectory(
            savedWorkingDirectory: originalRecord.workingDirectory,
            boxRoot: originalRecord.boxRoot
        ) else {
            resolveMissingLocalBoxRoot(
                in: workspace,
                missingRoot: originalRecord.boxRoot
            ) { [weak self, weak workspace] in
                guard let self, let workspace else { return }
                self.performLocalWindowAction(
                    action,
                    panelID: panelID,
                    workspace: workspace
                )
            }
            return
        }

        guard originalRecord.runtimeState != .agent else {
            presentError(
                String(
                    localized: "uniconnect.localWindow.error.agentStillRunning",
                    defaultValue: "Use /exit to return to the shell before starting, resuming, or changing this window."
                )
            )
            return
        }

        // A hook/process observation may time out before a long-running command or an
        // undetected agent exits. Never type a new foreground command into that process.
        if !action.canDispatchForegroundCommand(
            runtimeState: originalRecord.runtimeState,
            shellIsAtPrompt: workspace.panelShellActivityStates[panelID] == .promptIdle
        ) {
            presentError(
                String(
                    localized: "uniconnect.localWindow.error.actionUnavailable",
                    defaultValue: "That saved window action is no longer available."
                )
            )
            return
        }

        if case .forgetConversation(let conversationID) = action {
            confirmForgetLocalConversation(
                conversationID,
                panelID: panelID,
                workspace: workspace,
                record: originalRecord
            )
            return
        }
        let registry = CmuxVaultAgentRegistry.load(workingDirectory: originalRecord.workingDirectory)
        let resumeSnapshot = action.resolvedResumeSnapshot(
            record: originalRecord,
            registry: registry
        )
        guard let plan = action.terminalLaunchPlan(
            record: originalRecord,
            registry: registry
        ) else {
            presentError(
                String(
                    localized: "uniconnect.localWindow.error.actionUnavailable",
                    defaultValue: "That saved window action is no longer available."
                )
            )
            return
        }

        let wasStopped = originalRecord.runtimeState == .stopped
        if case .resumeConversation(let conversationID) = action {
            guard workspace.uniConnectSelectLocalConversation(
                panelId: panelID,
                conversationID: conversationID
            ) else {
                return
            }
        }
        let recordToRestore = workspace.uniConnectLocalWindowsByPanelId[panelID] ?? originalRecord
        let tmuxReopen = wasStopped ? recordToRestore.tmuxBinding.map {
            UniConnectLocalTmuxLaunchPlan(
                binding: $0,
                workingDirectory: plan.workingDirectory,
                initialCommand: plan.startupInput?.trimmingCharacters(in: .newlines)
            )
        } : nil
        let tmuxLaunchAttempt: LocalAgentLaunchAttempt?
        if tmuxReopen?.initialCommand != nil {
            guard let attempt = beginLocalAgentLaunch(
                owner: .init(workspaceID: workspace.id, panelID: panelID),
                snapshot: resumeSnapshot,
                hasPreparedResume: resumeSnapshot != nil
            ) else {
                presentConversationAlreadyRunningError()
                return
            }
            tmuxLaunchAttempt = attempt
        } else {
            tmuxLaunchAttempt = nil
        }

        let terminal: TerminalPanel?
        if wasStopped {
            terminal = workspace.respawnTerminalSurface(
                panelId: panelID,
                command: tmuxReopen?.startupCommand() ?? Self.localLoginShellCommand,
                workingDirectory: plan.workingDirectory,
                focus: true,
                preservesPreparedLocalAgentLaunch: tmuxLaunchAttempt != nil
            )
            guard terminal != nil else {
                if let tmuxLaunchAttempt { failLocalAgentLaunch(tmuxLaunchAttempt, workspace: workspace) }
                presentError(
                    String(
                        localized: "uniconnect.localWindow.error.reopenFailed",
                        defaultValue: "The saved terminal could not be reopened."
                    )
                )
                return
            }
            // Terminal respawn intentionally clears the old process lifecycle. Put the durable
            // logical-window identity and append-only history back before changing runtime state.
            workspace.uniConnectInstallLocalWindowRecord(
                recordToRestore,
                panelId: panelID,
                visibleName: recordToRestore.visibleName
            )
            _ = workspace.uniConnectTransitionLocalWindowToShell(panelId: panelID)
        } else {
            terminal = workspace.panels[panelID] as? TerminalPanel
        }

        guard let terminal else { return }
        if tmuxReopen == nil, let startupInput = plan.startupInput {
            let owner = LocalAgentOwner(workspaceID: workspace.id, panelID: panelID)
            guard let attempt = beginLocalAgentLaunch(
                owner: owner,
                snapshot: resumeSnapshot,
                hasPreparedResume: resumeSnapshot != nil
            ) else {
                presentConversationAlreadyRunningError()
                return
            }
            if let resumeSnapshot {
                guard workspace.uniConnectPrepareLocalAgentLaunch(
                    panelId: panelID,
                    snapshot: resumeSnapshot
                ) else {
                    failLocalAgentLaunch(attempt, workspace: workspace)
                    presentError(
                        String(
                            localized: "uniconnect.localWindow.error.actionUnavailable",
                            defaultValue: "That saved window action is no longer available."
                        )
                    )
                    return
                }
            }
            workspace.sendInputWhenReady(
                startupInput,
                to: terminal,
                reason: .localAgentLaunch
            ) { [weak self, weak workspace] delivered in
                guard let self else { return }
                self.handleLocalAgentDelivery(
                    attempt,
                    delivered: delivered,
                    workspace: workspace
                )
            }
        }
        workspace.uniConnectProfile?.touch()
        requestSave()
    }

    private func presentConversationAlreadyRunningError() {
        presentError(
            String(
                localized: "uniconnect.localWindow.error.conversationAlreadyRunning",
                defaultValue: "That conversation is already running in another local window. Exit it there before resuming it here."
            )
        )
    }

    /// Replaces only the tmux client; an existing pane and its foreground agent stay alive.
    @discardableResult
    func reconnectLocalWindow(
        panelID: UUID, in workspace: Workspace, focus: Bool = true
    ) -> TerminalPanel? {
        guard permitsImportSensitiveMutation(), workspace.uniConnectProfile?.kind == .local,
              let record = workspace.uniConnectLocalWindowsByPanelId[panelID],
              let binding = record.tmuxBinding else { return nil }
        let registry = CmuxVaultAgentRegistry.load(workingDirectory: record.workingDirectory)
        let snapshot = record.runtimeState == .agent ? record.latestRestorableSnapshot(registry: registry) : nil
        reconcileActiveLocalAgentClaims()
        let resume = snapshot.flatMap { snapshot in
            guard snapshot.workingDirectory.map({ UniConnectLocalBoxRootPolicy.isAvailableDirectory($0) }) == true,
                  let claim = UniConnectLocalAgentRestoreClaimPolicy.claim(for: snapshot),
                  localAgentClaimRegistry.conflictingOwner(
                      for: claim, requester: .init(workspaceID: workspace.id, panelID: panelID)
                  ) == nil else { return nil as String? }
            guard let command = snapshot.resumeCommand, let directory = snapshot.workingDirectory else { return nil }
            return UniConnectLocalBoxRootPolicy.commandRequiringWorkingDirectory(
                command, workingDirectory: directory, boxRoot: record.boxRoot
            )
        }
        let command = UniConnectLocalTmuxLaunchPlan(
            binding: binding, workingDirectory: record.workingDirectory, initialCommand: resume
        ).startupCommand()
        let localDirectory = UniConnectLocalBoxRootPolicy.isAvailableDirectory(record.workingDirectory)
            ? record.workingDirectory : UniConnectLocalBoxRootPolicy.safeShellFallbackDirectory(
                currentDirectory: nil, missingRoot: record.workingDirectory
            )
        guard let panel = workspace.respawnTerminalSurface(
            panelId: panelID, command: command, workingDirectory: localDirectory, focus: focus
        ) else { return nil }
        workspace.uniConnectInstallLocalWindowRecord(record, panelId: panelID, visibleName: record.visibleName)
        requestSave()
        return panel
    }

    private func beginLocalAgentLaunch(
        owner: LocalAgentOwner,
        snapshot: SessionRestorableAgentSnapshot?,
        hasPreparedResume: Bool
    ) -> LocalAgentLaunchAttempt? {
        reconcileActiveLocalAgentClaims()
        // A second click while delivery/observation is still pending must not enqueue the
        // same (or another) agent command into this shell. The original attempt keeps its
        // timeout and ownership until it succeeds or rolls back visibly to manual recovery.
        guard localAgentLaunchAttempts[owner] == nil else { return nil }

        let lease: LocalAgentLease?
        if let snapshot,
           let claim = UniConnectLocalAgentRestoreClaimPolicy.claim(for: snapshot) {
            guard let reserved = localAgentClaimRegistry.reserve(claim, for: owner) else {
                return nil
            }
            lease = reserved
        } else {
            lease = nil
        }

        let attempt = LocalAgentLaunchAttempt(
            token: UUID(),
            owner: owner,
            lease: lease,
            hasPreparedResume: hasPreparedResume
        )
        localAgentLaunchAttempts[owner] = attempt
        scheduleLocalAgentLaunchTimeout(for: attempt, phase: .pendingDelivery)
        return attempt
    }

    private func handleLocalAgentDelivery(
        _ attempt: LocalAgentLaunchAttempt,
        delivered: Bool,
        workspace: Workspace?
    ) {
        guard localAgentLaunchAttempts[attempt.owner]?.token == attempt.token else { return }
        guard delivered else {
            failLocalAgentLaunch(attempt, workspace: workspace)
            return
        }
        if let lease = attempt.lease,
           !localAgentClaimRegistry.markDelivered(lease) {
            failLocalAgentLaunch(attempt, workspace: workspace)
            return
        }
        scheduleLocalAgentLaunchTimeout(for: attempt, phase: .awaitingCommand)
    }

    private func scheduleLocalAgentLaunchTimeout(
        for attempt: LocalAgentLaunchAttempt,
        phase: UniConnectLocalAgentClaimRegistry.Phase
    ) {
        localAgentLaunchTimeouts.removeValue(forKey: attempt.owner)?.cancel()
        localAgentLaunchTimeouts[attempt.owner] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  self.localAgentLaunchAttempts[attempt.owner]?.token == attempt.token else {
                return
            }
            if let lease = attempt.lease,
               self.localAgentClaimRegistry.phase(for: lease) != phase {
                return
            }
            self.failLocalAgentLaunch(
                attempt,
                workspace: self.workspace(for: attempt.owner.workspaceID)
            )
        }
    }

    private func failLocalAgentLaunch(
        _ attempt: LocalAgentLaunchAttempt,
        workspace: Workspace?
    ) {
        guard localAgentLaunchAttempts[attempt.owner]?.token == attempt.token else { return }
        localAgentLaunchAttempts.removeValue(forKey: attempt.owner)
        localAgentLaunchTimeouts.removeValue(forKey: attempt.owner)?.cancel()
        if let lease = attempt.lease {
            _ = localAgentClaimRegistry.release(lease)
        }
        if attempt.hasPreparedResume {
            _ = workspace?.uniConnectCancelPreparedLocalAgentLaunch(
                panelId: attempt.owner.panelID
            )
        } else {
            _ = workspace?.uniConnectTransitionLocalWindowToShell(
                panelId: attempt.owner.panelID
            )
        }
        requestSave()
    }

    private func cancelLocalAgentLaunchAttempt(
        for owner: LocalAgentOwner,
        transitionToShell: Bool
    ) {
        rejectedLocalAgentObservations.removeValue(forKey: owner)
        guard let attempt = localAgentLaunchAttempts.removeValue(forKey: owner) else {
            localAgentClaimRegistry.releaseAll(for: owner)
            return
        }
        localAgentLaunchTimeouts.removeValue(forKey: owner)?.cancel()
        if let lease = attempt.lease {
            _ = localAgentClaimRegistry.release(lease)
        }
        if transitionToShell {
            _ = workspace(for: owner.workspaceID)?
                .uniConnectCancelPreparedLocalAgentLaunch(panelId: owner.panelID)
        }
    }

    private func handleLocalAgentSignal(_ signal: UniConnectClaudeSessionSignal) {
        let owner = LocalAgentOwner(
            workspaceID: signal.workspaceID,
            panelID: signal.panelID
        )
        if signal.kind == .panelClosed {
            let currentWorkspace = workspace(for: owner.workspaceID)
            let hasCurrentPanel = currentWorkspace?.panels[owner.panelID] != nil
            guard Self.shouldCancelLocalAgentLaunchForPanelClosedSignal(
                signalGeneration: signal.surfaceGeneration,
                currentGeneration: currentWorkspace?.uniConnectSurfaceGeneration(panelId: owner.panelID),
                hasCurrentPanel: hasCurrentPanel
            ) else {
                return
            }
            cancelLocalAgentLaunchAttempt(for: owner, transitionToShell: false)
            return
        }
        guard signal.kind == .shellActivityChanged else { return }
        guard let currentWorkspace = workspace(for: owner.workspaceID),
              let signalGeneration = signal.surfaceGeneration,
              signalGeneration == currentWorkspace.uniConnectSurfaceGeneration(panelId: owner.panelID),
              Self.isCurrentLocalAgentShellActivitySignal(
                  signal.shellActivity,
                  currentState: currentWorkspace.panelShellActivityStates[owner.panelID],
                  runtimeState: currentWorkspace.uniConnectLocalWindowsByPanelId[owner.panelID]?.runtimeState
              ) else {
            // Notification delivery is deliberately hopped through a MainActor task. The
            // terminal may already have returned to `commandRunning` (for example after a
            // fast `/exit` -> new-agent switch), so an older `promptIdle` event must not
            // release the newly observed conversation's claim.
            return
        }
        switch signal.shellActivity {
        case Workspace.PanelShellActivityState.commandRunning.rawValue:
            guard localAgentLaunchAttempts[owner] == nil else {
                // A generic shell transition cannot prove which conversation started.
                // Keep the reservation pending until the detector supplies the exact claim.
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.reconcileActiveLocalAgentClaims()
            }
        case Workspace.PanelShellActivityState.promptIdle.rawValue:
            if let attempt = localAgentLaunchAttempts[owner],
               let lease = attempt.lease,
               localAgentClaimRegistry.phase(for: lease) != .pendingDelivery {
                failLocalAgentLaunch(attempt, workspace: workspace(for: owner.workspaceID))
            } else if localAgentLaunchAttempts[owner] == nil {
                localAgentClaimRegistry.releaseAll(for: owner)
            }
        default:
            break
        }
    }

    /// A deferred close notification belongs to an older surface when the stable panel ID
    /// has already been rebound to a replacement terminal.
    static func shouldCancelLocalAgentLaunchForPanelClosedSignal(
        signalGeneration: UUID?,
        currentGeneration: UUID?,
        hasCurrentPanel: Bool
    ) -> Bool {
        guard signalGeneration != nil else { return false }
        guard hasCurrentPanel else { return true }
        return signalGeneration == currentGeneration
    }

    static func isCurrentLocalAgentShellActivitySignal(
        _ signalState: String?,
        currentState: Workspace.PanelShellActivityState?,
        runtimeState: UniConnectLocalWindowRuntimeState? = nil
    ) -> Bool {
        guard let signalState, let currentState else { return false }
        guard signalState == currentState.rawValue else { return false }
        // An exact foreground-process observation can beat the shell integration's
        // command-running callback. Once the durable record says an agent is active,
        // an idle event from the prior process generation is no longer authoritative.
        return signalState != Workspace.PanelShellActivityState.promptIdle.rawValue
            || runtimeState != .agent
    }

    private func handleLocalAgentSurfaceReady(_ object: Any?) {
        guard let surface = object as? TerminalSurface else { return }
        for tabManager in allTabManagers() {
            for workspace in tabManager.tabs {
                guard let panelID = workspace.panels.first(where: { _, panel in
                    (panel as? TerminalPanel)?.surface === surface
                })?.key else {
                    continue
                }
                let owner = LocalAgentOwner(workspaceID: workspace.id, panelID: panelID)
                guard let attempt = localAgentLaunchAttempts[owner] else { return }
                handleLocalAgentDelivery(attempt, delivered: true, workspace: workspace)
                return
            }
        }
    }

    private func workspace(for workspaceID: UUID) -> Workspace? {
        allTabManagers().flatMap(\.tabs).first { $0.id == workspaceID }
    }

    /// Reserves an automatic restore before Ghostty can enqueue its startup input.
    func prepareAutomaticLocalAgentLaunch(
        snapshot: SessionRestorableAgentSnapshot,
        panelID: UUID,
        workspace: Workspace
    ) -> Bool {
        beginLocalAgentLaunch(
            owner: .init(workspaceID: workspace.id, panelID: panelID),
            snapshot: snapshot,
            hasPreparedResume: true
        ) != nil
    }

    func cancelAutomaticLocalAgentLaunch(panelID: UUID, workspace: Workspace) {
        cancelLocalAgentLaunchAttempt(
            for: .init(workspaceID: workspace.id, panelID: panelID),
            transitionToShell: true
        )
    }

    func authorizeLocalAgentObservation(
        snapshot: SessionRestorableAgentSnapshot,
        panelID: UUID,
        workspace: Workspace
    ) -> Bool {
        guard let claim = UniConnectLocalAgentRestoreClaimPolicy.claim(for: snapshot) else {
            return false
        }
        let owner = LocalAgentOwner(workspaceID: workspace.id, panelID: panelID)
        let pendingLease: LocalAgentLease?
        if let attempt = localAgentLaunchAttempts.removeValue(forKey: owner) {
            localAgentLaunchTimeouts.removeValue(forKey: owner)?.cancel()
            pendingLease = attempt.lease
        } else {
            pendingLease = nil
        }
        guard localAgentClaimRegistry.registerObserved(
            claim,
            for: owner,
            replacing: pendingLease
        ) != nil else {
            if rejectedLocalAgentObservations[owner] != claim {
                rejectedLocalAgentObservations[owner] = claim
                presentConversationAlreadyRunningError()
            }
            return false
        }
        rejectedLocalAgentObservations.removeValue(forKey: owner)
        return true
    }

    func localWindowDidStop(panelID: UUID, workspace: Workspace) {
        let owner = LocalAgentOwner(workspaceID: workspace.id, panelID: panelID)
        rejectedLocalAgentObservations.removeValue(forKey: owner)
        cancelLocalAgentLaunchAttempt(for: owner, transitionToShell: false)
    }

    /// Ends the old surface generation before a stable panel ID is reused by respawn.
    func localWindowWillRespawn(panelID: UUID, workspace: Workspace) {
        let owner = LocalAgentOwner(workspaceID: workspace.id, panelID: panelID)
        rejectedLocalAgentObservations.removeValue(forKey: owner)
        cancelLocalAgentLaunchAttempt(for: owner, transitionToShell: false)
        _ = workspace.uniConnectTransitionLocalWindowToShell(panelId: panelID)
    }

    func resolvingDuplicateAutomaticLocalAgentClaims(
        in snapshot: AppSessionSnapshot
    ) -> AppSessionSnapshot {
        reconcileActiveLocalAgentClaims()
        return UniConnectLocalAgentRestoreClaimPolicy.resolvingDuplicateAutomaticClaims(
            in: snapshot,
            alreadyClaimed: localAgentClaimRegistry.claimedConversations
        )
    }

    private func activeLocalAgentClaimCandidates() -> [
        UniConnectLocalAgentRestoreClaimPolicy.ActiveCandidate
    ] {
        allTabManagers().flatMap { tabManager in
            tabManager.tabs.flatMap { workspace in
                workspace.uniConnectLocalWindowsByPanelId.map { panelID, record in
                    UniConnectLocalAgentRestoreClaimPolicy.ActiveCandidate(
                        owner: .init(workspaceID: workspace.id, panelID: panelID),
                        record: record
                    )
                }
            }
        }
    }

    private func reconcileActiveLocalAgentClaims() {
        let candidates = activeLocalAgentClaimCandidates().sorted { lhs, rhs in
            if lhs.owner.workspaceID != rhs.owner.workspaceID {
                return lhs.owner.workspaceID.uuidString < rhs.owner.workspaceID.uuidString
            }
            return lhs.owner.panelID.uuidString < rhs.owner.panelID.uuidString
        }
        var desired: [UniConnectLocalAgentRestoreClaimPolicy.Claim: LocalAgentOwner] = [:]
        for candidate in candidates {
            guard candidate.record.runtimeState == .agent,
                  let conversation = candidate.record.activeConversation else {
                continue
            }
            let claim = UniConnectLocalAgentRestoreClaimPolicy.claim(for: conversation)
            if desired[claim] == nil {
                desired[claim] = candidate.owner
            }
        }
        localAgentClaimRegistry.reconcileActive(desired)
    }

    private func resolveMissingLocalBoxRoot(
        in workspace: Workspace,
        missingRoot: String,
        showsMissingFolderAlert: Bool = true,
        onReassigned: @escaping @MainActor () -> Void
    ) {
        if showsMissingFolderAlert {
            let abbreviatedRoot = (missingRoot as NSString).abbreviatingWithTildeInPath
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                localized: "uniconnect.localWindow.missingRoot.title",
                defaultValue: "Trusted Box Folder Is Missing"
            )
            alert.informativeText = String(
                localized: "uniconnect.localWindow.missingRoot.detail",
                defaultValue: "UniConnect did not start anything because \(abbreviatedRoot) is unavailable. Choose its new folder to keep this window and all saved conversations recoverable."
            )
            alert.addButton(
                withTitle: String(
                    localized: "uniconnect.localWindow.missingRoot.choose",
                    defaultValue: "Choose New Folder…"
                )
            )
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let picker = NSOpenPanel()
        picker.title = String(
            localized: "uniconnect.localWindow.missingRoot.picker.title",
            defaultValue: "Reassign Trusted Box Folder"
        )
        picker.prompt = String(
            localized: "uniconnect.localWindow.missingRoot.picker.choose",
            defaultValue: "Use This Folder"
        )
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        guard picker.runModal() == .OK,
              let selectedURL = picker.url,
              UniConnectLocalBoxRootPolicy.isAvailableDirectory(selectedURL.path) else {
            return
        }

        workspace.uniConnectConfigureLocalRoot(selectedURL.path)
        workspace.uniConnectProfile?.touch()
        requestSave()
        DispatchQueue.main.async(execute: onReassigned)
    }

    private static let localLoginShellCommand = #"exec "${SHELL:-/bin/zsh}" -l"#

    private func confirmForgetLocalConversation(
        _ conversationID: UUID,
        panelID: UUID,
        workspace: Workspace,
        record: UniConnectLocalWindowRecord
    ) {
        guard let conversation = record.conversations.first(where: { $0.id == conversationID }) else {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "uniconnect.localWindow.forget.title",
            defaultValue: "Forget \(conversation.displayName) Conversation?"
        )
        alert.informativeText = String(
            localized: "uniconnect.localWindow.forget.detail",
            defaultValue: "UniConnect will remove this saved session link from the window. The other conversation history and files in the box stay untouched."
        )
        alert.addButton(
            withTitle: String(
                localized: "uniconnect.localWindow.forget.confirm",
                defaultValue: "Forget Conversation"
            )
        )
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard workspace.uniConnectForgetLocalConversation(
            panelId: panelID,
            conversationID: conversationID
        ) else {
            return
        }
        workspace.uniConnectProfile?.touch()
        requestSave()
    }

    @discardableResult
    func createSSHWindow(
        in workspace: Workspace,
        name: String,
        tmuxSession rawSession: String,
        directory: String? = nil,
        existingSessionOnly: Bool = false,
        replacingPanelID: UUID? = nil,
        focus: Bool = true,
        requestPersistence: Bool = true,
        showErrors: Bool = true,
        placement requestedPlacement: UniConnectNewWindowPlacement? = nil
    ) -> TerminalPanel? {
        guard permitsImportSensitiveMutation() else { return nil }
        guard let profile = workspace.uniConnectProfile, profile.isSSH,
              let credentialId = profile.credentialId,
              let credentialRecord = UniConnectVault.shared.credentialRecord(for: credentialId),
              let effectiveTarget = credentialRecord.effectiveTarget else {
            if showErrors {
                presentError(String(
                    localized: "uniconnect.ssh.window.error.missingConnection",
                    defaultValue: "This box has no saved connection command."
                ))
            }
            return nil
        }
        let session = UniConnectSSH.sanitizedTmuxName(rawSession)
        guard let targetKey = UniConnectSSHTargetKey(
                  effectiveTarget: effectiveTarget,
                  tmuxSession: session
              ) else {
            if showErrors {
                presentError(
                    String(
                        localized: "uniconnect.ssh.window.invalidConnection",
                        defaultValue: "The saved SSH connection is invalid. Edit the box connection before opening this window."
                    )
                )
            }
            return nil
        }
        let excludedOwners: Set<UniConnectSSHReconnectPolicy.Owner> = replacingPanelID.map {
            [.init(workspaceID: workspace.id, panelID: $0)]
        } ?? []
        if let duplicate = UniConnectSSHReconnectPolicy.conflictingCandidate(
            for: targetKey,
            excluding: excludedOwners,
            in: liveSSHReconnectCandidates()
        ) {
            if showErrors {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(
                    localized: "uniconnect.ssh.window.duplicate.title",
                    defaultValue: "That SSH/tmux Target Is Already Open"
                )
                let duplicateWorkspace = self.workspace(for: duplicate.workspaceID)
                let existingName = duplicateWorkspace?.panelCustomTitles[duplicate.panelID]
                    ?? duplicateWorkspace?.panelTitles[duplicate.panelID]
                    ?? String(localized: "uniconnect.ssh.window.fallbackName", defaultValue: "another window")
                alert.informativeText = String(
                    localized: "uniconnect.ssh.window.duplicate.detail",
                    defaultValue: "\"\(existingName)\" already owns tmux session \"\(session)\" on this SSH endpoint. UniConnect will not open a second client on the same target."
                )
                alert.addButton(
                    withTitle: String(
                        localized: "uniconnect.ssh.window.duplicate.focus",
                        defaultValue: "Go to Window"
                    )
                )
                alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
                if alert.runModal() == .alertFirstButtonReturn {
                    if let duplicateWorkspace,
                       let pane = duplicateWorkspace.paneId(forPanelId: duplicate.panelID),
                       let tabId = duplicateWorkspace.surfaceIdFromPanelId(duplicate.panelID) {
                        duplicateWorkspace.bonsplitController.focusPane(pane)
                        duplicateWorkspace.bonsplitController.selectTab(tabId)
                        duplicateWorkspace.focusPanel(duplicate.panelID)
                    }
                }
            }
            return nil
        }
        // A reconnect/update owns the same logical window. Keeping the panel UUID lets
        // Bonsplit retain its tab, pane, ordering, selection, and bridge route identity.
        let panelID = replacingPanelID ?? UUID()
        let bridge = claudeBridgePlan(
            workspace: workspace,
            panelID: panelID,
            credentialID: credentialId,
            windowName: name,
            tmuxSession: session
        )
        guard let commandLine = UniConnectSSH.attachCommandLine(
            credentialRecord: credentialRecord,
            session: session,
            directory: directory,
            bridge: bridge,
            existingSessionOnly: existingSessionOnly
        ), let launcher = UniConnectSSH.writeLauncherScript(commandLine: commandLine, label: session) else {
            claudeBridgeRuntime?.unregister(routeID: panelID, removeToken: false)
            workspace.uniConnectClaudeBridgeStatusByPanelId.removeValue(forKey: panelID)
            if showErrors {
                presentError(String(
                    localized: "uniconnect.ssh.window.error.launcher",
                    defaultValue: "The window launcher could not be prepared."
                ))
            }
            return nil
        }
        let panel: TerminalPanel?
        if let replacingPanelID {
            panel = workspace.respawnTerminalSurface(
                panelId: replacingPanelID,
                command: launcher,
                inheritExistingWorkingDirectory: false,
                tmuxStartCommand: launcher,
                focus: focus,
                forceTerminateForegroundProcess: true
            )
        } else if let placement = requestedPlacement ?? .focusedPane(in: workspace) {
            panel = placement.createPanel(
                in: workspace,
                panelID: panelID,
                focus: focus,
                initialCommand: launcher,
                tmuxStartCommand: launcher,
                suppressWorkspaceRemoteStartupCommand: true
            )
        } else {
            panel = nil
        }
        guard let panel else {
            claudeBridgeRuntime?.unregister(routeID: panelID, removeToken: false)
            workspace.uniConnectClaudeBridgeStatusByPanelId.removeValue(forKey: panelID)
            if showErrors {
                presentError(String(
                    localized: "uniconnect.ssh.window.error.open",
                    defaultValue: "The window could not be opened."
                ))
            }
            return nil
        }
        workspace.uniConnectTmuxSessionsByPanelId[panel.id] = session
        workspace.setPanelCustomTitle(panelId: panel.id, title: name)
        removePlaceholders(from: workspace, keeping: panel.id)
        workspace.uniConnectProfile?.touch()
        if requestPersistence { requestSave() }
        return panel
    }

    fileprivate func claudeBridgePlan(
        workspace: Workspace,
        panelID: UUID,
        credentialID: UUID,
        windowName: String,
        tmuxSession: String,
        hostLabelOverride: String? = nil
    ) -> ClaudeBridgeConnectionPlan? {
        guard let runtime = claudeBridgeRuntime else {
            if claudeBridgeListenerUnavailable {
                workspace.uniConnectClaudeBridgeStatusByPanelId[panelID] = .unavailable(.localListener)
            }
            return nil
        }
        let workspaceName = (workspace.customTitle ?? workspace.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hostLabel = hostLabelOverride ?? workspace.uniConnectProfile?.hostLabel ?? "remote"
        let route = ClaudeBridgeRoute(
            id: panelID,
            workspaceID: workspace.id,
            surfaceID: panelID,
            credentialID: credentialID,
            hostLabel: hostLabel,
            workspaceName: workspaceName.isEmpty ? "UniConnect" : workspaceName,
            windowName: windowName.isEmpty ? tmuxSession : windowName,
            tmuxSession: tmuxSession
        )
        return runtime.connectionPlan(for: route)
    }

    private func installPlaceholder(in workspace: Workspace) {
        let terminalIds = Set(workspace.panels.keys)
        guard let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let markdown = workspace.newMarkdownSurface(
                inPane: pane,
                filePath: UniConnectPaths.placeholderMarkdownFile.path,
                focus: false
              ) else {
            workspace.uniConnectPlaceholderPanelIds = terminalIds
            return
        }
        workspace.uniConnectPlaceholderPanelIds = [markdown.id]
        for panelId in terminalIds where workspace.panels[panelId] != nil {
            _ = workspace.closePanel(panelId, force: true)
        }
    }

    // MARK: Reconnecting a dropped tmux window

    /// How many automatic attempts per window before leaving it to the user.
    private static let maxReconnectAttempts = 3
    /// An outage budget and flight follow the remote endpoint/tmux target across boxes
    /// and immutable credential revisions, not a disposable local terminal process.
    private typealias ReconnectKey = UniConnectSSHTargetKey
    private var reconnectAttempts: [ReconnectKey: Int] = [:]
    private var reconnectTasks: [ReconnectKey: Task<Void, Never>] = [:]
    private var reconnectStabilityTasks: [ReconnectKey: Task<Void, Never>] = [:]
    private let reconnectFlights = UniConnectSSHReconnectFlightRegistry()
    private var reconnectFlightLeases: [ReconnectKey: UniConnectSSHReconnectFlightRegistry.Lease] = [:]
    private var reconnectAllTask: Task<Void, Never>?
    private var reconnectAllGeneration: UInt64 = 0
    /// Re-entrancy guard: closing the dead panel and creating the replacement both select
    /// tabs, and bonsplit reports programmatic selections exactly like user clicks. Without
    /// this the app recursed until the stack blew up.
    private var reconnectDepth = 0
    var isReconnecting: Bool { reconnectDepth > 0 }

    private func sshTargetKey(panelID: UUID, in workspace: Workspace) -> UniConnectSSHTargetKey? {
        guard workspace.panels[panelID] != nil,
              let tmuxSession = workspace.uniConnectTmuxSessionsByPanelId[panelID],
              let profile = workspace.uniConnectProfile,
              profile.isSSH,
              let credentialID = profile.credentialId,
              let record = UniConnectVault.shared.credentialRecord(for: credentialID),
              let effectiveTarget = record.effectiveTarget else {
            return nil
        }
        return UniConnectSSHTargetKey(
            effectiveTarget: effectiveTarget,
            tmuxSession: tmuxSession
        )
    }

    private func liveSSHReconnectCandidates() -> [UniConnectSSHReconnectPolicy.Candidate] {
        allTabManagers().flatMap { tabManager in
            tabManager.tabs.flatMap { workspace in
                workspace.uniConnectTmuxSessionsByPanelId.compactMap { panelID, tmuxSession in
                    guard workspace.panels[panelID] != nil else { return nil }
                    return UniConnectSSHReconnectPolicy.Candidate(
                        workspaceID: workspace.id,
                        panelID: panelID,
                        tmuxSession: tmuxSession,
                        targetKey: sshTargetKey(panelID: panelID, in: workspace)
                    )
                }
            }
        }
    }

    func hasConflictingLiveSSHTarget(
        _ target: UniConnectSSHTargetKey,
        workspaceID: UUID,
        panelID: UUID
    ) -> Bool {
        let requester = UniConnectSSHReconnectPolicy.Owner(
            workspaceID: workspaceID,
            panelID: panelID
        )
        let candidates = liveSSHReconnectCandidates()
        guard candidates.contains(where: { $0.targetKey == target && $0.owner == requester }) else {
            return candidates.contains { $0.targetKey == target }
        }
        return UniConnectSSHReconnectPolicy.canonicalOwner(
            for: target,
            in: candidates
        ) != requester
    }

    /// Re-attaches a tmux window whose ssh client died, with a growing delay. The dead
    /// process is respawned behind the same surface identity, keeping name, pane, position,
    /// pinning, notification state, and tmux binding.
    func scheduleReconnect(panelId: UUID, in workspace: Workspace) {
        guard permitsImportSensitiveMutation() else { return }
        guard Self.isEnabled, !isReconnecting,
              workspace.uniConnectDisconnectedPanelIds.contains(panelId),
              let tmuxSession = workspace.uniConnectTmuxSessionsByPanelId[panelId],
              let key = sshTargetKey(panelID: panelId, in: workspace) else { return }
        guard !hasConflictingLiveSSHTarget(
            key,
            workspaceID: workspace.id,
            panelID: panelId
        ) else { return }
        cancelReconnectStability(for: key)
        guard reconnectTasks[key] == nil else { return }
        guard let attempt = UniConnectSSHReconnectPolicy.nextAttempt(
            trigger: .automatic,
            isDisconnected: true,
            attemptsSpent: reconnectAttempts[key] ?? 0,
            maximumAutomaticAttempts: Self.maxReconnectAttempts,
            hasReconnectInFlight: reconnectFlights.contains(key)
        ) else { return }
        reconnectAttempts[key] = attempt
        let delay = Double(attempt) * 4.0
        reconnectTasks[key] = Task { @MainActor [weak self, weak workspace] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            defer { self.reconnectTasks.removeValue(forKey: key) }
            guard let workspace,
                  workspace.panels[panelId] != nil,
                  workspace.uniConnectTmuxSessionsByPanelId[panelId] == tmuxSession else {
                self.reconnectAttempts.removeValue(forKey: key)
                return
            }
            self.reconnect(panelId: panelId, in: workspace, attempt: attempt, key: key)
        }
    }

    private func reconnect(panelId: UUID, in workspace: Workspace, attempt: Int, key: ReconnectKey) {
        guard permitsImportSensitiveMutation() else { return }
        guard !isReconnecting,
              sshTargetKey(panelID: panelId, in: workspace) == key,
              let flight = reconnectFlights.begin(key) else { return }
        reconnectFlightLeases[key] = flight
        guard let session = workspace.uniConnectTmuxSessionsByPanelId[panelId],
              session == key.tmuxSession,
              workspace.panels[panelId] != nil,
              let profile = workspace.uniConnectProfile,
              let credentialId = profile.credentialId,
              let credentialRecord = UniConnectVault.shared.credentialRecord(for: credentialId),
              credentialRecord.effectiveTarget != nil else {
            finishReconnectFlight(flight)
            return
        }
        let disconnectedSuffix = String(
            localized: "uniconnect.window.disconnectedSuffix",
            defaultValue: " · disconnected"
        )
        let title = [disconnectedSuffix, " · disconnected", " · desconectada"].reduce(
            workspace.panelCustomTitles[panelId] ?? workspace.panelTitles[panelId] ?? session
        ) { partial, suffix in
            partial.hasSuffix(suffix) ? String(partial.dropLast(suffix.count)) : partial
        }
        let bridge = claudeBridgePlan(
            workspace: workspace,
            panelID: panelId,
            credentialID: credentialId,
            windowName: title,
            tmuxSession: session
        )
        guard let commandLine = UniConnectSSH.attachCommandLine(
            credentialRecord: credentialRecord,
            session: session,
            directory: nil,
            bridge: bridge,
            existingSessionOnly: true,
            recoverMissingSession: true
        ), let launcher = UniConnectSSH.writeLauncherScript(commandLine: commandLine, label: session) else {
            // Keep the existing route/token alive. A failed reconnect preparation must not
            // sever notifications from the logical window that still owns this panel ID.
            finishReconnectFlight(flight)
            return
        }
        reconnectDepth += 1
        defer { reconnectDepth -= 1 }
        guard workspace.respawnTerminalSurface(
            panelId: panelId,
            command: launcher,
            inheritExistingWorkingDirectory: false,
            tmuxStartCommand: launcher,
            focus: false,
            forceTerminateForegroundProcess: true
        ) != nil else {
            // The bridge route is keyed by the stable panel ID and remains valid for retry.
            finishReconnectFlight(flight)
            return
        }
        workspace.uniConnectDisconnectedPanelIds.remove(panelId)
        workspace.setPanelCustomTitle(panelId: panelId, title: title)
        scheduleReconnectStabilityCheck(
            panelId: panelId,
            in: workspace,
            key: key,
            flight: flight
        )
        requestSave()
        NSLog("[UniConnect] reconectando %@ (intento %d)", session, attempt)
    }

    /// Clears an outage budget only after the replacement has remained alive long enough
    /// for immediate SSH/auth/tmux failures to report their child exit. A failure during
    /// this window marks the same panel disconnected and spends the next attempt.
    private func scheduleReconnectStabilityCheck(
        panelId: UUID,
        in workspace: Workspace,
        key: ReconnectKey,
        flight: UniConnectSSHReconnectFlightRegistry.Lease
    ) {
        cancelReconnectStability(for: key, finishingFlight: false)
        reconnectStabilityTasks[key] = Task { @MainActor [weak self, weak workspace] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard let self else { return }
            defer {
                self.reconnectStabilityTasks.removeValue(forKey: key)
                self.finishReconnectFlight(flight)
            }
            guard let workspace,
                  workspace.panels[panelId] != nil,
                  workspace.uniConnectTmuxSessionsByPanelId[panelId] == key.tmuxSession,
                  !workspace.uniConnectDisconnectedPanelIds.contains(panelId) else { return }
            self.reconnectAttempts.removeValue(forKey: key)
        }
    }

    private func cancelReconnectStability(
        for key: ReconnectKey,
        finishingFlight: Bool = true
    ) {
        reconnectStabilityTasks.removeValue(forKey: key)?.cancel()
        if finishingFlight, let flight = reconnectFlightLeases[key] {
            finishReconnectFlight(flight)
        }
    }

    private func finishReconnectFlight(_ flight: UniConnectSSHReconnectFlightRegistry.Lease) {
        guard reconnectFlights.finish(flight) else { return }
        if reconnectFlightLeases[flight.target] == flight {
            reconnectFlightLeases.removeValue(forKey: flight.target)
        }
    }

    /// Stops every automatic entrypoint after a permanent launcher failure. A deliberate
    /// reconnect still resets this target's budget after the user repairs its setup.
    func stopAutomaticReconnect(panelId: UUID, in workspace: Workspace) {
        guard let key = sshTargetKey(panelID: panelId, in: workspace) else { return }
        reconnectTasks.removeValue(forKey: key)?.cancel()
        cancelReconnectStability(for: key)
        reconnectAttempts[key] = Self.maxReconnectAttempts
    }

    /// Reconnects one SSH/tmux window. A user-forced call also replaces a hung connection
    /// that macOS has not reported as disconnected yet, while automatic calls stay bounded.
    @discardableResult
    func reconnectNow(panelId: UUID, in workspace: Workspace, userInitiated: Bool = true) -> Bool {
        guard permitsImportSensitiveMutation() else { return false }
        guard Self.isEnabled, !isReconnecting,
              workspace.uniConnectTmuxSessionsByPanelId[panelId] != nil,
              let key = sshTargetKey(panelID: panelId, in: workspace) else { return false }
        guard !hasConflictingLiveSSHTarget(
            key,
            workspaceID: workspace.id,
            panelID: panelId
        ) else { return false }
        let trigger: UniConnectSSHReconnectTrigger = userInitiated ? .userForced : .automatic
        if userInitiated {
            reconnectTasks.removeValue(forKey: key)?.cancel()
            cancelReconnectStability(for: key)
            reconnectAttempts.removeValue(forKey: key)
        }
        guard let attempt = UniConnectSSHReconnectPolicy.nextAttempt(
            trigger: trigger,
            isDisconnected: workspace.uniConnectDisconnectedPanelIds.contains(panelId),
            attemptsSpent: reconnectAttempts[key] ?? 0,
            maximumAutomaticAttempts: Self.maxReconnectAttempts,
            hasReconnectInFlight: reconnectFlights.contains(key)
        ) else { return false }
        reconnectAttempts[key] = attempt
        reconnect(panelId: panelId, in: workspace, attempt: attempt, key: key)
        return true
    }

    /// Force-reconnects every open SSH/tmux window, including connections that are merely hung.
    func reconnectAllSSHWindowsNow() {
        guard permitsImportSensitiveMutation() else { return }
        guard Self.isEnabled else { return }
        let targets = UniConnectSSHReconnectPolicy.deduplicatedCandidates(
            liveSSHReconnectCandidates().filter { $0.targetKey != nil }
        )
        if targets.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "uniconnect.reconnect.none.title",
                defaultValue: "No SSH Windows to Reconnect"
            )
            alert.informativeText = String(
                localized: "uniconnect.reconnect.none.detail",
                defaultValue: "Open an SSH/tmux window before forcing a reconnect."
            )
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }
        reconnectAllTask?.cancel()
        reconnectAllGeneration &+= 1
        let generation = reconnectAllGeneration
        reconnectAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.reconnectAllGeneration == generation {
                    self.reconnectAllTask = nil
                }
            }
            for (index, target) in targets.enumerated() {
                if index > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(400))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled,
                      let workspace = self.allTabManagers()
                        .flatMap(\.tabs)
                        .first(where: { $0.id == target.workspaceID }),
                      workspace.uniConnectTmuxSessionsByPanelId[target.panelID] == target.tmuxSession else {
                    continue
                }
                self.reconnectNow(panelId: target.panelID, in: workspace, userInitiated: true)
            }
        }
    }

    /// Force-reconnects the SSH/tmux windows belonging to the supplied boxes.
    func reconnectSSHWindowsNow(in workspaces: [Workspace]) {
        guard permitsImportSensitiveMutation() else { return }
        let candidates = workspaces.flatMap { workspace in
            workspace.uniConnectTmuxSessionsByPanelId.compactMap { panelID, tmuxSession in
                workspace.panels[panelID] == nil
                    ? nil
                    : UniConnectSSHReconnectPolicy.Candidate(
                        workspaceID: workspace.id,
                        panelID: panelID,
                        tmuxSession: tmuxSession,
                        targetKey: sshTargetKey(panelID: panelID, in: workspace)
                    )
            }
        }
        let targets = UniConnectSSHReconnectPolicy.deduplicatedCandidates(
            candidates.filter { $0.targetKey != nil }
        )
        guard !targets.isEmpty else { return }
        reconnectAllTask?.cancel()
        reconnectAllGeneration &+= 1
        let generation = reconnectAllGeneration
        reconnectAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.reconnectAllGeneration == generation {
                    self.reconnectAllTask = nil
                }
            }
            for (index, target) in targets.enumerated() {
                if index > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(400))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled,
                      let workspace = workspaces.first(where: { $0.id == target.workspaceID }),
                      workspace.panels[target.panelID] != nil,
                      workspace.uniConnectTmuxSessionsByPanelId[target.panelID] == target.tmuxSession else {
                    continue
                }
                self.reconnectNow(
                    panelId: target.panelID,
                    in: workspace,
                    userInitiated: true
                )
            }
        }
    }

    private func removePlaceholders(from workspace: Workspace, keeping keep: UUID) {
        var placeholders = workspace.uniConnectPlaceholderPanelIds.subtracting([keep])
        // First tmux window of the box: every other panel is a placeholder (the markdown
        // stand-in, or a stock terminal restored from an older snapshot) → drop it too.
        let boundPanels = workspace.panels.keys.filter { workspace.uniConnectTmuxSessionsByPanelId[$0] != nil }
        if boundPanels == [keep] {
            for panelId in workspace.panels.keys where panelId != keep {
                placeholders.insert(panelId)
            }
        }
        workspace.uniConnectPlaceholderPanelIds.removeAll()
        workspace.withClosedPanelHistorySuppressed {
            for panelId in placeholders where workspace.panels[panelId] != nil {
                _ = workspace.closePanel(panelId, force: true)
            }
        }
        _ = workspace.uniConnectRemoveStaleUnboundSSHTerminals()
    }

    /// Repairs snapshots produced by the legacy import rollback race: an SSH box with
    /// real tmux windows must not retain the stock local `~` terminal as another window.
    @discardableResult
    private func reconcileUnboundSSHTerminals() -> Bool {
        var changed = false
        for tabManager in allTabManagers() {
            for workspace in tabManager.tabs {
                changed = workspace.uniConnectRemoveStaleUnboundSSHTerminals() || changed
            }
        }
        if changed {
            requestSave()
        }
        return changed
    }

    private func reconcileUnboundSSHTerminalsAndPersist(
        using adapter: UniConnectLiveImportAdapter
    ) async {
        guard reconcileUnboundSSHTerminals() else { return }
        do {
            try await adapter.persistDurably()
        } catch {
            // Keep the normal debounced session save armed. The in-memory repair is
            // safe, but startup/import must not claim its durable boundary succeeded.
            NSLog("[UniConnect] stale SSH placeholder repair could not be persisted immediately")
        }
    }

    // MARK: Startup seed (UNICONNECT_IMPORT_SEED=<path>)

    /// Recovers any interrupted import, then applies an explicitly configured startup seed.
    /// A keyed marker is written only after the resulting state is durably persisted.
    func applyStartupSeedIfNeeded() {
        guard Self.isEnabled else { return }
        let securedSeedCount = UniConnectBackup.secureAppOwnedStartupSeeds(
            in: UniConnectPaths.directory,
            vault: .shared
        )
        if securedSeedCount > 0 {
            NSLog("[UniConnect] secured %d app-owned startup seed file(s)", securedSeedCount)
        }
        guard importTask == nil,
              let transaction = importTransaction,
              let adapter = try? liveImportAdapter(),
              let importMutationGate,
              let lease = try? importMutationGate.acquire() else {
            return
        }
        importTask = Task { @MainActor [weak self] in
            defer { _ = importMutationGate.release(lease) }
            guard let self else { return }
            defer { self.importTask = nil }
            _ = await importMutationGate.withLease(lease) {
                guard await self.recoverInterruptedImportIfNeeded(
                    transaction: transaction,
                    adapter: adapter
                ) else {
                    return
                }
                await self.reconcileUnboundSSHTerminalsAndPersist(using: adapter)
                if let hooks = TestHooks.current,
                   hooks.exportPath != nil,
                   ProcessInfo.processInfo.environment["UNICONNECT_IMPORT_SEED"] == nil {
                    self.exportConfiguration()
                    return
                }
                await self.applyStartupSeed(transaction: transaction, adapter: adapter)
            }
        }
    }

    private func recoverInterruptedImportIfNeeded(
        transaction: UniConnectImportTransaction,
        adapter: UniConnectLiveImportAdapter
    ) async -> Bool {
        guard !didRecoverInterruptedImport else { return true }
        let result = await transaction.recoverInterruptedTransaction(adapter: adapter)
        switch result {
        case nil, .some(.noChanges), .some(.committed), .some(.rolledBack):
            didRecoverInterruptedImport = true
            return true
        case .some(.failedBeforeMutation), .some(.rollbackFailed):
            NSLog("[UniConnect] interrupted import recovery failed; startup seed skipped")
            presentError(String(
                localized: "uniconnect.import.error.recoveryFailed",
                defaultValue: "An interrupted import could not be recovered safely. The startup seed was not applied."
            ))
            return false
        }
    }

    private func applyStartupSeed(
        transaction: UniConnectImportTransaction,
        adapter: UniConnectLiveImportAdapter
    ) async {
        // Seed source: the environment variable, or a `seed.json` dropped into the UniConnect
        // directory (first-run provisioning without touching the command line). Applied once.
        let envPath = ProcessInfo.processInfo.environment["UNICONNECT_IMPORT_SEED"]
        let dropIn = UniConnectPaths.directory.appendingPathComponent("seed.json")
        let url: URL
        if let envPath, !envPath.isEmpty {
            url = URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath)
        } else if FileManager.default.fileExists(atPath: dropIn.path) {
            url = dropIn
        } else {
            return
        }
        let managesDropIn = url.standardizedFileURL == dropIn.standardizedFileURL
        let data: Data
        do {
            data = managesDropIn
                ? try UniConnectAtomicFileWriter.readPrivateFile(
                    at: url,
                    repairPermissions: true
                )
                : try Data(contentsOf: url)
        } catch {
            NSLog("[UniConnect] startup seed is not readable")
            return
        }
        let force = ProcessInfo.processInfo.environment["UNICONNECT_IMPORT_SEED_FORCE"] == "1"
        let originalMarker = startupSeedMarker(for: data)
        let wasAlreadyApplied = FileManager.default.fileExists(atPath: originalMarker.path)
            && !force
        let isReadableSplitSeed = UniConnectBackup.isReadableLocalBackupManifest(data)
        if wasAlreadyApplied && (!managesDropIn || isReadableSplitSeed) {
            return
        }

        let source: UniConnectImportSourceDocument
        var markerData = data
        do {
            if isReadableSplitSeed {
                source = try UniConnectBackup.readReadableBackupSource(
                    at: url,
                    vault: .shared
                )
            } else {
                switch try UniConnectBackup.inspectDetailed(data: data) {
                case .plain(let parsed):
                    source = parsed
                    if managesDropIn {
                        // The app owns this drop-in path. Convert it before any mutation so
                        // a crash, validation failure, or partial import cannot leave an SSH
                        // password in a long-lived JSON configuration file.
                        markerData = try UniConnectBackup.securePlainStartupSeed(
                            document: parsed.document,
                            at: url,
                            vault: .shared
                        )
                    }
                case .encrypted(let container):
                    if wasAlreadyApplied { return }
                    guard let hooks = TestHooks.current, let passphrase = hooks.passphrase else {
                        NSLog("[UniConnect] encrypted startup seed requires interactive import")
                        return
                    }
                    source = UniConnectImportSourceDocument(
                        document: try UniConnectBackup.decrypt(
                            container: container,
                            passphrase: passphrase
                        ),
                        sourceMap: .empty
                    )
                }
            }
        } catch {
            NSLog("[UniConnect] startup seed was rejected")
            return
        }

        let marker = startupSeedMarker(for: markerData)
        if wasAlreadyApplied {
            do {
                try UniConnectAtomicFileWriter.write(Data(), to: marker)
            } catch {
                NSLog("[UniConnect] secured startup seed marker could not be migrated")
            }
            return
        }
        if FileManager.default.fileExists(atPath: marker.path), !force {
            return
        }

        let prepared = makePreparedImport(for: source)
        let selection = UniConnectImportSelection.allMutations(in: prepared.plan)
        let result = await transaction.execute(
            prepared: prepared,
            selection: selection,
            adapter: adapter
        )
        switch result {
        case .committed, .noChanges:
            // A partial seed remains eligible on the next launch so rejected declarations
            // are never silently forgotten after its safe rows have been reconciled.
            guard !prepared.plan.hasBlockingIssues else {
                NSLog("[UniConnect] startup seed retained unresolved declarations")
                return
            }
            do {
                try await adapter.persistDurably()
                try UniConnectAtomicFileWriter.write(Data(), to: marker)
                NSLog(
                    "[UniConnect] startup seed reconciled: %d selected of %d",
                    selection.rowIDs.count,
                    prepared.plan.rows.count
                )
            } catch {
                NSLog("[UniConnect] startup seed marker was not written because persistence failed")
            }
        case .failedBeforeMutation, .rolledBack, .rollbackFailed:
            NSLog("[UniConnect] startup seed transaction did not commit")
        }
    }

    private func startupSeedMarker(for data: Data) -> URL {
        let digest = HMAC<SHA256>.authenticationCode(
            for: data,
            using: UniConnectMasterKey.load()
        ).map { String(format: "%02x", $0) }.joined()
        return UniConnectPaths.directory.appendingPathComponent(
            "seed-\(digest.prefix(16)).applied"
        )
    }

    /// Drops the stock empty workspace the app booted with (the empty-state box, or the
    /// legacy untouched "~" box) once a real box exists in that window.
    func closeUntouchedInitialWorkspaces() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for tabManager in allTabManagers() {
            for workspace in tabManager.tabs where tabManager.tabs.count > 1 {
                let isStarter = workspace.uniConnectShowsStarter
                let isLegacyBlank = workspace.uniConnectProfile == nil
                    && workspace.customTitle == nil
                    && workspace.panels.count == 1
                    && workspace.panels.values.first is TerminalPanel
                    && workspace.currentDirectory == home
                if isStarter || isLegacyBlank {
                    tabManager.closeWorkspace(workspace, recordHistory: false)
                }
            }
        }
    }

    // MARK: Migration from cmux (explicit, on demand)

    /// cmux's session file, read-only. UniConnect never writes there.
    static var cmuxSessionFileURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("cmux/session-com.cmuxterm.app.json")
    }

    /// Turns cmux's own session snapshot into a UniConnect document: every workspace becomes
    /// a local box (name, colour, group, folder) and every terminal keeps its folder and,
    /// when cmux recorded one, its Claude session id for `--resume`.
    static func documentFromCmuxSnapshot(_ snapshot: AppSessionSnapshot) -> UniConnectDocument {
        var workspaces: [UniConnectDocument.Workspace] = []
        for window in snapshot.windows {
            let groups = window.tabManager.workspaceGroups ?? []
            for ws in window.tabManager.workspaces {
                let name = (ws.customTitle?.isEmpty == false ? ws.customTitle : nil) ?? ws.processTitle
                let boxRoot = UniConnectLocalWindowRecord.validatedBoxRoot(
                    ws.uniConnect?.localRoot ?? ws.currentDirectory
                )
                    ?? UniConnectLocalWindowRecord(boxRoot: "~").boxRoot
                let windows: [UniConnectDocument.Window] = ws.panels.compactMap { panel in
                    guard panel.type == .terminal else { return nil }
                    let title = (panel.customTitle?.isEmpty == false ? panel.customTitle : nil) ?? panel.title
                    let reportedWorkingDirectory = panel.terminal?.workingDirectory
                        ?? panel.directory
                    let workingDirectory = reportedWorkingDirectory.flatMap {
                        UniConnectLocalWindowRecord.validatedWorkingDirectory(
                            $0,
                            within: boxRoot
                        )
                    }
                        ?? panel.terminal?.uniConnectLocalWindow?.workingDirectory
                        ?? boxRoot
                    let agent = panel.terminal?.agent
                    var localWindow = panel.terminal?.uniConnectLocalWindow
                        ?? UniConnectLocalWindowRecord.migratingLegacy(
                            id: panel.id,
                            visibleName: title,
                            boxRoot: boxRoot,
                            workingDirectory: workingDirectory,
                            agent: agent,
                            claudeSession: agent.flatMap {
                                $0.kind == .claude ? $0.sessionId : nil
                            },
                            wasAgentRunning: panel.terminal?.wasAgentRunning
                        )
                    _ = localWindow.reconcileIdentity(
                        visibleName: title,
                        boxRoot: boxRoot,
                        workingDirectory: workingDirectory,
                        at: localWindow.updatedAt
                    )
                    if let agent {
                        _ = localWindow.record(agent, at: localWindow.updatedAt)
                        if panel.terminal?.wasAgentRunning == false {
                            _ = localWindow.transitionToShell(at: localWindow.updatedAt)
                        }
                    }
                    return UniConnectDocument.Window(
                        name: title,
                        tmux: nil,
                        claudeSession: localWindow.legacyClaudeSession,
                        cwd: localWindow.workingDirectory,
                        isPinned: panel.isPinned ? true : nil,
                        localWindow: localWindow
                    )
                }
                workspaces.append(UniConnectDocument.Workspace(
                    id: ws.workspaceId,
                    name: name.isEmpty ? "cmux" : name,
                    kind: .local,
                    color: ws.customColor,
                    group: ws.groupId.flatMap { id in groups.first(where: { $0.id == id })?.name },
                    isPinned: ws.isPinned ? true : nil,
                    cwd: boxRoot,
                    connect: nil,
                    windows: windows
                ))
            }
        }
        return UniConnectDocument(workspaces: workspaces, savedAt: Date(timeIntervalSince1970: snapshot.createdAt))
    }

    /// "Migrar cajas desde cmux…": reads cmux's session (never modifies it), shows the
    /// usual import preview and creates the boxes here. cmux keeps everything as it was.
    func migrateFromCmux() {
        guard let url = Self.cmuxSessionFileURL, FileManager.default.fileExists(atPath: url.path) else {
            presentError(
                String(
                    localized: "uniconnect.migration.none.detail",
                    defaultValue: "No cmux session was found on this Mac (Application Support/cmux/session-com.cmuxterm.app.json)."
                ),
                title: String(
                    localized: "uniconnect.migration.none.title",
                    defaultValue: "Nothing to Migrate"
                )
            )
            return
        }
        guard let snapshot = SessionPersistenceStore.load(fileURL: url) else {
            presentError(
                String(
                    localized: "uniconnect.migration.readFailed.detail",
                    defaultValue: "The cmux session could not be read. cmux was not modified."
                ),
                title: String(
                    localized: "uniconnect.migration.title",
                    defaultValue: "Migration"
                )
            )
            return
        }
        let document = Self.documentFromCmuxSnapshot(snapshot)
        guard !document.workspaces.isEmpty else {
            presentError(
                String(
                    localized: "uniconnect.migration.empty.detail",
                    defaultValue: "The cmux session has no boxes."
                ),
                title: String(
                    localized: "uniconnect.migration.none.title",
                    defaultValue: "Nothing to Migrate"
                )
            )
            return
        }
        UniConnectAppLock.shared.authenticateForSensitiveAction(
            reason: String(
                localized: "uniconnect.migration.authenticationReason",
                defaultValue: "Migrate boxes from cmux"
            )
        ) { [weak self] ok in
            guard ok, let self else { return }
            self.previewImport(UniConnectImportSourceDocument(
                document: document,
                sourceMap: .empty
            ))
        }
    }

    // MARK: Persist / export / import

    func allTabManagers() -> [TabManager] {
        AppDelegate.shared?.uniConnectAllTabManagers() ?? []
    }

    func requestSave() {
        AppDelegate.shared?.uniConnectRequestSessionSave()
    }

    func persistNow(showConfirmation: Bool = true) {
        guard manualSaveTask == nil, permitsImportSensitiveMutation() else { return }
        manualSaveTask = Task { @MainActor [weak self] in
            let resumeIndexes = await ProcessDetectedResumeIndexes.load()
            guard let self else { return }
            defer { self.manualSaveTask = nil }
            guard !Task.isCancelled, self.permitsImportSensitiveMutation() else { return }
            self.finishManualSave(resumeIndexes: resumeIndexes, showConfirmation: showConfirmation)
        }
    }

    private func finishManualSave(
        resumeIndexes: ProcessDetectedResumeIndexes,
        showConfirmation: Bool
    ) {
        guard AppDelegate.shared?.uniConnectPersistSessionNow(resumeIndexes: resumeIndexes) == true else {
            presentError(String(
                localized: "uniconnect.backup.sessionSaveFailed",
                defaultValue: "The app session could not be written to disk. No complete backup was confirmed."
            ))
            return
        }
        do {
            let url = try UniConnectBackup.persistNow(
                tabManagers: allTabManagers(),
                restorableAgentIndex: resumeIndexes.restorableAgentIndex
            )
            if showConfirmation {
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "uniconnect.backup.saved.title",
                    defaultValue: "Saved"
                )
                alert.informativeText = String.localizedStringWithFormat(
                    String(
                        localized: "uniconnect.backup.saved.detail",
                        defaultValue: "Readable backup saved to:\n%@\n\nSSH connection details are stored in its encrypted companion. The complete app session was also saved."
                    ),
                    url.path
                )
                alert.informativeText += "\n\n" + String(
                    localized: "uniconnect.backup.saved.detectionDetail",
                    defaultValue: "AI sessions are resumable only when their native session ID is detected. Previously saved conversations are preserved."
                )
                alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
                alert.addButton(withTitle: String(
                    localized: "uniconnect.backup.saved.reveal",
                    defaultValue: "Show in Finder"
                ))
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } catch {
            presentError(String.localizedStringWithFormat(
                String(
                    localized: "uniconnect.backup.saveFailed",
                    defaultValue: "The backup could not be saved: %@"
                ),
                error.localizedDescription
            ))
        }
    }

    /// Automation hooks. They exist only for the headless end-to-end run and are ignored
    /// unless a Debug/XCTest build explicitly disables the Touch ID gate
    /// (`UNICONNECT_DISABLE_LOCK=1`). Release builds always keep the gate enabled.
    @MainActor private struct TestHooks {
        let passphrase: String?
        let exportPath: String?
        let autoImport: Bool
        static var current: TestHooks? {
            guard !UniConnectAppLock.isEnabled else { return nil }
            let env = ProcessInfo.processInfo.environment
            guard env["UNICONNECT_TEST_PASSPHRASE"] != nil || env["UNICONNECT_TEST_EXPORT_PATH"] != nil else { return nil }
            return TestHooks(passphrase: env["UNICONNECT_TEST_PASSPHRASE"], exportPath: env["UNICONNECT_TEST_EXPORT_PATH"], autoImport: env["UNICONNECT_TEST_AUTOIMPORT"] == "1")
        }
    }

    func exportConfiguration() {
        if let hooks = TestHooks.current, let path = hooks.exportPath, let passphrase = hooks.passphrase {
            let document = UniConnectBackup.buildDocument(tabManagers: allTabManagers())
            do {
                let data = try UniConnectBackup.exportData(document: document, passphrase: passphrase)
                try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), options: [.atomic])
                NSLog("[UniConnect] test export written: %@", path)
            } catch {
                NSLog("[UniConnect] test export failed: %@", error.localizedDescription)
            }
            return
        }
        UniConnectAppLock.shared.authenticateForSensitiveAction(
            reason: String(
                localized: "uniconnect.export.authenticationReason",
                defaultValue: "Export the configuration (includes encrypted secrets)"
            )
        ) { [weak self] ok in
            guard ok, let self else { return }
            self.exportConfigurationAuthenticated()
        }
    }

    private func exportConfigurationAuthenticated() {
        let document = UniConnectBackup.buildDocument(tabManagers: allTabManagers())
        let window = hostWindow(for: nil)
        UniConnectSheet.present(on: window, size: CGSize(width: 420, height: 230)) { dismiss in
            UniConnectPassphraseView(
                title: String(
                    localized: "uniconnect.export.title",
                    defaultValue: "Export Configuration"
                ),
                message: String(
                    localized: "uniconnect.export.detail",
                    defaultValue: "The file includes SSH commands (and their passwords). It is encrypted with AES-256-GCM and a key derived from this password; it cannot be opened without it."
                ),
                confirm: true,
                onSubmit: { [weak self] passphrase in
                    dismiss()
                    self?.finishExport(document: document, passphrase: passphrase)
                },
                onCancel: { dismiss() }
            )
        }
    }

    private func finishExport(document: UniConnectDocument, passphrase: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "uniconnect-\(document.savedAt.prefix(10)).uniconnect"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try UniConnectBackup.exportData(document: document, passphrase: passphrase)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            presentError(String.localizedStringWithFormat(
                String(
                    localized: "uniconnect.export.error",
                    defaultValue: "The configuration could not be exported: %@"
                ),
                error.localizedDescription
            ))
        }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "uniconnect.import.action", defaultValue: "Import")
        panel.message = String(
            localized: "uniconnect.import.filePicker.detail",
            defaultValue: "Encrypted export (.uniconnect), JSON seed, or Markdown connection map"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importConfiguration(from: url)
    }

    func importConfiguration(from url: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentError(String.localizedStringWithFormat(
                String(
                    localized: "uniconnect.import.error.readFile",
                    defaultValue: "The file could not be read: %@"
                ),
                error.localizedDescription
            ))
            return
        }
        let source: UniConnectBackup.DetailedImportSource
        do {
            if UniConnectBackup.isReadableLocalBackupManifest(data) {
                source = .plain(try UniConnectBackup.readReadableBackupSource(
                    at: url,
                    vault: .shared
                ))
            } else {
                source = try UniConnectBackup.inspectDetailed(data: data)
            }
        } catch {
            presentError(
                error.localizedDescription,
                title: String(
                    localized: "uniconnect.import.error.rejectedFile.title",
                    defaultValue: "File Rejected"
                )
            )
            return
        }
        // Importing creates workspaces with secrets: require a fresh Touch ID.
        UniConnectAppLock.shared.authenticateForSensitiveAction(
            reason: String(
                localized: "uniconnect.import.authenticationReason",
                defaultValue: "Import configuration"
            )
        ) { [weak self] ok in
            guard ok, let self else { return }
            switch source {
            case .plain(let parsed):
                self.previewImport(parsed)
            case .encrypted(let container):
                let window = self.hostWindow(for: nil)
                UniConnectSheet.present(on: window, size: CGSize(width: 420, height: 200)) { dismiss in
                    UniConnectPassphraseView(
                        title: String(
                            localized: "uniconnect.import.title",
                            defaultValue: "Import Configuration"
                        ),
                        message: String.localizedStringWithFormat(
                            String(
                                localized: "uniconnect.import.encryptedFile.detail",
                                defaultValue: "%1$@ file saved on %2$@ with %3$lld boxes. Enter the password used to export it."
                            ),
                            container.meta.app,
                            container.meta.savedAt,
                            container.meta.workspaces
                        ),
                        confirm: false,
                        onSubmit: { [weak self] passphrase in
                            dismiss()
                            do {
                                let document = try UniConnectBackup.decrypt(container: container, passphrase: passphrase)
                                self?.previewImport(UniConnectImportSourceDocument(
                                    document: document,
                                    sourceMap: .empty
                                ))
                            } catch {
                                self?.presentError(
                                    error.localizedDescription,
                                    title: String(
                                        localized: "uniconnect.import.error.decrypt.title",
                                        defaultValue: "Could Not Decrypt"
                                    )
                                )
                            }
                        },
                        onCancel: { dismiss() }
                    )
                }
            }
        }
    }

    private func liveImportWorkspaces() -> [LiveImportWorkspace] {
        let agentIndex = RestorableAgentSessionIndex.load()
        return allTabManagers().flatMap { tabManager in
            let groupNames = Dictionary(uniqueKeysWithValues: tabManager.workspaceGroups.map {
                ($0.id, $0.name)
            })
            return tabManager.tabs.compactMap { workspace -> LiveImportWorkspace? in
                guard !workspace.uniConnectShowsStarter else { return nil }
                return LiveImportWorkspace(
                    tabManager: tabManager,
                    workspace: workspace,
                    document: UniConnectBackup.documentWorkspace(
                        workspace,
                        groupNames: groupNames,
                        agentIndex: agentIndex,
                        reconcileLiveState: false
                    )
                )
            }
        }
    }

    private func currentImportDocument() -> UniConnectDocument {
        importDocument(from: liveImportWorkspaces())
    }

    private func importDocument(
        from entries: [LiveImportWorkspace]
    ) -> UniConnectDocument {
        UniConnectDocument(
            workspaces: entries.map(\.document),
            savedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Reads each current workspace and its exact encrypted SSH revision using the
    /// same row ordering consumed by ``currentImportDocument``.
    private func importSSHCredentialRecords(
        from entries: [LiveImportWorkspace]
    ) -> [Int: UniConnectSSHCredentialRecord] {
        Dictionary(uniqueKeysWithValues: entries.enumerated().compactMap { index, entry in
            guard entry.document.kind == .ssh,
                  let credentialID = entry.workspace.uniConnectProfile?.credentialId,
                  let record = UniConnectVault.shared.credentialRecord(for: credentialID) else {
                return nil
            }
            return (index, record)
        })
    }

    private func currentImportSSHCredentialRecords() -> [Int: UniConnectSSHCredentialRecord] {
        importSSHCredentialRecords(from: liveImportWorkspaces())
    }

    private func importSSHCredentialRecords(
        referencedBy document: UniConnectDocument
    ) -> [Int: UniConnectSSHCredentialRecord] {
        Dictionary(uniqueKeysWithValues: document.workspaces.enumerated().compactMap {
            index, workspace in
            guard workspace.kind == .ssh,
                  let credentialID = workspace.credentialId,
                  let record = UniConnectVault.shared.credentialRecord(for: credentialID) else {
                return nil
            }
            return (index, record)
        })
    }

    private func makeImportPlan(
        for source: UniConnectImportSourceDocument
    ) -> UniConnectImportPlan {
        let entries = liveImportWorkspaces()
        return UniConnectImportPlanner().plan(
            importing: source,
            against: importDocument(from: entries),
            existingSSHCredentialRecordsByWorkspaceIndex:
                importSSHCredentialRecords(from: entries)
        )
    }

    private func makePreparedImport(
        for source: UniConnectImportSourceDocument
    ) -> UniConnectPreparedImport {
        let entries = liveImportWorkspaces()
        return UniConnectImportPlanner().prepare(
            importing: source,
            against: importDocument(from: entries),
            existingSSHCredentialRecordsByWorkspaceIndex:
                importSSHCredentialRecords(from: entries)
        )
    }

    private func liveImportAdapter() throws -> UniConnectLiveImportAdapter {
        guard let importCheckpoints else { throw ImportApplicationError.runtimeUnavailable }
        return UniConnectLiveImportAdapter(
            checkpoints: importCheckpoints,
            readDocument: { [weak self] in
                guard let self else { throw ImportApplicationError.runtimeUnavailable }
                return self.currentImportDocument()
            },
            readSSHCredentialRecords: { [weak self] in
                guard let self else { throw ImportApplicationError.runtimeUnavailable }
                return self.currentImportSSHCredentialRecords()
            },
            readCheckpointSnapshot: {
                guard let snapshot = AppDelegate.shared?.uniConnectImportSessionSnapshot(
                    includeScrollback: true
                ) else {
                    throw ImportApplicationError.runtimeUnavailable
                }
                return snapshot
            },
            readStateSnapshot: {
                guard let snapshot = AppDelegate.shared?.uniConnectImportSessionSnapshot(
                    includeScrollback: false
                ) else {
                    throw ImportApplicationError.runtimeUnavailable
                }
                return snapshot
            },
            applyMutation: { [weak self] mutation in
                guard let self else { throw ImportApplicationError.runtimeUnavailable }
                try self.applyImportMutation(mutation)
            },
            verifyMutation: { [weak self] mutation in
                guard let self else { throw ImportApplicationError.runtimeUnavailable }
                return try await self.verifyAppliedImportMutation(mutation)
            },
            finalizeMutation: { [weak self] mutation in
                guard let self else { throw ImportApplicationError.runtimeUnavailable }
                try self.finalizeVerifiedImportMutation(mutation)
            },
            persist: { [weak self] in
                guard let self else { throw ImportApplicationError.runtimeUnavailable }
                try self.persistImportStateDurably()
            },
            restoreSessionSnapshot: { snapshot in
                guard AppDelegate.shared?.uniConnectRestoreImportSessionSnapshot(snapshot) == true else {
                    throw ImportApplicationError.rollbackMismatch
                }
            },
            readVaultSnapshot: {
                try UniConnectVault.shared.encryptedSnapshot()
            },
            restoreVault: { encryptedVault in
                try UniConnectVault.shared.restoreExactEncryptedSnapshot(encryptedVault)
            },
            restoreVaultDelta: { checkpoint, imported in
                try UniConnectVault.shared.restoreImportDelta(
                    checkpoint: checkpoint,
                    expected: imported
                )
            },
            verifyVault: { encryptedVault in
                UniConnectVault.shared.matchesExactEncryptedSnapshot(encryptedVault)
            }
        )
    }

    private func persistImportStateDurably() throws {
        guard let appDelegate = AppDelegate.shared else {
            throw ImportApplicationError.runtimeUnavailable
        }
        guard appDelegate.uniConnectPersistSessionNow() else {
            throw ImportApplicationError.persistenceFailed
        }
        _ = try UniConnectBackup.persistNow(
            tabManagers: allTabManagers(),
            reconcileLiveState: false
        )
        let persisted = try UniConnectBackup.readLocalBackup()
        guard persisted.workspaces == currentImportDocument().workspaces else {
            throw ImportApplicationError.persistenceFailed
        }
    }

    private func applyImportMutation(_ mutation: UniConnectImportMutation) throws {
        switch mutation.outcome {
        case .create:
            try createImportedWorkspace(for: mutation)
        case .update:
            try updateImportedWorkspace(for: mutation)
        case .unchanged, .conflict, .rejected:
            throw ImportApplicationError.invalidMutation
        }
        requestSave()
    }

    /// Verifies that an attach-only child survived startup before metadata can commit.
    private func verifyAppliedImportMutation(
        _ mutation: UniConnectImportMutation
    ) async throws -> Bool {
        guard mutation.workspace.kind == .ssh else { return true }
        try await Task.sleep(for: .seconds(1))
        try Task.checkCancellation()

        let candidates = liveImportWorkspaces().filter {
            liveEntry($0, matches: mutation.workspace)
        }
        guard candidates.count == 1,
              let entry = candidates.first,
              let expectedRecord = try validatedSSHCredentialRecord(
                  mutation.sshCredentialRecord,
                  for: mutation.workspace
              ),
              let credentialID = entry.workspace.uniConnectProfile?.credentialId,
              UniConnectVault.shared.credentialRecord(for: credentialID) == expectedRecord else {
            return false
        }
        for row in mutation.windowRows where row.requiresMutation {
            guard mutation.workspace.windows.indices.contains(row.id.windowIndex),
                  let tmux = mutation.workspace.windows[row.id.windowIndex].tmux else {
                return false
            }
            let matchingPanels = entry.workspace.uniConnectTmuxSessionsByPanelId.compactMap {
                panelID, session -> UUID? in
                guard session == tmux,
                      entry.workspace.panels[panelID] is TerminalPanel else {
                    return nil
                }
                return panelID
            }
            guard matchingPanels.count == 1,
                  let panelID = matchingPanels.first,
                  let panel = entry.workspace.panels[panelID] as? TerminalPanel,
                  panel.surface.hasRunningProcessForImportVerification() else {
                return false
            }
        }
        return true
    }

    /// Publishes readiness only after the attach-only child passed verification.
    private func finalizeVerifiedImportMutation(
        _ mutation: UniConnectImportMutation
    ) throws {
        guard mutation.workspace.kind == .ssh else { return }
        let candidates = liveImportWorkspaces().filter {
            liveEntry($0, matches: mutation.workspace)
        }
        guard candidates.count == 1,
              let workspace = candidates.first?.workspace,
              var profile = workspace.uniConnectProfile else {
            throw ImportApplicationError.workspaceNotFound
        }
        profile.tmuxReady = true
        workspace.uniConnectProfile = profile
    }

    private func createImportedWorkspace(for mutation: UniConnectImportMutation) throws {
        guard let tabManager = AppDelegate.shared?.uniConnectActiveTabManager()
            ?? allTabManagers().first else {
            throw ImportApplicationError.runtimeUnavailable
        }
        let item = mutation.workspace
        let workspace: Workspace
        switch item.kind {
        case .local:
            let folder = ((item.cwd ?? "~") as NSString).expandingTildeInPath
            guard UniConnectLocalBoxRootPolicy.isAvailableDirectory(folder) else {
                throw ImportApplicationError.trustedFolderUnavailable
            }
            workspace = createLocalWorkspace(
                name: item.name,
                folder: folder,
                color: item.color,
                in: tabManager,
                select: false,
                finalizeCreation: false,
                stableIdentity: item.id
            )
            guard seedLocalWindows(item.windows, in: workspace) else {
                throw ImportApplicationError.windowCreationFailed
            }
        case .ssh:
            guard let credentialRecord = try validatedSSHCredentialRecord(
                      mutation.sshCredentialRecord,
                      for: item
                  ),
                  let created = createSSHWorkspace(
                      name: item.name,
                      color: item.color,
                      credentialRecord: credentialRecord,
                      in: tabManager,
                      select: false,
                      probeImmediately: false,
                      finalizeCreation: false,
                      stableIdentity: item.id
                  ) else {
                throw ImportApplicationError.windowCreationFailed
            }
            workspace = created
            for windowRow in mutation.windowRows.sorted(by: { $0.id.windowIndex < $1.id.windowIndex }) {
                guard mutation.workspace.windows.indices.contains(windowRow.id.windowIndex) else {
                    throw ImportApplicationError.invalidMutation
                }
                let window = mutation.workspace.windows[windowRow.id.windowIndex]
                guard let session = window.tmux,
                      let existingOnly = existingOnlyPolicy(for: windowRow.action),
                      let panel = createSSHWindow(
                          in: workspace,
                          name: window.name ?? session,
                          tmuxSession: session,
                          directory: window.cwd ?? item.cwd,
                          existingSessionOnly: existingOnly,
                          focus: false,
                          requestPersistence: false,
                          showErrors: false
                      ) else {
                    throw ImportApplicationError.windowCreationFailed
                }
                if window.isPinned == true {
                    workspace.setPanelPinned(panelId: panel.id, pinned: true)
                }
            }
        }
        try applyImportedWorkspaceMetadata(
            item,
            sshCredentialRecord: mutation.sshCredentialRecord,
            to: workspace,
            in: tabManager
        )
        closeUntouchedInitialWorkspaces()
    }

    private func updateImportedWorkspace(for mutation: UniConnectImportMutation) throws {
        let entry = try matchingLiveWorkspace(for: mutation)
        guard entry.document.kind == mutation.workspace.kind else {
            throw ImportApplicationError.workspaceKindMismatch
        }
        let previousSSHRecord = entry.workspace.uniConnectProfile?.credentialId.flatMap {
            UniConnectVault.shared.credentialRecord(for: $0)
        }
        let importedSSHRecord = try validatedSSHCredentialRecord(
            mutation.sshCredentialRecord,
            for: mutation.workspace
        )
        let reconnectSSHWindows = mutation.workspace.kind == .ssh
            && previousSSHRecord != importedSSHRecord
        let orderedPanelIDs = entry.workspace.uniConnectOrderedTerminalPanelIds()
        try applyImportedWorkspaceMetadata(
            mutation.workspace,
            sshCredentialRecord: importedSSHRecord,
            to: entry.workspace,
            in: entry.tabManager
        )

        let existingRows = mutation.windowRows.filter { $0.existingWindowIndex != nil }
        let createRows = mutation.windowRows.filter { $0.existingWindowIndex == nil }
        for row in existingRows + createRows {
            guard mutation.workspace.windows.indices.contains(row.id.windowIndex) else {
                throw ImportApplicationError.invalidMutation
            }
            let window = mutation.workspace.windows[row.id.windowIndex]
            switch row.action {
            case .leaveUnchanged:
                continue
            case .reject:
                throw ImportApplicationError.invalidMutation
            case .create:
                try appendImportedWindow(
                    window,
                    row: row,
                    to: entry.workspace
                )
            case .update:
                guard let existingIndex = row.existingWindowIndex,
                      orderedPanelIDs.indices.contains(existingIndex) else {
                    throw ImportApplicationError.windowNotFound
                }
                try updateImportedWindow(
                    window,
                    row: row,
                    panelID: orderedPanelIDs[existingIndex],
                    in: entry.workspace,
                    forceSSHReconnect: reconnectSSHWindows
                )
            case .keepTerminalBecauseDuplicateAgent(_, _, let outcome):
                switch outcome {
                case .create:
                    try appendImportedWindow(window, row: row, to: entry.workspace)
                case .update:
                    guard let existingIndex = row.existingWindowIndex,
                          orderedPanelIDs.indices.contains(existingIndex) else {
                        throw ImportApplicationError.windowNotFound
                    }
                    try updateImportedWindow(
                        window,
                        row: row,
                        panelID: orderedPanelIDs[existingIndex],
                        in: entry.workspace,
                        forceSSHReconnect: reconnectSSHWindows
                    )
                case .unchanged:
                    continue
                case .conflict, .rejected:
                    throw ImportApplicationError.invalidMutation
                }
            }
        }
    }

    private func applyImportedWorkspaceMetadata(
        _ item: UniConnectDocument.Workspace,
        sshCredentialRecord: UniConnectSSHCredentialRecord?,
        to workspace: Workspace,
        in tabManager: TabManager
    ) throws {
        workspace.setCustomTitle(item.name)
        workspace.setCustomColor(item.color)
        var profile = workspace.uniConnectProfile ?? UniConnectWorkspaceProfile(kind: item.kind)
        profile.kind = item.kind
        profile.importIdentity = item.id ?? profile.importIdentity ?? UUID()
        switch item.kind {
        case .local:
            let folder = ((item.cwd ?? "~") as NSString).expandingTildeInPath
            guard UniConnectLocalBoxRootPolicy.isAvailableDirectory(folder) else {
                throw ImportApplicationError.trustedFolderUnavailable
            }
            profile.credentialId = nil
            profile.hostLabel = nil
            profile.tmuxReady = false
            profile.localRoot = folder
            workspace.uniConnectProfile = profile
            workspace.uniConnectConfigureLocalRoot(folder)
        case .ssh:
            guard let record = try validatedSSHCredentialRecord(
                sshCredentialRecord,
                for: item
            ) else { throw ImportApplicationError.invalidMutation }
            let currentCredentialID = profile.credentialId
            let currentRecord = currentCredentialID.flatMap {
                UniConnectVault.shared.credentialRecord(for: $0)
            }
            let credentialID: UUID
            if let currentCredentialID,
               currentRecord == record {
                credentialID = currentCredentialID
            } else if isRestoringImportCheckpoint,
                      let checkpointCredentialID = UniConnectVault.shared.credentialID(
                          matching: record,
                          excluding: currentCredentialID
                      ) {
                credentialID = checkpointCredentialID
            } else {
                // Connection changes get a fresh immutable binding. The previous vault
                // entry remains available to snapshots and to transactional rollback.
                credentialID = try UniConnectVault.shared.createImmutableRevision(
                    connectCommand: record.connectCommand,
                    effectiveTarget: record.effectiveTarget
                )
            }
            profile.credentialId = credentialID
            profile.hostLabel = UniConnectSSH.hostLabel(from: record.connectCommand)
            profile.localRoot = nil
            if currentRecord != record {
                profile.tmuxReady = false
            }
            workspace.uniConnectProfile = profile
        }
        profile.touch()
        workspace.uniConnectProfile = profile

        tabManager.setPinned(workspace, pinned: item.isPinned == true)
        let groupName = item.group?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let groupName, !groupName.isEmpty, item.isPinned != true {
            if let group = tabManager.workspaceGroups.first(where: { $0.name == groupName }) {
                tabManager.addWorkspaceToGroup(workspaceId: workspace.id, groupId: group.id)
            } else {
                _ = tabManager.createWorkspaceGroup(
                    name: groupName,
                    childWorkspaceIds: [workspace.id],
                    selectAnchor: false
                )
            }
        } else if workspace.groupId != nil {
            tabManager.removeWorkspaceFromGroup(workspaceId: workspace.id)
        }
    }

    /// Validates that transaction-owned SSH metadata and its encrypted record are
    /// the same declaration. Import never accepts a command-only or unresolved record.
    private func validatedSSHCredentialRecord(
        _ record: UniConnectSSHCredentialRecord?,
        for workspace: UniConnectDocument.Workspace
    ) throws -> UniConnectSSHCredentialRecord? {
        guard workspace.kind == .ssh else { return nil }
        guard let rawConnect = workspace.connect,
              UniConnectSSH.validateConnectCommand(rawConnect) == nil,
              let record,
              let effectiveTarget = record.effectiveTarget else {
            throw ImportApplicationError.invalidMutation
        }
        let connect = rawConnect.trimmingCharacters(in: .whitespacesAndNewlines)
        guard record.connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            == connect else {
            throw ImportApplicationError.invalidMutation
        }
        return UniConnectSSHCredentialRecord(
            connectCommand: connect,
            effectiveTarget: effectiveTarget
        )
    }

    private func appendImportedWindow(
        _ window: UniConnectDocument.Window,
        row: UniConnectImportPlan.WindowRow,
        to workspace: Workspace
    ) throws {
        switch workspace.uniConnectProfile?.kind {
        case .some(.local):
            guard let root = workspace.uniConnectLocalBoxRoot,
                  UniConnectLocalBoxRootPolicy.isAvailableDirectory(root),
                  let workingDirectory = try? importedLocalWorkingDirectory(
                      for: window,
                      boxRoot: root
                  ),
                  let pane = workspace.bonsplitController.focusedPaneId
                    ?? workspace.bonsplitController.allPaneIds.first,
                  let panel = workspace.newTerminalSurface(
                      inPane: pane,
                      focus: false,
                      workingDirectory: workingDirectory
                  ) else {
                throw ImportApplicationError.windowCreationFailed
            }
            try installImportedLocalWindow(window, panelID: panel.id, in: workspace)
        case .some(.ssh):
            guard let session = window.tmux,
                  let existingOnly = existingOnlyPolicy(for: row.action),
                  let panel = createSSHWindow(
                      in: workspace,
                      name: window.name ?? session,
                      tmuxSession: session,
                      directory: window.cwd,
                      existingSessionOnly: existingOnly,
                      focus: false,
                      requestPersistence: false,
                      showErrors: false
                  ) else {
                throw ImportApplicationError.windowCreationFailed
            }
            if window.isPinned == true {
                workspace.setPanelPinned(panelId: panel.id, pinned: true)
            }
        case nil:
            throw ImportApplicationError.workspaceKindMismatch
        }
    }

    private func updateImportedWindow(
        _ window: UniConnectDocument.Window,
        row: UniConnectImportPlan.WindowRow,
        panelID: UUID,
        in workspace: Workspace,
        forceSSHReconnect: Bool = false
    ) throws {
        guard workspace.panels[panelID] is TerminalPanel else {
            throw ImportApplicationError.windowNotFound
        }
        switch workspace.uniConnectProfile?.kind {
        case .some(.local):
            guard let root = workspace.uniConnectLocalBoxRoot else {
                throw ImportApplicationError.trustedFolderUnavailable
            }
            let workingDirectory = try importedLocalWorkingDirectory(
                for: window,
                boxRoot: root
            )
            let previous = workspace.uniConnectLocalWindowsByPanelId[panelID]
            if previous?.workingDirectory != workingDirectory {
                guard previous?.runtimeState != .agent else {
                    throw ImportApplicationError.activeAgentConflict
                }
                guard workspace.respawnTerminalSurface(
                    panelId: panelID,
                    command: Self.localLoginShellCommand,
                    workingDirectory: workingDirectory,
                    focus: false
                ) != nil else {
                    throw ImportApplicationError.windowCreationFailed
                }
            }
            try installImportedLocalWindow(window, panelID: panelID, in: workspace)
        case .some(.ssh):
            guard let session = window.tmux,
                  let existingOnly = existingOnlyPolicy(for: row.action) else {
                throw ImportApplicationError.invalidMutation
            }
            if workspace.uniConnectTmuxSessionsByPanelId[panelID] == session,
               !forceSSHReconnect {
                workspace.setPanelCustomTitle(panelId: panelID, title: window.name ?? session)
                workspace.setPanelPinned(panelId: panelID, pinned: window.isPinned == true)
                return
            }
            guard let replacement = createSSHWindow(
                in: workspace,
                name: window.name ?? session,
                tmuxSession: session,
                directory: window.cwd,
                existingSessionOnly: existingOnly,
                replacingPanelID: panelID,
                focus: false,
                requestPersistence: false,
                showErrors: false
            ) else {
                throw ImportApplicationError.windowCreationFailed
            }
            guard replacement.id == panelID else {
                throw ImportApplicationError.windowCreationFailed
            }
            workspace.setPanelPinned(panelId: replacement.id, pinned: window.isPinned == true)
        case nil:
            throw ImportApplicationError.workspaceKindMismatch
        }
    }

    private func installImportedLocalWindow(
        _ window: UniConnectDocument.Window,
        panelID: UUID,
        in workspace: Workspace
    ) throws {
        guard let root = workspace.uniConnectLocalBoxRoot,
              UniConnectLocalBoxRootPolicy.isAvailableDirectory(root) else {
            throw ImportApplicationError.trustedFolderUnavailable
        }
        let previous = workspace.uniConnectLocalWindowsByPanelId[panelID]
        let workingDirectory = try importedLocalWorkingDirectory(
            for: window,
            boxRoot: root
        )
        var record = window.localWindow
            ?? UniConnectLocalWindowRecord.migratingLegacy(
                id: previous?.id ?? panelID,
                visibleName: window.name,
                boxRoot: root,
                workingDirectory: workingDirectory,
                agent: nil,
                claudeSession: window.claudeSession,
                wasAgentRunning: window.claudeSession == nil ? false : true
            )
        _ = record.reconcileIdentity(
            visibleName: window.name,
            boxRoot: root,
            workingDirectory: workingDirectory,
            at: record.updatedAt
        )
        if record.runtimeState == .stopped, !isRestoringImportCheckpoint {
            _ = record.transitionToShell(at: record.updatedAt)
        }
        let registry = CmuxVaultAgentRegistry.load(workingDirectory: root)
        let desiredSnapshot = record.latestRestorableSnapshot(registry: registry)
        let desiredClaim = record.runtimeState == .agent
            ? desiredSnapshot.flatMap(UniConnectLocalAgentRestoreClaimPolicy.claim(for:))
            : nil
        let previousClaim = previous?.runtimeState == .agent
            ? previous?.activeConversation.map(UniConnectLocalAgentRestoreClaimPolicy.claim(for:))
            : nil
        if let previousClaim, previousClaim != desiredClaim {
            throw ImportApplicationError.activeAgentConflict
        }
        if let desiredClaim,
           UniConnectLocalAgentRestoreClaimPolicy.conflictingActiveOwner(
               for: desiredClaim,
               requester: .init(workspaceID: workspace.id, panelID: panelID),
               candidates: activeLocalAgentClaimCandidates()
           ) != nil {
            throw ImportApplicationError.activeAgentConflict
        }

        let startupInput: String?
        if desiredClaim != nil, previousClaim != desiredClaim {
            startupInput = desiredSnapshot?.resumeStartupInput(
                allowLauncherScript: false,
                allowOversizedInlineInput: true
            )
            guard startupInput != nil else {
                throw ImportApplicationError.invalidMutation
            }
        } else {
            startupInput = nil
        }

        let launchAttempt: LocalAgentLaunchAttempt?
        if startupInput != nil, let desiredSnapshot {
            let owner = LocalAgentOwner(workspaceID: workspace.id, panelID: panelID)
            guard let attempt = beginLocalAgentLaunch(
                owner: owner,
                snapshot: desiredSnapshot,
                hasPreparedResume: true
            ) else {
                throw ImportApplicationError.activeAgentConflict
            }
            launchAttempt = attempt
            // Importing a requested active agent is still a two-phase launch. It becomes
            // `.agent` only after the shell reports that the queued resume command is running.
            _ = record.transitionToShell(at: record.updatedAt)
        } else {
            launchAttempt = nil
        }

        if let name = window.name, !name.isEmpty {
            workspace.setPanelCustomTitle(panelId: panelID, title: name)
        }
        workspace.setPanelPinned(panelId: panelID, pinned: window.isPinned == true)
        workspace.uniConnectInstallLocalWindowRecord(
            record,
            panelId: panelID,
            visibleName: window.name,
            at: record.updatedAt
        )
        if let desiredSnapshot {
            workspace.restoredAgentSnapshotsByPanelId[panelID] = desiredSnapshot
            workspace.restoredAgentResumeStatesByPanelId[panelID] = startupInput == nil
                ? (desiredClaim == nil ? .manualResumeAvailable : .observedAgentCommandRunning)
                : .awaitingAutoResumeCommand
        } else {
            workspace.restoredAgentSnapshotsByPanelId.removeValue(forKey: panelID)
            workspace.restoredAgentResumeStatesByPanelId.removeValue(forKey: panelID)
        }
        if let startupInput, let launchAttempt {
            guard let panel = workspace.panels[panelID] as? TerminalPanel else {
                failLocalAgentLaunch(launchAttempt, workspace: workspace)
                throw ImportApplicationError.windowCreationFailed
            }
            workspace.sendInputWhenReady(
                startupInput,
                to: panel,
                reason: .localAgentLaunch
            ) { [weak self, weak workspace] delivered in
                self?.handleLocalAgentDelivery(
                    launchAttempt,
                    delivered: delivered,
                    workspace: workspace
                )
            }
        }
    }

    private func importedLocalWorkingDirectory(
        for window: UniConnectDocument.Window,
        boxRoot: String
    ) throws -> String {
        let candidate = window.cwd
            ?? window.localWindow?.workingDirectory
            ?? boxRoot
        guard let workingDirectory = UniConnectLocalWindowRecord.validatedWorkingDirectory(
            candidate,
            within: boxRoot
        ) else {
            throw ImportApplicationError.invalidMutation
        }
        return workingDirectory
    }

    private func existingOnlyPolicy(
        for action: UniConnectImportPlan.WindowAction
    ) -> Bool? {
        let destination: UniConnectImportPlan.WindowDestination
        switch action {
        case .create(let value), .update(let value):
            destination = value
        case .leaveUnchanged, .keepTerminalBecauseDuplicateAgent, .reject:
            return nil
        }
        switch destination {
        case .attachExistingTmux:
            return true
        case .createTmuxIfMissing:
            return false
        case .terminal, .agent:
            return nil
        }
    }

    private func matchingLiveWorkspace(
        for mutation: UniConnectImportMutation
    ) throws -> LiveImportWorkspace {
        let entries = liveImportWorkspaces()
        if let id = mutation.existingWorkspaceID {
            let matches = entries.filter { $0.document.id == id }
            guard matches.count <= 1 else { throw ImportApplicationError.workspaceAmbiguous }
            if let match = matches.first { return match }
        }
        if let index = mutation.existingWorkspaceIndex,
           entries.indices.contains(index) {
            return entries[index]
        }
        throw ImportApplicationError.workspaceNotFound
    }

    private func restoreImportDocument(_ checkpoint: UniConnectDocument) throws {
        guard !isRestoringImportCheckpoint else {
            throw ImportApplicationError.rollbackMismatch
        }
        isRestoringImportCheckpoint = true
        defer { isRestoringImportCheckpoint = false }
        var entries = liveImportWorkspaces()
        var matchedLiveIDs = Set<UUID>()
        for item in checkpoint.workspaces {
            let matches = entries.filter { liveEntry($0, matches: item) }
            guard matches.count <= 1 else { throw ImportApplicationError.workspaceAmbiguous }
            if let match = matches.first { matchedLiveIDs.insert(match.workspace.id) }
        }
        for entry in entries.reversed() where !matchedLiveIDs.contains(entry.workspace.id) {
            entry.tabManager.closeWorkspace(entry.workspace, recordHistory: false)
        }
        try stopConflictingImportedAgents(beforeRestoring: checkpoint)

        let checkpointCredentialRecords = importSSHCredentialRecords(
            referencedBy: checkpoint
        )
        let source = UniConnectImportSourceDocument(
            document: checkpoint,
            sourceMap: .empty,
            sshCredentialRecordsByWorkspaceIndex: checkpointCredentialRecords
        )
        let plan = makeImportPlan(for: source)
        guard !plan.hasBlockingIssues else { throw ImportApplicationError.rollbackMismatch }
        for row in plan.mutationRows.sorted(by: { $0.sourceIndex < $1.sourceIndex }) {
            let mutation = UniConnectImportMutation(
                rowID: row.id,
                outcome: row.outcome,
                existingWorkspaceIndex: row.existingWorkspaceIndex,
                existingWorkspaceID: row.existingWorkspaceID,
                workspace: row.workspace,
                windowRows: row.windowRows,
                sshCredentialRecord: checkpointCredentialRecords[row.sourceIndex]
            )
            try applyImportMutation(mutation)
        }

        entries = liveImportWorkspaces()
        for item in checkpoint.workspaces {
            let matches = entries.filter { liveEntry($0, matches: item) }
            guard matches.count == 1, let entry = matches.first else {
                throw ImportApplicationError.rollbackMismatch
            }
            let desiredWindows = item.windows
            let panelIDs = entry.workspace.uniConnectOrderedTerminalPanelIds()
            var retainedPanelIDs = Set<UUID>()
            for desired in desiredWindows {
                let candidates = panelIDs.filter { panelID in
                    livePanel(panelID, in: entry.workspace, matches: desired, kind: item.kind)
                }
                guard candidates.count == 1, let panelID = candidates.first else {
                    throw ImportApplicationError.rollbackMismatch
                }
                retainedPanelIDs.insert(panelID)
            }
            for panelID in panelIDs where !retainedPanelIDs.contains(panelID) {
                var closedExtra = false
                entry.workspace.withClosedPanelHistorySuppressed {
                    closedExtra = entry.workspace.closePanel(panelID, force: true)
                }
                guard closedExtra else {
                    throw ImportApplicationError.rollbackMismatch
                }
            }
        }
        requestSave()
    }

    /// Stops only an agent process introduced by the failed import before the pure planner
    /// compares the checkpoint shell/owner. Ordinary shell processes are left untouched.
    private func stopConflictingImportedAgents(
        beforeRestoring checkpoint: UniConnectDocument
    ) throws {
        let entries = liveImportWorkspaces()
        for desiredWorkspace in checkpoint.workspaces where desiredWorkspace.kind == .local {
            let matches = entries.filter { liveEntry($0, matches: desiredWorkspace) }
            guard matches.count <= 1 else { throw ImportApplicationError.workspaceAmbiguous }
            guard let entry = matches.first else { continue }
            let panelIDs = entry.workspace.uniConnectOrderedTerminalPanelIds()
            for desiredWindow in desiredWorkspace.windows {
                let candidates = panelIDs.filter {
                    livePanel($0, in: entry.workspace, matches: desiredWindow, kind: .local)
                }
                guard candidates.count <= 1 else { throw ImportApplicationError.rollbackMismatch }
                guard let panelID = candidates.first,
                      let existingIndex = panelIDs.firstIndex(of: panelID),
                      entry.document.windows.indices.contains(existingIndex) else {
                    continue
                }
                let currentWindow = entry.document.windows[existingIndex]
                let currentOwner = activeAgentImportKey(currentWindow)
                guard currentOwner != nil,
                      currentOwner != activeAgentImportKey(desiredWindow) else {
                    continue
                }
                let rawBoxRoot = desiredWorkspace.cwd
                    ?? desiredWindow.localWindow?.boxRoot
                    ?? entry.workspace.uniConnectLocalBoxRoot
                    ?? ""
                guard let boxRoot = UniConnectLocalWindowRecord.validatedBoxRoot(rawBoxRoot),
                      let workingDirectory = try? importedLocalWorkingDirectory(
                          for: desiredWindow,
                          boxRoot: boxRoot
                      ),
                      UniConnectLocalBoxRootPolicy.isAvailableDirectory(workingDirectory),
                      entry.workspace.respawnTerminalSurface(
                          panelId: panelID,
                          command: Self.localLoginShellCommand,
                          workingDirectory: workingDirectory,
                          focus: false,
                          forceTerminateForegroundProcess: true
                      ) != nil else {
                    throw ImportApplicationError.rollbackMismatch
                }
                if var record = entry.workspace.uniConnectLocalWindowsByPanelId[panelID] {
                    _ = record.transitionToShell(at: record.updatedAt)
                    entry.workspace.uniConnectInstallLocalWindowRecord(
                        record,
                        panelId: panelID,
                        visibleName: currentWindow.name,
                        at: record.updatedAt
                    )
                }
            }
        }
    }

    private func activeAgentImportKey(_ window: UniConnectDocument.Window) -> String? {
        if let localWindow = window.localWindow {
            guard localWindow.runtimeState == .agent,
                  let active = localWindow.activeConversation else {
                return nil
            }
            return UniConnectLocalAgentRestoreClaimPolicy.canonicalKey(
                kind: active.kind,
                sessionID: active.sessionID
            )
        }
        guard let claude = window.claudeSession?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !claude.isEmpty else {
            return nil
        }
        return UniConnectLocalAgentRestoreClaimPolicy.canonicalKey(
            kind: .claude,
            sessionID: claude
        )
    }

    private func liveEntry(
        _ entry: LiveImportWorkspace,
        matches imported: UniConnectDocument.Workspace
    ) -> Bool {
        if let id = imported.id, let liveID = entry.document.id {
            return id == liveID
        }
        return entry.document.kind == imported.kind
            && normalizedImportName(entry.document.name) == normalizedImportName(imported.name)
    }

    private func livePanel(
        _ panelID: UUID,
        in workspace: Workspace,
        matches imported: UniConnectDocument.Window,
        kind: UniConnectWorkspaceKind
    ) -> Bool {
        switch kind {
        case .local:
            if let id = imported.localWindow?.id {
                return workspace.uniConnectLocalWindowsByPanelId[panelID]?.id == id
            }
        case .ssh:
            if let tmux = imported.tmux {
                return workspace.uniConnectTmuxSessionsByPanelId[panelID] == tmux
            }
        }
        let liveName = workspace.panelCustomTitles[panelID] ?? workspace.panelTitles[panelID] ?? ""
        return normalizedImportName(liveName) == normalizedImportName(imported.name ?? "")
    }

    private func normalizedImportName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func previewImport(_ source: UniConnectImportSourceDocument) {
        let prepared = makePreparedImport(for: source)
        let window = hostWindow(for: nil)
        UniConnectSheet.present(on: window, size: CGSize(width: 680, height: 620)) { dismiss in
            UniConnectImportPreviewView(
                plan: prepared.plan,
                onImport: { [weak self] selectedRowIDs in
                    dismiss()
                    self?.startImport(prepared, selectedRowIDs: selectedRowIDs)
                },
                onCancel: { dismiss() }
            )
        }
    }

    private func startImport(
        _ prepared: UniConnectPreparedImport,
        selectedRowIDs: Set<Int>,
        showErrors: Bool = true
    ) {
        guard importTask == nil else {
            if showErrors {
                presentError(String(
                    localized: "uniconnect.import.error.inProgress",
                    defaultValue: "Another import or recovery operation is already in progress."
                ))
            }
            return
        }
        let selection: UniConnectImportSelection
        do {
            selection = try UniConnectImportSelection(
                rowIDs: selectedRowIDs,
                plan: prepared.plan
            )
        } catch {
            if showErrors {
                presentError(String(
                    localized: "uniconnect.import.error.invalidSelection",
                    defaultValue: "The import selection is no longer valid. Review the import again; no changes were made."
                ))
            }
            return
        }
        guard let transaction = importTransaction,
              let adapter = try? liveImportAdapter(),
              let importMutationGate,
              let lease = try? importMutationGate.acquire() else {
            if showErrors {
                presentError(String(
                    localized: "uniconnect.import.error.runtimeUnavailable",
                    defaultValue: "The protected import service is unavailable. No changes were made."
                ))
            }
            return
        }
        importTask = Task { @MainActor [weak self] in
            defer { _ = importMutationGate.release(lease) }
            guard let self else { return }
            defer { self.importTask = nil }
            let completed = await importMutationGate.withLease(lease) {
                guard await self.recoverInterruptedImportIfNeeded(
                    transaction: transaction,
                    adapter: adapter
                ) else {
                    return false
                }
                let result = await transaction.execute(
                    prepared: prepared,
                    selection: selection,
                    adapter: adapter
                )
                switch result {
                case .noChanges, .committed:
                    await self.reconcileUnboundSSHTerminalsAndPersist(using: adapter)
                case .failedBeforeMutation, .rolledBack, .rollbackFailed:
                    break
                }
                self.handleImportResult(result, showErrors: showErrors)
                return true
            }
            if completed == nil, showErrors {
                self.presentError(String(
                    localized: "uniconnect.import.error.inProgress",
                    defaultValue: "Another import or recovery operation is already in progress."
                ))
            }
        }
    }

    private func handleImportResult(
        _ result: UniConnectImportTransactionResult,
        showErrors: Bool
    ) {
        guard showErrors else { return }
        switch result {
        case .noChanges, .committed:
            return
        case .failedBeforeMutation(let failure):
            presentError(importFailureMessage(failure, rolledBack: false))
        case .rolledBack(_, let failure):
            presentError(importFailureMessage(failure, rolledBack: true))
        case .rollbackFailed:
            presentError(String(
                localized: "uniconnect.import.error.rollbackFailed",
                defaultValue: "Import failed and its automatic rollback could not be verified. UniConnect kept the encrypted recovery checkpoint."
            ))
        }
    }

    private func importFailureMessage(
        _ failure: UniConnectImportTransactionResult.Failure,
        rolledBack: Bool
    ) -> String {
        if rolledBack {
            return String(
                localized: "uniconnect.import.error.rolledBack",
                defaultValue: "Import could not finish. UniConnect restored and verified the complete pre-import state."
            )
        }
        switch failure {
        case .blockedPlan:
            return String(
                localized: "uniconnect.import.error.blocked",
                defaultValue: "Only rows marked Create or Update can be imported. Conflicts and rejected declarations were skipped."
            )
        case .stateChanged:
            return String(
                localized: "uniconnect.import.error.stateChanged",
                defaultValue: "The current workspaces changed after this preview. Review the import again; no changes were made."
            )
        case .invalidSelection:
            return String(
                localized: "uniconnect.import.error.invalidSelection",
                defaultValue: "The import selection is no longer valid. Review the import again; no changes were made."
            )
        case .remoteSessionsUnavailable(let windowIDs):
            return String.localizedStringWithFormat(
                String(
                    localized: "uniconnect.import.error.remoteSessionsUnavailable",
                    defaultValue: "%lld declared existing tmux windows are unavailable. No remote session was created and no local changes were made."
                ),
                Int64(windowIDs.count)
            )
        case .checkpointFailed, .journalFailed:
            return String(
                localized: "uniconnect.import.error.checkpointFailed",
                defaultValue: "The encrypted recovery checkpoint could not be saved. No import changes were made."
            )
        case .mutationFailed, .persistenceFailed, .verificationFailed:
            return String(
                localized: "uniconnect.import.error.notCommitted",
                defaultValue: "Import could not be committed safely. No unverified state was accepted."
            )
        case .cancelled:
            return String(
                localized: "uniconnect.import.error.cancelled",
                defaultValue: "Import was cancelled before it could commit."
            )
        }
    }

    @discardableResult
    private func applyCreateOnlyImport(
        _ workspaces: [UniConnectDocument.Workspace],
        in tabManager: TabManager
    ) -> Bool {
        let originalSelection = tabManager.selectedWorkspace
        var created: [Workspace] = []
        var probesAfterCommit: [Workspace] = []
        var groupMembers: [String: [UUID]] = [:]
        for (index, item) in workspaces.enumerated() {
            let isLast = index == workspaces.count - 1
            switch item.kind {
            case .local:
                let folder = ((item.cwd ?? "~") as NSString).expandingTildeInPath
                let workspace = createLocalWorkspace(
                    name: item.name,
                    folder: folder,
                    color: item.color,
                    in: tabManager,
                    select: isLast,
                    finalizeCreation: false,
                    stableIdentity: item.id
                )
                created.append(workspace)
                guard seedLocalWindows(item.windows, in: workspace) else {
                    rollbackImportCreation(created, in: tabManager, originalSelection: originalSelection)
                    return false
                }
                if item.isPinned == true { tabManager.setPinned(workspace, pinned: true) }
                if let group = item.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
                    groupMembers[group, default: []].append(workspace.id)
                }
            case .ssh:
                guard let connect = item.connect else {
                    rollbackImportCreation(created, in: tabManager, originalSelection: originalSelection)
                    return false
                }
                guard let workspace = createSSHWorkspace(
                    name: item.name,
                    color: item.color,
                    connectCommand: connect,
                    in: tabManager,
                    select: isLast,
                    probeImmediately: false,
                    finalizeCreation: false,
                    stableIdentity: item.id
                ) else {
                    rollbackImportCreation(created, in: tabManager, originalSelection: originalSelection)
                    return false
                }
                created.append(workspace)
                // This legacy create-only application path opens explicit SSH windows.
                // Transactional import performs its own read-only tmux preflight before
                // reaching integration and must never infer recovery from this fallback.
                var profile = workspace.uniConnectProfile ?? UniConnectWorkspaceProfile(kind: .ssh)
                if !item.windows.isEmpty {
                    profile.tmuxReady = true
                    workspace.uniConnectProfile = profile
                    for window in item.windows {
                        let name = window.name
                            ?? window.tmux
                            ?? String(localized: "uniconnect.window.fallbackName", defaultValue: "window")
                        guard let session = window.tmux,
                              let panel = createSSHWindow(
                                  in: workspace,
                                  name: name,
                                  tmuxSession: session,
                                  directory: window.cwd ?? item.cwd,
                                  focus: false,
                                  requestPersistence: false,
                                  showErrors: false
                              ) else {
                            rollbackImportCreation(created, in: tabManager, originalSelection: originalSelection)
                            return false
                        }
                        if window.isPinned == true {
                            workspace.setPanelPinned(panelId: panel.id, pinned: true)
                        }
                    }
                } else {
                    probesAfterCommit.append(workspace)
                }
                if item.isPinned == true { tabManager.setPinned(workspace, pinned: true) }
                if let group = item.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
                    groupMembers[group, default: []].append(workspace.id)
                }
            }
        }
        for (name, ids) in groupMembers where !ids.isEmpty {
            if let existing = tabManager.workspaceGroups.first(where: { $0.name == name }) {
                for id in ids { tabManager.assignGroup(workspaceId: id, groupId: existing.id) }
            } else {
                _ = tabManager.createWorkspaceGroup(name: name, childWorkspaceIds: ids, selectAnchor: false)
            }
        }
        closeUntouchedInitialWorkspaces()
        requestSave()
        for workspace in probesAfterCommit { startProbe(for: workspace) }
        return true
    }

    private func rollbackImportCreation(
        _ workspaces: [Workspace],
        in tabManager: TabManager,
        originalSelection: Workspace?
    ) {
        for workspace in workspaces.reversed() {
            probes.removeValue(forKey: workspace.id)?.cancel()
            setupStates.removeValue(forKey: workspace.id)
            if let credentialID = workspace.uniConnectProfile?.credentialId {
                UniConnectVault.shared.remove(id: credentialID)
            }
            tabManager.closeWorkspace(workspace, recordHistory: false)
        }
        if let originalSelection, tabManager.tabs.contains(where: { $0.id == originalSelection.id }) {
            tabManager.selectWorkspace(originalSelection)
        }
        requestSave()
    }

    private func seedLocalWindows(_ windows: [UniConnectDocument.Window], in workspace: Workspace) -> Bool {
        guard !windows.isEmpty else { return true }
        guard let boxRoot = workspace.uniConnectLocalBoxRoot else {
            return false
        }
        // The first window reuses the initial terminal; the rest are new tabs.
        var panelIds = workspace.uniConnectOrderedTerminalPanelIds()
        for (index, window) in windows.enumerated() {
            guard let workingDirectory = try? importedLocalWorkingDirectory(
                for: window,
                boxRoot: boxRoot
            ), UniConnectLocalBoxRootPolicy.isAvailableDirectory(workingDirectory) else {
                return false
            }
            let panelId: UUID?
            if index < panelIds.count {
                panelId = panelIds[index]
                if let panelId,
                   workspace.uniConnectLocalWindowsByPanelId[panelId]?.workingDirectory
                    != workingDirectory,
                   workspace.respawnTerminalSurface(
                       panelId: panelId,
                       command: Self.localLoginShellCommand,
                       workingDirectory: workingDirectory,
                       focus: false
                   ) == nil {
                    return false
                }
            } else if let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first {
                panelId = workspace.newTerminalSurface(
                    inPane: pane,
                    focus: false,
                    workingDirectory: workingDirectory
                )?.id
                if let panelId { panelIds.append(panelId) }
            } else {
                panelId = nil
            }
            guard let panelId else { return false }
            do {
                try installImportedLocalWindow(window, panelID: panelId, in: workspace)
            } catch {
                return false
            }
        }
        return true
    }

    func saveSeedTemplate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "uniconnect-seed.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try UniConnectBackup.seedTemplate().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError(String.localizedStringWithFormat(
                String(
                    localized: "uniconnect.backup.seed.saveFailed",
                    defaultValue: "The template could not be saved: %@"
                ),
                error.localizedDescription
            ))
        }
    }

    /// "Último guardado" for the menu: modification time of the session snapshot cmux writes.
    static func lastSavedMenuLabel() -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? UniConnectIdentity.releaseBundleIdentifier
        let safe = bundleId.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let snapshot = base?.appendingPathComponent("UniConnect/session-\(safe)\(UniConnectIdentity.storageSuffix).json")
        guard let snapshot, let date = (try? FileManager.default.attributesOfItem(atPath: snapshot.path))?[.modificationDate] as? Date else {
            return String(localized: "menu.file.lastSaved.never", defaultValue: "Last saved: not yet")
        }
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium
        return String.localizedStringWithFormat(
            String(localized: "menu.file.lastSaved.time", defaultValue: "Last saved: %@"),
            f.string(from: date)
        )
    }

    // MARK: Explicit remote termination (never a side effect of closing)

    /// Kills the tmux session behind the focused window on the server, after a confirmation
    /// that spells out exactly what dies, then closes the tab. This is the only place
    /// UniConnect ever runs `tmux kill-session`.
    func terminateRemoteTmuxSession(in workspace: Workspace) {
        guard let profile = workspace.uniConnectProfile, profile.isSSH,
              let panelId = workspace.focusedPanelId,
              let session = workspace.uniConnectTmuxSessionsByPanelId[panelId],
              let credentialId = profile.credentialId,
              let credentialRecord = UniConnectVault.shared.credentialRecord(for: credentialId),
              credentialRecord.effectiveTarget != nil else {
            presentError(String(
                localized: "uniconnect.ssh.terminate.error.notRemoteTmux",
                defaultValue: "The active window is not a tmux window in an SSH box."
            ))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        let host = profile.hostLabel
            ?? String(localized: "uniconnect.ssh.hostFallbackWithArticle", defaultValue: "the server")
        alert.messageText = String.localizedStringWithFormat(
            String(
                localized: "uniconnect.ssh.terminate.title",
                defaultValue: "End tmux session \"%1$@\" on %2$@?"
            ),
            session,
            host
        )
        alert.informativeText = String.localizedStringWithFormat(
            String(
                localized: "uniconnect.ssh.terminate.detail",
                defaultValue: "This runs `tmux kill-session -t %@` on the server. The process inside it (Claude, logs, or anything else) will end and cannot be recovered. Closing the tab normally does NOT do this."
            ),
            session
        )
        alert.addButton(withTitle: String(
            localized: "uniconnect.ssh.terminate.action",
            defaultValue: "End Remote Session"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let invocation = UniConnectSSH.processInvocation(
            credentialRecord: credentialRecord,
            injecting: ["-T"] + UniConnectSSH.baseClientOptions,
            remoteCommand: "tmux kill-session -t \(UniConnectSSH.shellQuote(session))"
        ) else {
            presentError(String(
                localized: "uniconnect.ssh.error.secureInvocation",
                defaultValue: "A secure SSH connection could not be prepared."
            ))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            presentError(error.localizedDescription)
            return
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            presentError(String(
                localized: "uniconnect.ssh.error.remoteTmuxTerminationFailed",
                defaultValue: "The remote tmux session could not be ended."
            ))
            return
        }
        workspace.uniConnectTmuxSessionsByPanelId.removeValue(forKey: panelId)
        _ = workspace.closePanel(panelId, force: true)
        workspace.uniConnectProfile?.touch()
        requestSave()
    }

    // MARK: Closed items ("Cerradas")

    func showClosedItemsMenu(tabManager: TabManager?) {
        let snapshot = ClosedItemHistoryStore.shared.menuSnapshot(maxItemCount: 40)
        let menu = NSMenu(title: String(
            localized: "menu.file.recentlyClosed",
            defaultValue: "Recently Closed"
        ))
        if snapshot.items.isEmpty {
            let item = NSMenuItem(
                title: String(
                    localized: "menu.file.recentlyClosed.empty",
                    defaultValue: "No Closed Windows or Boxes"
                ),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
        for entry in snapshot.items {
            let item = NSMenuItem(title: entry.menuTitle, action: #selector(reopenClosedItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            let submenu = NSMenu()
            let reopen = NSMenuItem(
                title: String(localized: "menu.file.recentlyClosed.reopen", defaultValue: "Reopen"),
                action: #selector(reopenClosedItem(_:)),
                keyEquivalent: ""
            )
            reopen.target = self
            reopen.representedObject = entry.id
            let delete = NSMenuItem(
                title: String(
                    localized: "menu.file.recentlyClosed.delete",
                    defaultValue: "Delete Permanently…"
                ),
                action: #selector(deleteClosedItem(_:)),
                keyEquivalent: ""
            )
            delete.target = self
            delete.representedObject = entry.id
            submenu.addItem(reopen)
            submenu.addItem(delete)
            item.submenu = submenu
            menu.addItem(item)
        }
        if let window = hostWindow(for: tabManager), let contentView = window.contentView {
            let origin = NSPoint(x: 12, y: contentView.bounds.height - 12)
            menu.popUp(positioning: nil, at: origin, in: contentView)
        }
    }

    @objc private func reopenClosedItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        _ = AppDelegate.shared?.uniConnectActiveTabManager()?.reopenClosedHistoryItem(id: id)
    }

    @objc private func deleteClosedItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = ClosedItemHistoryStore.shared.record(id: id) else { return }
        let cleanup = claudeBridgeCleanupPreparation(for: record)
        guard !cleanup.routeIDs.isEmpty else {
            confirmPlainClosedItemDeletion(id: id)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "bridge.cleanup.delete.title",
            defaultValue: "Delete this SSH item permanently?"
        )
        var detail = String(
            localized: "bridge.cleanup.delete.detail",
            defaultValue: "You can also remove UniConnect's namespaced Claude notification integration from the remote host. Other hooks and tmux sessions are never touched."
        )
        let canRemoveRemotely = !cleanup.hasUnavailableCredential && claudeBridgeMaintenance != nil
        if !canRemoveRemotely {
            detail += "\n\n" + String(
                localized: "bridge.cleanup.delete.remoteUnavailable",
                defaultValue: "Remote cleanup is unavailable because the saved SSH connection cannot be opened safely. You can keep this item and retry later, or delete only its local record."
            )
        }
        alert.informativeText = detail
        let removeButton = alert.addButton(withTitle: String(
            localized: "bridge.cleanup.deleteAndRemoveRemote",
            defaultValue: "Delete and Remove Remote Integration"
        ))
        removeButton.isEnabled = canRemoveRemotely
        alert.addButton(withTitle: String(
            localized: "bridge.cleanup.deleteLocalOnly",
            defaultValue: "Delete Locally Only"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            removeBridgeAndClosedItem(id: id, cleanup: cleanup)
        case .alertSecondButtonReturn:
            finishClosedItemDeletion(id: id, routeIDs: cleanup.routeIDs)
        default:
            break
        }
    }

    private struct ClaudeBridgeCleanupGroup: Sendable {
        let credentialID: UUID
        let session: DetectedSSHSession
        var routeIDs: Set<UUID>
    }

    private struct ClaudeBridgeCleanupPreparation: Sendable {
        let groups: [ClaudeBridgeCleanupGroup]
        let routeIDs: Set<UUID>
        let hasUnavailableCredential: Bool
    }

    private func claudeBridgeCleanupPreparation(
        for record: ClosedItemHistoryRecord
    ) -> ClaudeBridgeCleanupPreparation {
        var allRouteIDs: Set<UUID> = []
        var groupsByCredentialID: [UUID: ClaudeBridgeCleanupGroup] = [:]
        var hasUnavailableCredential = false

        func append(profile: UniConnectWorkspaceProfile?, panels: [SessionPanelSnapshot]) {
            guard let profile, profile.isSSH else { return }
            let routeIDs = Set(panels.compactMap { panel -> UUID? in
                guard let tmuxSession = panel.terminal?.uniConnectTmuxSession,
                      !tmuxSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return panel.id
            })
            guard !routeIDs.isEmpty else { return }
            allRouteIDs.formUnion(routeIDs)
            guard let credentialID = profile.credentialId,
                  let credentialRecord = UniConnectVault.shared.credentialRecord(
                      for: credentialID
                  ),
                  let session = UniConnectSSH.detectedSession(
                      fromCredentialRecord: credentialRecord
                  ) else {
                hasUnavailableCredential = true
                return
            }
            if var existing = groupsByCredentialID[credentialID] {
                existing.routeIDs.formUnion(routeIDs)
                groupsByCredentialID[credentialID] = existing
            } else {
                groupsByCredentialID[credentialID] = ClaudeBridgeCleanupGroup(
                    credentialID: credentialID,
                    session: session,
                    routeIDs: routeIDs
                )
            }
        }

        switch record.entry {
        case .panel(let entry):
            let workspace = allTabManagers()
                .lazy
                .compactMap { manager in
                    manager.tabs.first { $0.id == entry.workspaceId }
                }
                .first
            append(profile: workspace?.uniConnectProfile, panels: [entry.snapshot])
        case .workspace(let entry):
            append(profile: entry.snapshot.uniConnect, panels: entry.snapshot.panels)
        case .window(let entry):
            for snapshot in entry.snapshot.tabManager.workspaces {
                append(profile: snapshot.uniConnect, panels: snapshot.panels)
            }
        }
        return ClaudeBridgeCleanupPreparation(
            groups: groupsByCredentialID.values.sorted {
                $0.credentialID.uuidString < $1.credentialID.uuidString
            },
            routeIDs: allRouteIDs,
            hasUnavailableCredential: hasUnavailableCredential
        )
    }

    private func confirmPlainClosedItemDeletion(id: UUID) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "history.delete.confirm.title",
            defaultValue: "Delete permanently?"
        )
        alert.informativeText = String(
            localized: "history.delete.confirm.detail",
            defaultValue: "This removes the item from Closed Items, so it can no longer be reopened from UniConnect. Remote tmux sessions are not touched."
        )
        alert.addButton(withTitle: String(localized: "common.delete", defaultValue: "Delete"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = ClosedItemHistoryStore.shared.removeRecord(id: id)
    }

    private func removeBridgeAndClosedItem(
        id: UUID,
        cleanup: ClaudeBridgeCleanupPreparation
    ) {
        guard let maintenance = claudeBridgeMaintenance,
              !cleanup.hasUnavailableCredential,
              bridgeCleanupRecordIDs.insert(id).inserted else {
            presentError(String(
                localized: "bridge.cleanup.error.busyOrUnavailable",
                defaultValue: "The remote integration cannot be removed safely right now. The closed item has been kept so you can retry."
            ))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.bridgeCleanupRecordIDs.remove(id) }
            do {
                for group in cleanup.groups {
                    try await maintenance.removeRemoteIntegration(
                        routeIDs: Array(group.routeIDs),
                        session: group.session
                    )
                }
            } catch {
                self.presentError(String(
                    localized: "bridge.cleanup.error.failed",
                    defaultValue: "UniConnect could not verify remote cleanup. Nothing was deleted from Closed Items; check the SSH connection and try again."
                ))
                return
            }
            self.finishClosedItemDeletion(id: id, routeIDs: cleanup.routeIDs)
            let confirmation = NSAlert()
            confirmation.messageText = String(
                localized: "bridge.cleanup.success.title",
                defaultValue: "Remote integration removed"
            )
            confirmation.informativeText = String(
                localized: "bridge.cleanup.success.detail",
                defaultValue: "UniConnect removed only its route files and Claude hook entries. Other hooks and remote tmux sessions were left unchanged."
            )
            confirmation.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            confirmation.runModal()
        }
    }

    private func finishClosedItemDeletion(id: UUID, routeIDs: Set<UUID>) {
        guard ClosedItemHistoryStore.shared.removeRecord(id: id) != nil else { return }
        for routeID in routeIDs {
            claudeBridgeRuntime?.unregister(routeID: routeID, removeToken: false)
        }
        guard let maintenance = claudeBridgeMaintenance, !routeIDs.isEmpty else { return }
        Task {
            await maintenance.forgetLocalRoutes(Array(routeIDs))
        }
    }
}

// MARK: - Workspace helpers

extension Workspace {
    var uniConnectIsSSH: Bool { uniConnectProfile?.isSSH == true }

    /// True for the stock workspace created when there is nothing to show → empty state.
    var uniConnectShowsStarter: Bool { uniConnectIsStarter && uniConnectProfile == nil }

    /// Whether this workspace represents a real box in workspace navigation.
    var uniConnectAppearsInWorkspaceNavigation: Bool { !uniConnectShowsStarter }

    /// Converts cmux's required bootstrap workspace into UniConnect's non-user-facing empty state.
    func uniConnectConfigureAsStarter() {
        guard uniConnectProfile == nil else { return }
        uniConnectPlaceholderPanelIds = Set(panels.keys)
        uniConnectIsStarter = true
    }

    /// True while an SSH workspace has no tmux-bound window yet → show the welcome page.
    var uniConnectShowsWelcome: Bool {
        guard uniConnectIsSSH else { return false }
        return !panels.keys.contains { uniConnectTmuxSessionsByPanelId[$0] != nil }
    }

    func uniConnectOrderedTerminalPanelIds() -> [UUID] {
        var seen: Set<UUID> = []
        var ordered: [UUID] = []
        for id in sidebarOrderedPanelIds() where panels[id] is TerminalPanel && seen.insert(id).inserted {
            ordered.append(id)
        }
        for id in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) where panels[id] is TerminalPanel && seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered.filter { !uniConnectPlaceholderPanelIds.contains($0) }
    }

    /// Returns legacy local terminals that cannot represent a window in an SSH box.
    /// An entirely unbound box is still the valid pre-first-window welcome state.
    static func uniConnectStaleUnboundTerminalPanelIDs(
        isSSH: Bool,
        terminalPanelIDs: Set<UUID>,
        tmuxSessionsByPanelID: [UUID: String]
    ) -> Set<UUID> {
        guard isSSH,
              terminalPanelIDs.contains(where: { tmuxSessionsByPanelID[$0] != nil }) else {
            return []
        }
        return Set(terminalPanelIDs.filter { tmuxSessionsByPanelID[$0] == nil })
    }

    /// Removes only unbound terminals after at least one canonical tmux binding exists.
    /// Bound remote sessions and their panel identities are never touched.
    @discardableResult
    func uniConnectRemoveStaleUnboundSSHTerminals() -> Bool {
        let terminalPanelIDs = Set(panels.compactMap { panelID, panel in
            panel is TerminalPanel ? panelID : nil
        })
        let stalePanelIDs = Self.uniConnectStaleUnboundTerminalPanelIDs(
            isSSH: uniConnectIsSSH,
            terminalPanelIDs: terminalPanelIDs,
            tmuxSessionsByPanelID: uniConnectTmuxSessionsByPanelId
        )
        guard !stalePanelIDs.isEmpty else { return false }

        var removedAny = false
        withClosedPanelHistorySuppressed {
            for panelID in stalePanelIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                removedAny = closePanel(panelID, force: true) || removedAny
            }
        }
        uniConnectPlaceholderPanelIds.subtract(stalePanelIDs)
        return removedAny
    }

    /// Startup command for a restored terminal panel bound to a tmux session.
    /// Returns nil for anything that is not an SSH/tmux window.
    func uniConnectRestoredStartupCommand(panelSnapshot: SessionPanelSnapshot) -> String? {
        guard let profile = uniConnectProfile, profile.isSSH,
              let session = panelSnapshot.terminal?.uniConnectTmuxSession,
              let credentialId = profile.credentialId,
              let credentialRecord = UniConnectVault.shared.credentialRecord(for: credentialId),
              let effectiveTarget = credentialRecord.effectiveTarget else {
            return nil
        }
        let safe = UniConnectSSH.sanitizedTmuxName(session)
        if let target = UniConnectSSHTargetKey(
            effectiveTarget: effectiveTarget,
            tmuxSession: safe
        ),
           UniConnectCoordinator.shared.hasConflictingLiveSSHTarget(
               target,
               workspaceID: id,
               panelID: panelSnapshot.id
           ) {
            return UniConnectSSH.duplicateTargetPlaceholderLauncher(session: safe)
        }
        let windowName = panelSnapshot.customTitle ?? panelSnapshot.title ?? safe
        let bridge = UniConnectCoordinator.shared.claudeBridgePlan(
            workspace: self,
            panelID: panelSnapshot.id,
            credentialID: credentialId,
            windowName: windowName,
            tmuxSession: safe
        )
        guard let commandLine = UniConnectSSH.attachCommandLine(
            credentialRecord: credentialRecord,
            session: safe,
            directory: nil,
            bridge: bridge,
            existingSessionOnly: true,
            recoverMissingSession: true
        ), let launcher = UniConnectSSH.writeLauncherScript(
            commandLine: commandLine,
            label: safe,
            delay: UniConnectSSH.nextStaggerDelay()
        ) else {
            UniConnectCoordinator.shared.unregisterClaudeBridgeRoute(panelSnapshot.id)
            return nil
        }
        return launcher
    }

    /// Marks a tmux-bound window whose ssh client died so the tab itself says so.
    func uniConnectMarkDisconnected(panelId: UUID, exitCode: UInt32? = nil) {
        guard uniConnectTmuxSessionsByPanelId[panelId] != nil else { return }
        let suffix = String(
            localized: "uniconnect.window.disconnectedSuffix",
            defaultValue: " · disconnected"
        )
        let localizedSuffixes = [
            suffix,
            " · disconnected",
            " · desconectada"
        ]
        let base = localizedSuffixes.reduce(
            panelCustomTitles[panelId]
                ?? panelTitles[panelId]
                ?? String(localized: "uniconnect.window.fallbackName", defaultValue: "window")
        ) { partial, candidate in
            partial.hasSuffix(candidate) ? String(partial.dropLast(candidate.count)) : partial
        }
        if !base.hasSuffix(suffix) {
            setPanelCustomTitle(panelId: panelId, title: base + suffix)
        }
        uniConnectProfile?.touch()
        uniConnectDisconnectedPanelIds.insert(panelId)
        if UniConnectSSHReconnectPolicy.shouldAutomaticallyReconnect(afterChildExitCode: exitCode) {
            // A transport loss can be recovered without changing the saved tmux binding.
            UniConnectCoordinator.shared.scheduleReconnect(panelId: panelId, in: self)
        } else {
            // Preserve the terminal and its error text, but cancel pending delays and
            // stability resets so a permanent bootstrap error cannot restart the loop.
            UniConnectCoordinator.shared.stopAutomaticReconnect(panelId: panelId, in: self)
        }
    }
}

// MARK: - Welcome overlay host

struct UniConnectSSHWelcomeHost: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var state: UniConnectSSHSetupState

    init(workspace: Workspace) {
        self.workspace = workspace
        self._state = ObservedObject(wrappedValue: UniConnectCoordinator.shared.setupState(for: workspace))
    }

    var body: some View {
        UniConnectSSHWelcomeView(
            workspace: workspace,
            state: state,
            onCreateWindow: { name, tmux in
                UniConnectCoordinator.shared.createSSHWindow(in: workspace, name: name, tmuxSession: tmux)
            },
            onRetry: { UniConnectCoordinator.shared.startProbe(for: workspace) },
            onEditConnection: { UniConnectCoordinator.shared.editConnection(for: workspace) },
            onInstallTmux: { UniConnectCoordinator.shared.installTmux(for: workspace) }
        )
        .onAppear {
            if state.phase == .idle {
                UniConnectCoordinator.shared.startProbe(for: workspace)
            }
        }
    }
}


/// Empty state shown when the app has nothing open (first run, or every box closed).
struct UniConnectStarterHost: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        UniConnectStarterView(
            hasCmuxSession: UniConnectCoordinator.cmuxSessionFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            onNewBox: {
                if let tabManager = workspace.owningTabManager {
                    _ = UniConnectCoordinator.shared.interceptNewWorkspace(tabManager: tabManager)
                }
            },
            onImport: { UniConnectCoordinator.shared.importConfiguration() },
            onMigrate: { UniConnectCoordinator.shared.migrateFromCmux() }
        )
    }
}
