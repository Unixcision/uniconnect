import AppKit
import SwiftUI
import CryptoKit

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

    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        // Off under XCTest so the inherited cmux test-suite (shortcut routing, workspace
        // creation, CLI) keeps exercising stock behaviour; off on demand for dogfooding.
        if env["XCTestConfigurationFilePath"] != nil { return false }
        return env["UNICONNECT_DISABLE"] != "1"
    }

    private init() {}

    // MARK: Window helpers

    private func hostWindow(for tabManager: TabManager?) -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
    }

    private func presentError(_ message: String, title: String = "UniConnect") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Vale")
        alert.runModal()
    }

    // MARK: "+" → Local / SSH

    /// Returns true when UniConnect handled the request (a sheet is showing or a
    /// workspace was created). False lets cmux fall back to its stock behaviour.
    func interceptNewWorkspace(tabManager: TabManager) -> Bool {
        guard Self.isEnabled else { return false }
        let window = hostWindow(for: tabManager)
        UniConnectSheet.present(on: window, size: CGSize(width: 480, height: 400)) { dismiss in
            UniConnectNewWorkspaceView(
                onLocal: { [weak self, weak tabManager] result in
                    dismiss()
                    guard let self, let tabManager else { return }
                    self.createLocalWorkspace(
                        name: result.name,
                        folder: result.folder,
                        color: result.color,
                        in: tabManager
                    )
                },
                onSSH: { [weak self, weak tabManager] result in
                    dismiss()
                    guard let self, let tabManager else { return }
                    self.createSSHWorkspace(
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

    @discardableResult
    func createLocalWorkspace(
        name: String,
        folder: String,
        color: String?,
        in tabManager: TabManager,
        select: Bool = true
    ) -> Workspace {
        let workspace = tabManager.addWorkspace(
            title: name,
            workingDirectory: folder,
            inheritWorkingDirectory: false,
            select: select,
            autoWelcomeIfNeeded: false
        )
        workspace.uniConnectProfile = .local
        workspace.setCustomColor(color)
        if (workspace.customDescription ?? "").isEmpty {
            workspace.setCustomDescription("Local · \((folder as NSString).abbreviatingWithTildeInPath)")
        }
        requestSave()
        return workspace
    }

    @discardableResult
    func createSSHWorkspace(
        name: String,
        color: String?,
        connectCommand: String,
        in tabManager: TabManager,
        select: Bool = true,
        probeImmediately: Bool = true
    ) -> Workspace {
        let credentialId = UniConnectVault.shared.store(connectCommand: connectCommand)
        let workspace = tabManager.addWorkspace(
            title: name,
            workingDirectory: nil,
            inheritWorkingDirectory: false,
            select: select,
            autoWelcomeIfNeeded: false
        )
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: credentialId,
            hostLabel: UniConnectSSH.hostLabel(from: connectCommand),
            tmuxReady: false
        )
        // The stock initial terminal is only a placeholder hidden behind the
        // welcome page; it gets replaced by the first tmux window.
        workspace.uniConnectPlaceholderPanelIds = Set(workspace.panels.keys)
        workspace.setCustomColor(color)
        if (workspace.customDescription ?? "").isEmpty {
            workspace.setCustomDescription("SSH · \(UniConnectSSH.hostLabel(from: connectCommand)) · tmux")
        }
        requestSave()
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
        guard let profile = workspace.uniConnectProfile, profile.isSSH,
              let credentialId = profile.credentialId,
              let connect = UniConnectVault.shared.connectCommand(for: credentialId) else {
            let state = setupState(for: workspace)
            state.phase = .failed("No se encuentra el comando de conexión guardado.")
            return
        }
        probes[workspace.id]?.cancel()
        let state = setupState(for: workspace)
        state.phase = .connecting
        state.log = ["$ \(UniConnectSSH.hostLabel(from: connect)) — comprobando tmux…"]
        runProbe(for: workspace, connect: connect, state: state, install: false)
    }

    /// Second step of the welcome flow: the user confirmed the tmux installation.
    func installTmux(for workspace: Workspace) {
        guard let profile = workspace.uniConnectProfile, profile.isSSH,
              let credentialId = profile.credentialId,
              let connect = UniConnectVault.shared.connectCommand(for: credentialId) else { return }
        let state = setupState(for: workspace)
        state.phase = .installing
        state.log.append("⏳ instalando tmux…")
        runProbe(for: workspace, connect: connect, state: state, install: true)
    }

    private func runProbe(for workspace: Workspace, connect: String, state: UniConnectSSHSetupState, install: Bool) {
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
        probe.start(connectCommand: connect)
    }

    static func humanizeSSHFailure(_ message: String, log: [String]) -> String {
        let joined = log.joined(separator: "\n").lowercased()
        if joined.contains("permission denied") || joined.contains("authentication fail") {
            return "Autenticación rechazada. Revisa usuario, contraseña o clave del comando de conexión."
        }
        if joined.contains("could not resolve") || joined.contains("name or service not known") {
            return "No se resuelve el host. Revisa la IP o el nombre del servidor."
        }
        if joined.contains("connection refused") || joined.contains("timed out") || joined.contains("no route") {
            return "No hay conexión con el servidor (rechazada o sin respuesta). ¿Firewall, puerto o red?"
        }
        if joined.contains("sudo") && (joined.contains("password") || joined.contains("not allowed")) {
            return "El usuario no tiene sudo sin contraseña: no puedo instalar tmux. Instálalo a mano o conecta como root."
        }
        if joined.contains("gestor de paquetes desconocido") {
            return "Sistema sin gestor de paquetes conocido. Instala tmux a mano y reintenta."
        }
        if joined.contains("sshpass: command not found") || joined.contains("sshpass: not found") {
            return "Falta sshpass en este Mac (brew install hudochenkov/sshpass/sshpass)."
        }
        return message
    }

    func editConnection(for workspace: Workspace) {
        guard let profile = workspace.uniConnectProfile, profile.isSSH else { return }
        UniConnectAppLock.shared.authenticateForSensitiveAction(reason: "Mostrar el comando de conexión") { [weak self, weak workspace] ok in
            guard ok, let self, let workspace else { return }
            self.editConnectionAuthenticated(for: workspace, profile: profile)
        }
    }

    private func editConnectionAuthenticated(for workspace: Workspace, profile: UniConnectWorkspaceProfile) {
        let current = profile.credentialId.flatMap { UniConnectVault.shared.connectCommand(for: $0) } ?? ""
        let alert = NSAlert()
        alert.messageText = "Editar conexión"
        alert.informativeText = "Comando completo de conexión (se guarda cifrado)."
        let input = NSTextField(string: current)
        input.frame = NSRect(x: 0, y: 0, width: 420, height: 22)
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = input
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let command = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.contains("\n") else { return }
        var updated = profile
        let id = profile.credentialId ?? UUID()
        UniConnectVault.shared.store(connectCommand: command, id: id)
        updated.credentialId = id
        updated.hostLabel = UniConnectSSH.hostLabel(from: command)
        updated.tmuxReady = false
        workspace.uniConnectProfile = updated
        requestSave()
        startProbe(for: workspace)
    }

    // MARK: Windows (tabs) inside an SSH workspace

    /// Intercepts Cmd+T / "+" tab creation inside an SSH workspace.
    func interceptNewSurface(in workspace: Workspace) -> Bool {
        guard Self.isEnabled, let profile = workspace.uniConnectProfile, profile.isSSH else { return false }
        let window = hostWindow(for: nil)
        let title = workspace.customTitle ?? workspace.title
        UniConnectSheet.present(on: window, size: CGSize(width: 440, height: 250)) { dismiss in
            UniConnectNewWindowView(
                workspaceName: title,
                onCreate: { [weak self, weak workspace] name, tmux in
                    dismiss()
                    guard let self, let workspace else { return }
                    self.createSSHWindow(in: workspace, name: name, tmuxSession: tmux)
                },
                onCancel: { dismiss() }
            )
        }
        return true
    }

    @discardableResult
    func createSSHWindow(
        in workspace: Workspace,
        name: String,
        tmuxSession rawSession: String,
        directory: String? = nil,
        focus: Bool = true
    ) -> TerminalPanel? {
        guard let profile = workspace.uniConnectProfile, profile.isSSH,
              let credentialId = profile.credentialId,
              let connect = UniConnectVault.shared.connectCommand(for: credentialId) else {
            presentError("Esta caja no tiene comando de conexión guardado.")
            return nil
        }
        let session = UniConnectSSH.sanitizedTmuxName(rawSession)
        if let duplicate = workspace.uniConnectTmuxSessionsByPanelId.first(where: { $0.value == session && workspace.panels[$0.key] != nil }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Ese código tmux ya está en uso"
            let existingName = workspace.panelCustomTitles[duplicate.key] ?? workspace.panelTitles[duplicate.key] ?? "otra ventana"
            alert.informativeText = "La ventana \"\(existingName)\" ya usa la sesión tmux \"\(session)\". Dos ventanas sobre la misma sesión se pisan (tmux desengancha a la otra). ¿Abrirla igualmente?"
            alert.addButton(withTitle: "Abrir igualmente")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        let commandLine = UniConnectSSH.attachCommandLine(connectCommand: connect, session: session, directory: directory)
        guard let launcher = UniConnectSSH.writeLauncherScript(commandLine: commandLine, label: session) else {
            presentError("No se pudo preparar el lanzador de la ventana.")
            return nil
        }
        guard let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }
        guard let panel = workspace.newTerminalSurface(
            inPane: pane,
            focus: focus,
            initialCommand: launcher,
            suppressWorkspaceRemoteStartupCommand: true
        ) else {
            presentError("No se pudo abrir la ventana.")
            return nil
        }
        workspace.uniConnectTmuxSessionsByPanelId[panel.id] = session
        workspace.setPanelCustomTitle(panelId: panel.id, title: name)
        removePlaceholders(from: workspace, keeping: panel.id)
        requestSave()
        return panel
    }

    private func removePlaceholders(from workspace: Workspace, keeping keep: UUID) {
        var placeholders = workspace.uniConnectPlaceholderPanelIds.subtracting([keep])
        // If this is the first tmux window, any other terminal without a tmux binding is a
        // stock placeholder (cmux always keeps at least one panel alive) → drop it too.
        let boundPanels = workspace.panels.keys.filter { workspace.uniConnectTmuxSessionsByPanelId[$0] != nil }
        if boundPanels == [keep] {
            for panelId in workspace.panels.keys where panelId != keep && workspace.panels[panelId] is TerminalPanel {
                placeholders.insert(panelId)
            }
        }
        workspace.uniConnectPlaceholderPanelIds.removeAll()
        for panelId in placeholders where workspace.panels[panelId] != nil {
            _ = workspace.closePanel(panelId, force: true)
        }
    }

    // MARK: Startup seed (UNICONNECT_IMPORT_SEED=<path>)

    /// Imports a plain JSON seed or an encrypted export at launch. Used for the very
    /// first configuration and for automated end-to-end checks. Each file is applied
    /// once: a marker with its SHA-256 is written next to the vault.
    func applyStartupSeedIfNeeded() {
        guard Self.isEnabled,
              let path = ProcessInfo.processInfo.environment["UNICONNECT_IMPORT_SEED"], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            NSLog("[UniConnect] seed not readable: %@", url.path)
            return
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let marker = UniConnectPaths.directory.appendingPathComponent("seed-\(digest.prefix(16)).applied")
        if FileManager.default.fileExists(atPath: marker.path),
           ProcessInfo.processInfo.environment["UNICONNECT_IMPORT_SEED_FORCE"] != "1" {
            return
        }
        do {
            switch try UniConnectBackup.inspect(data: data) {
            case .plainSeed(let document):
                applyImport(document.workspaces)
                try? Data().write(to: marker)
                NSLog("[UniConnect] seed applied: %d workspaces", document.workspaces.count)
            case .encrypted:
                NSLog("[UniConnect] seed is encrypted; use Importar configuración… from the menu")
            }
        } catch {
            NSLog("[UniConnect] seed rejected: %@", error.localizedDescription)
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
        AppDelegate.shared?.uniConnectPersistSessionNow()
        do {
            let url = try UniConnectBackup.persistNow(tabManagers: allTabManagers())
            if showConfirmation {
                let alert = NSAlert()
                alert.messageText = "Persistido"
                alert.informativeText = "Backup cifrado guardado en:\n\(url.path)\n\nTambién se ha guardado la sesión completa de la app."
                alert.addButton(withTitle: "Vale")
                alert.addButton(withTitle: "Mostrar en Finder")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } catch {
            presentError("No se pudo guardar el backup: \(error.localizedDescription)")
        }
    }

    func exportConfiguration() {
        UniConnectAppLock.shared.authenticateForSensitiveAction(reason: "Exportar la configuración (incluye secretos cifrados)") { [weak self] ok in
            guard ok, let self else { return }
            self.exportConfigurationAuthenticated()
        }
    }

    private func exportConfigurationAuthenticated() {
        let document = UniConnectBackup.buildDocument(tabManagers: allTabManagers())
        let window = hostWindow(for: nil)
        UniConnectSheet.present(on: window, size: CGSize(width: 420, height: 230)) { dismiss in
            UniConnectPassphraseView(
                title: "Exportar configuración",
                message: "El fichero incluye los comandos SSH (con contraseñas). Va cifrado con AES-256-GCM y una clave derivada de esta contraseña; sin ella no se puede abrir.",
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
            presentError("No se pudo exportar: \(error.localizedDescription)")
        }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Importar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importConfiguration(from: url)
    }

    func importConfiguration(from url: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentError("No se pudo leer el fichero: \(error.localizedDescription)")
            return
        }
        let source: UniConnectBackup.ImportSource
        do {
            source = try UniConnectBackup.inspect(data: data)
        } catch {
            presentError(error.localizedDescription, title: "Fichero rechazado")
            return
        }
        // Importing creates workspaces with secrets: require a fresh Touch ID.
        UniConnectAppLock.shared.authenticateForSensitiveAction(reason: "Importar configuración") { [weak self] ok in
            guard ok, let self else { return }
            switch source {
            case .plainSeed(let document):
                self.previewImport(document)
            case .encrypted(let container):
                let window = self.hostWindow(for: nil)
                UniConnectSheet.present(on: window, size: CGSize(width: 420, height: 200)) { dismiss in
                    UniConnectPassphraseView(
                        title: "Importar configuración",
                        message: "Fichero de \(container.meta.app) guardado el \(container.meta.savedAt) con \(container.meta.workspaces) cajas. Escribe la contraseña con la que se exportó.",
                        confirm: false,
                        onSubmit: { [weak self] passphrase in
                            dismiss()
                            do {
                                let document = try UniConnectBackup.decrypt(container: container, passphrase: passphrase)
                                self?.previewImport(document)
                            } catch {
                                self?.presentError(error.localizedDescription, title: "No se pudo descifrar")
                            }
                        },
                        onCancel: { dismiss() }
                    )
                }
            }
        }
    }

    private func previewImport(_ document: UniConnectDocument) {
        let existingNames = Set(allTabManagers().flatMap { $0.tabs.map { ($0.customTitle ?? $0.title).lowercased() } })
        let rows = document.workspaces.map {
            UniConnectImportPreviewView.Row(workspace: $0, existsAlready: existingNames.contains($0.name.lowercased()))
        }
        let window = hostWindow(for: nil)
        UniConnectSheet.present(on: window, size: CGSize(width: 560, height: 460)) { dismiss in
            UniConnectImportPreviewView(
                rows: rows,
                onImport: { [weak self] selected in
                    dismiss()
                    self?.applyImport(selected)
                },
                onCancel: { dismiss() }
            )
        }
    }

    func applyImport(_ workspaces: [UniConnectDocument.Workspace]) {
        guard let tabManager = AppDelegate.shared?.uniConnectActiveTabManager() ?? allTabManagers().first else {
            presentError("No hay ventana principal donde importar.")
            return
        }
        var created: [Workspace] = []
        var groupMembers: [String: [UUID]] = [:]
        for (index, item) in workspaces.enumerated() {
            let isLast = index == workspaces.count - 1
            switch item.kind {
            case .local:
                let folder = ((item.cwd ?? "~") as NSString).expandingTildeInPath
                let workspace = createLocalWorkspace(name: item.name, folder: folder, color: item.color, in: tabManager, select: isLast)
                seedLocalWindows(item.windows, in: workspace)
                created.append(workspace)
                if let group = item.group { groupMembers[group, default: []].append(workspace.id) }
            case .ssh:
                guard let connect = item.connect else { continue }
                let workspace = createSSHWorkspace(
                    name: item.name,
                    color: item.color,
                    connectCommand: connect,
                    in: tabManager,
                    select: isLast,
                    probeImmediately: false
                )
                // Windows are recreated eagerly: tmux new-session -A creates or attaches,
                // so importing on a fresh server just creates the sessions.
                var profile = workspace.uniConnectProfile ?? UniConnectWorkspaceProfile(kind: .ssh)
                if !item.windows.isEmpty {
                    profile.tmuxReady = true
                    workspace.uniConnectProfile = profile
                    for window in item.windows {
                        let name = window.name ?? window.tmux ?? "ventana"
                        let session = window.tmux ?? UniConnectSSH.suggestedTmuxName(windowName: name)
                        createSSHWindow(in: workspace, name: name, tmuxSession: session, directory: item.cwd, focus: false)
                    }
                } else {
                    startProbe(for: workspace)
                }
                created.append(workspace)
                if let group = item.group { groupMembers[group, default: []].append(workspace.id) }
            }
        }
        for (name, ids) in groupMembers where !ids.isEmpty {
            if let existing = tabManager.workspaceGroups.first(where: { $0.name == name }) {
                for id in ids { tabManager.assignGroup(workspaceId: id, groupId: existing.id) }
            } else {
                _ = tabManager.createWorkspaceGroup(name: name, childWorkspaceIds: ids, selectAnchor: false)
            }
        }
        requestSave()
    }

    private func seedLocalWindows(_ windows: [UniConnectDocument.Window], in workspace: Workspace) {
        guard !windows.isEmpty else { return }
        // The first window reuses the initial terminal; the rest are new tabs.
        var panelIds = workspace.uniConnectOrderedTerminalPanelIds()
        for (index, window) in windows.enumerated() {
            let panelId: UUID?
            if index < panelIds.count {
                panelId = panelIds[index]
            } else if let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first {
                let resume = window.claudeSession.map { "claude --dangerously-skip-permissions --resume \($0)" }
                panelId = workspace.newTerminalSurface(
                    inPane: pane,
                    focus: false,
                    workingDirectory: window.cwd,
                    initialInput: resume.map { $0 + "\n" }
                )?.id
                if let panelId { panelIds.append(panelId) }
            } else {
                panelId = nil
            }
            if let panelId, let name = window.name, !name.isEmpty {
                workspace.setPanelCustomTitle(panelId: panelId, title: name)
            }
            if index == 0, let panelId, let session = window.claudeSession, let panel = workspace.panels[panelId] as? TerminalPanel {
                workspace.sendInputWhenReady("claude --dangerously-skip-permissions --resume \(session)\n", to: panel)
            }
        }
    }

    func saveSeedTemplate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "uniconnect-seed.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try UniConnectBackup.seedTemplate().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError("No se pudo guardar la plantilla: \(error.localizedDescription)")
        }
    }

    // MARK: Closed items ("Cerradas")

    func showClosedItemsMenu(tabManager: TabManager?) {
        let snapshot = ClosedItemHistoryStore.shared.menuSnapshot(maxItemCount: 40)
        let menu = NSMenu(title: "Cerradas")
        if snapshot.items.isEmpty {
            let item = NSMenuItem(title: "No hay ventanas ni cajas cerradas", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for entry in snapshot.items {
            let item = NSMenuItem(title: entry.menuTitle, action: #selector(reopenClosedItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            let submenu = NSMenu()
            let reopen = NSMenuItem(title: "Reabrir", action: #selector(reopenClosedItem(_:)), keyEquivalent: "")
            reopen.target = self
            reopen.representedObject = entry.id
            let delete = NSMenuItem(title: "Eliminar definitivamente…", action: #selector(deleteClosedItem(_:)), keyEquivalent: "")
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
        guard let id = sender.representedObject as? UUID else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "¿Eliminar definitivamente?"
        alert.informativeText = "Se borra de Cerradas y ya no podrás reabrirla desde UniConnect. Las sesiones tmux del servidor NO se tocan."
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = ClosedItemHistoryStore.shared.removeRecord(id: id)
    }
}

// MARK: - Workspace helpers

extension Workspace {
    var uniConnectIsSSH: Bool { uniConnectProfile?.isSSH == true }

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

    /// Startup command for a restored terminal panel bound to a tmux session.
    /// Returns nil for anything that is not an SSH/tmux window.
    func uniConnectRestoredStartupCommand(panelSnapshot: SessionPanelSnapshot) -> String? {
        guard let profile = uniConnectProfile, profile.isSSH,
              let session = panelSnapshot.terminal?.uniConnectTmuxSession,
              let credentialId = profile.credentialId,
              let connect = UniConnectVault.shared.connectCommand(for: credentialId) else {
            return nil
        }
        let safe = UniConnectSSH.sanitizedTmuxName(session)
        let commandLine = UniConnectSSH.attachCommandLine(connectCommand: connect, session: safe, directory: nil)
        return UniConnectSSH.writeLauncherScript(commandLine: commandLine, label: safe)
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
