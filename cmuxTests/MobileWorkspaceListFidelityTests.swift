import Testing
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the mobile workspace-list fidelity fixes: terminals are serialized in
/// the on-screen bonsplit spatial order, a terminal rename re-emits to the phone,
/// and a pure drag-reorder is detected even though it changes no panel-set state.
///
/// `.serialized` because these exercise process-global surface registries via the
/// real `Workspace`/`TabManager`/bonsplit model, which must not run concurrently.
@MainActor
@Suite(.serialized)
struct MobileWorkspaceListFidelityTests {
    @Test("A generic local workspace honors the advertised agent, name and folder without replacing its existing terminal")
    func genericLocalMobileCreationHonorsExplicitLaunchIntent() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let workspace = try #require(manager.selectedWorkspace)
        #expect(workspace.uniConnectProfile == nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectMobileGeneric-\(UUID().uuidString)", isDirectory: true)
        let chosenFolder = root.appendingPathComponent("chosen-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: chosenFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.currentDirectory = root.path
        let selectedPanel = try #require(workspace.focusedPanelId)
        let existing = try #require(workspace.terminalPanel(for: selectedPanel))
        let existingSurface = existing.surface
        let before = Set(workspace.panels.keys)
        defer {
            for id in Set(workspace.panels.keys).subtracting(before) {
                workspace.terminalPanel(for: id)?.surface.teardownSurface()
            }
        }

        let response = await TerminalController.shared.mobileHostHandleRPC(.init(
            id: "generic-local-agent-create", method: "terminal.create",
            params: [
                "workspace_id": workspace.id.uuidString,
                "name": "Revisión desde Android",
                "directory": chosenFolder.path,
                "agent": "codex"
            ], auth: nil
        ))
        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let rawID = payload["created_terminal_id"] as? String,
              let panelID = UUID(uuidString: rawID) else {
            Issue.record("Expected the chosen agent to be created in the existing generic workspace")
            return
        }
        let record = try #require(workspace.uniConnectLocalWindowsByPanelId[panelID])
        let binding = try #require(record.tmuxBinding)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let expectedRoot = try #require(UniConnectLocalWindowRecord.validatedBoxRoot(root.path))
        let expectedFolder = try #require(UniConnectLocalWindowRecord.validatedBoxRoot(chosenFolder.path))
        let agentCommand = try #require(UniConnectLocalWindowLaunchTarget.codex.startupCommand(
            boxRoot: expectedRoot, workingDirectory: expectedFolder
        ))
        let launch = UniConnectLocalTmuxLaunchPlan(
            binding: binding, workingDirectory: expectedFolder, initialCommand: agentCommand
        )
        #expect(panel.surface.initialCommand == launch.startupCommand())
        #expect(record.visibleName == "Revisión desde Android")
        #expect(record.workingDirectory == expectedFolder)
        #expect(record.boxRoot == expectedRoot)
        #expect(workspace.uniConnectProfile?.kind == .local)
        #expect(workspace.uniConnectLocalBoxRoot == expectedRoot)
        #expect(Set(workspace.panels.keys) == before.union([panelID]))
        #expect(workspace.terminalPanel(for: selectedPanel)?.surface === existingSurface)
        #expect(workspace.focusedPanelId == selectedPanel)
        #expect(manager.selectedTabId == workspace.id)
        #expect(workspace.currentDirectory == root.path)
    }

    @Test("An invalid explicit agent does not create a plain fallback or adopt a generic workspace")
    func genericLocalInvalidAgentDoesNotMutateWorkspace() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let workspace = try #require(manager.selectedWorkspace)
        #expect(workspace.uniConnectProfile == nil)
        let before = Set(workspace.panels.keys)
        let selectedPanel = workspace.focusedPanelId
        defer {
            for id in Set(workspace.panels.keys).subtracting(before) {
                workspace.terminalPanel(for: id)?.surface.teardownSurface()
            }
        }
        let response = await TerminalController.shared.mobileHostHandleRPC(.init(
            id: "generic-invalid-agent", method: "terminal.create",
            params: [
                "workspace_id": workspace.id.uuidString,
                "name": "No crear otra consola",
                "directory": FileManager.default.temporaryDirectory.path,
                "agent": "unadvertised-agent"
            ], auth: nil
        ))
        guard case .failure = response else {
            Issue.record("An unsupported explicit agent must fail instead of creating a plain terminal")
            return
        }
        #expect(workspace.uniConnectProfile == nil)
        #expect(Set(workspace.panels.keys) == before)
        #expect(workspace.focusedPanelId == selectedPanel)
    }

    @Test("A remote local-window request uses the same durable tmux path without selecting it")
    func mobileCreationPreservesDesktopFocusAndUsesTmux() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let workspace = try #require(manager.selectedWorkspace)
        let folder = FileManager.default.temporaryDirectory.path
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .local, localRoot: folder)
        let selectedPanel = workspace.focusedPanelId
        let panelCount = workspace.panels.count
        let response = await TerminalController.shared.mobileHostHandleRPC(.init(
            id: "durable-local-create", method: "terminal.create",
            params: ["workspace_id": workspace.id.uuidString, "name": "Desde Android", "directory": folder],
            auth: nil
        ))
        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let rawID = payload["created_terminal_id"] as? String,
              let panelID = UUID(uuidString: rawID) else {
            Issue.record("Expected a created durable local window")
            return
        }
        defer { workspace.terminalPanel(for: panelID)?.surface.teardownSurface() }
        let record = try #require(workspace.uniConnectLocalWindowsByPanelId[panelID])
        #expect(record.tmuxBinding != nil)
        #expect(record.visibleName == "Desde Android")
        #expect(record.workingDirectory == UniConnectLocalWindowRecord.validatedBoxRoot(folder))
        #expect(workspace.panels.count == panelCount + 1)
        #expect(workspace.focusedPanelId == selectedPanel)
        #expect(manager.selectedTabId == workspace.id)
    }

    @Test("Creating or resetting through mobile cannot silently target the selected legacy console")
    func invalidMobileMutationDoesNotChangeExistingPanels() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .local, localRoot: FileManager.default.temporaryDirectory.path
        )
        let before = Set(workspace.panels.keys)
        for (method, params) in [
            ("terminal.create", ["workspace_id": workspace.id.uuidString]),
            ("terminal.create", ["name": "Sin destino explícito"]),
            ("terminal.reset", ["surface_id": panelID.uuidString]),
            ("terminal.reset", ["workspace_id": workspace.id.uuidString, "surface_id": panelID.uuidString]),
        ] {
            let response = await TerminalController.shared.mobileHostHandleRPC(.init(
                id: UUID().uuidString, method: method, params: params, auth: nil
            ))
            guard case .failure = response else {
                Issue.record("Mutation without an explicit durable target must fail")
                continue
            }
            #expect(Set(workspace.panels.keys) == before)
            #expect(workspace.focusedPanelId == panelID)
        }
    }

    @Test("Mobile creation validates explicit intent and delegates local agent selection to the shared request")
    func mobileCreationInputPolicy() throws {
        let local = try #require(UniConnectMobileTerminalCreation(
            name: "Trabajo", tmuxSession: nil, directory: "/repo/api", agentID: "codex", isSSH: false
        ))
        let request = try #require(local.localRequest(boxRoot: "/repo", availableTargets: [.codex]))
        #expect(request.workingDirectory == "/repo/api")
        #expect(request.launchTarget == .codex)
        #expect(request.boxRoot == "/repo")
        #expect(local.localRequest(boxRoot: "/repo", availableTargets: [.claude]) == nil)
        #expect(UniConnectMobileTerminalCreation(
            name: "", tmuxSession: nil, directory: "/repo", agentID: nil, isSSH: false
        ) == nil)
        #expect(UniConnectMobileTerminalCreation(
            name: "Local", tmuxSession: "other", directory: "/repo", agentID: nil, isSSH: false
        ) == nil)
        // Without a session, SSH gets one like the desktop sheet suggests (what Android sends).
        let generated = try #require(UniConnectMobileTerminalCreation(
            name: "SSH", tmuxSession: nil, directory: nil, agentID: nil, isSSH: true
        ))
        let session = try #require(generated.tmuxSession)
        #expect(session.hasPrefix("uc-"))
        #expect(UniConnectSSH.sanitizedTmuxName(session) == session)
        #expect(UniConnectMobileTerminalCreation(
            name: "SSH", tmuxSession: "", directory: nil, agentID: "terminal", isSSH: true
        )?.tmuxSession?.hasPrefix("uc-") == true)
        #expect(UniConnectMobileTerminalCreation(
            name: "SSH", tmuxSession: "valid-session", directory: "/srv/code", agentID: "codex", isSSH: true
        ) == nil)
        let ssh = try #require(UniConnectMobileTerminalCreation(
            name: "SSH", tmuxSession: "valid-session", directory: "/srv/code", agentID: nil, isSSH: true
        ))
        #expect(ssh.tmuxSession == "valid-session")
        #expect(ssh.directory == "/srv/code")
        #expect(ssh.localRequest(boxRoot: "/repo", availableTargets: [.codex]) == nil)
    }

    @Test("Durable identity and lifecycle changes invalidate the mobile list without changing its title")
    func tmuxAndRuntimeChangesInvalidateObserverHash() throws {
        let (workspace, panels) = try makeWorkspaceWithTabTerminals(count: 1)
        let panelID = try #require(panels.first)
        func hash() -> Int {
            MobileWorkspaceListObserver.summaryHashForTesting(tabs: [workspace], selectedTabID: workspace.id)
        }
        let original = hash()
        var record = UniConnectLocalWindowRecord(
            id: panelID, boxRoot: "/repo",
            tmuxBinding: UniConnectLocalTmuxBinding(name: "fixture", socketName: "uc-test")
        )
        workspace.uniConnectLocalWindowsByPanelId[panelID] = record
        let durable = hash()
        #expect(durable != original)
        record.markStopped()
        workspace.uniConnectLocalWindowsByPanelId[panelID] = record
        let stopped = hash()
        #expect(stopped != durable)
        record.transitionToShell()
        workspace.uniConnectLocalWindowsByPanelId[panelID] = record
        #expect(hash() == durable)
        workspace.uniConnectTmuxSessionsByPanelId[panelID] = "remote-fixture"
        #expect(hash() != durable)
    }

    @Test("Mobile workspace metadata advertises local agents but only terminal for SSH")
    func workspaceMetadataDescribesCreationTargets() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let workspace = try #require(manager.selectedWorkspace)
        for kind in [UniConnectWorkspaceKind.local, .ssh] {
            workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: kind, localRoot: "/tmp")
            let response = await TerminalController.shared.mobileHostHandleRPC(.init(
                id: UUID().uuidString, method: "mobile.workspace.list",
                params: ["workspace_id": workspace.id.uuidString], auth: nil
            ))
            guard case let .ok(rawPayload) = response,
                  let payload = rawPayload as? [String: Any],
                  let boxes = payload["workspaces"] as? [[String: Any]],
                  let box = boxes.first, let targets = box["available_agent_targets"] as? [[String: String]] else {
                Issue.record("Expected workspace creation metadata")
                continue
            }
            #expect(box["kind"] as? String == (kind == .ssh ? "ssh" : "local"))
            let ids = Set(targets.compactMap { $0["id"] })
            #expect(ids.contains("terminal"))
            let resolver = AgentExecutableResolver()
            let installed = UniConnectLocalWindowLaunchTarget.installedBuiltInAgents {
                resolver.isInstalled(executableName: $0)
            }.map(\.id)
            // Local: only the installed ones.
            if kind == .ssh {
                #expect(ids == ["terminal"])
            } else {
                let builtIn = Set(UniConnectLocalWindowLaunchTarget.builtInAgents.map(\.id))
                #expect(ids.intersection(builtIn) == Set(installed))
            }
            #expect(targets.allSatisfy { Set($0.keys) == ["id", "title"] })
        }
    }

    @Test("Android: a new local box without a window, then its first window with Claude, attachable and unselected")
    func androidLocalBoxThenFirstAgentWindow() async throws {
        // The UniConnect branch of the mobile host (off by default under XCTest), with the
        // created-window saver replaced so nothing is written outside the test.
        let previousEnable = ProcessInfo.processInfo.environment["UNICONNECT_TEST_ENABLE"]
        setenv("UNICONNECT_TEST_ENABLE", "1", 1)
        let previousPersistence = UniConnectCoordinator.shared.createdWindowPersistence
        UniConnectCoordinator.shared.configureCreatedWindowPersistence(UniConnectCreatedWindowPersistence(
            save: {}, capture: { _ in .unavailable }, sleep: { _ in }
        ))
        defer {
            UniConnectCoordinator.shared.configureCreatedWindowPersistence(previousPersistence)
            if let previousEnable { setenv("UNICONNECT_TEST_ENABLE", previousEnable, 1) } else { unsetenv("UNICONNECT_TEST_ENABLE") }
        }
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectAndroidBox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedBefore = manager.selectedTabId

        // NativeMachineClient.creationParameters(ResourceCreation.Workspace(name, folder, null,
        // initialTerminal = false)), as CreateResourceSheet builds it.
        let boxResponse = await TerminalController.shared.mobileHostHandleRPC(.init(
            id: "android-box", method: "workspace.create",
            params: ["name": "Proyecto Android", "directory": root.path, "kind": "local", "initial_terminal": false],
            auth: nil
        ))
        guard case let .ok(rawBox) = boxResponse, let boxPayload = rawBox as? [String: Any],
              let workspaceID = boxPayload["created_workspace_id"] as? String else {
            Issue.record("Expected the box Android asked for")
            return
        }
        let workspace = try #require(manager.tabs.first { $0.id.uuidString == workspaceID })
        defer { manager.closeWorkspace(workspace, recordHistory: false) }
        let createdBoxes = boxPayload["workspaces"] as? [[String: Any]] ?? []
        let box = try #require(createdBoxes.first(where: { ($0["id"] as? String) == workspaceID }))
        // Android only asks for the first window when the box is local and empty.
        #expect(box["kind"] as? String == "local")
        #expect((box["terminals"] as? [[String: Any]])?.isEmpty == true)
        let offered = Set((box["available_agent_targets"] as? [[String: String]] ?? []).compactMap { $0["id"] })
        #expect(offered.contains("terminal"))
        #expect(manager.selectedTabId == selectedBefore)

        // ResourceCreation.Terminal(workspaceID, "Claude Code", null, null, "claude"): no folder
        // and no tmux session, the title of the chosen agent as the name.
        let windowResponse = await TerminalController.shared.mobileHostHandleRPC(.init(
            id: "android-first-window", method: "mobile.terminal.create",
            params: ["name": "Claude Code", "workspace_id": workspaceID, "agent": "claude"],
            auth: nil
        ))
        guard case let .ok(rawWindow) = windowResponse, let windowPayload = rawWindow as? [String: Any],
              let rawID = windowPayload["created_terminal_id"] as? String,
              let panelID = UUID(uuidString: rawID) else {
            Issue.record("Expected the first window Android asked for")
            return
        }
        defer { workspace.terminalPanel(for: panelID)?.surface.teardownSurface() }
        let boxes = windowPayload["workspaces"] as? [[String: Any]] ?? []
        let listedBox = try #require(boxes.first(where: { ($0["id"] as? String) == workspaceID }))
        let listed = listedBox["terminals"] as? [[String: Any]] ?? []
        #expect(listed.compactMap { $0["id"] as? String } == [rawID])

        let record = try #require(workspace.uniConnectLocalWindowsByPanelId[panelID])
        let binding = try #require(record.tmuxBinding)
        let expectedRoot = try #require(UniConnectLocalWindowRecord.validatedBoxRoot(root.path))
        // Claude starts on the conversation id chosen at creation, already saved with the window.
        let chosen = try #require(record.launch?.sessionID)
        #expect(record.activeConversation?.sessionID == chosen)
        let claude = try #require(UniConnectLocalWindowLaunchTarget.claude.startupCommand(
            boxRoot: expectedRoot, workingDirectory: expectedRoot, extraArguments: ["--session-id", chosen]
        ))
        let launch = UniConnectLocalTmuxLaunchPlan(binding: binding, workingDirectory: expectedRoot, initialCommand: claude)
        #expect(workspace.terminalPanel(for: panelID)?.surface.initialCommand == launch.startupCommand())
        #expect(record.visibleName == "Claude Code")
        #expect(workspace.uniConnectPlaceholderPanelIds.isEmpty)
        #expect(manager.selectedTabId == selectedBefore)

        // mobile.terminal.attach resolves this exact window to its own tmux session.
        let resolver = MobileTmuxTargetResolver(
            tabManagers: { [manager] }, credentialRecord: { _ in nil }, isLocked: { false }
        )
        let plan = try resolver.resolve(workspaceID: workspace.id, surfaceID: panelID)
        #expect(plan.command == MobileTmuxAttachPlan.localCommand(binding: binding))
    }

    @Test("Android: an agent the box advertised is accepted when the window uses another folder")
    func androidAdvertisedAgentWithAnotherFolder() async throws {
        // The UniConnect branch of the mobile host (off by default under XCTest), with the
        // created-window saver replaced so nothing is written outside the test.
        let previousEnable = ProcessInfo.processInfo.environment["UNICONNECT_TEST_ENABLE"]
        setenv("UNICONNECT_TEST_ENABLE", "1", 1)
        let previousPersistence = UniConnectCoordinator.shared.createdWindowPersistence
        UniConnectCoordinator.shared.configureCreatedWindowPersistence(UniConnectCreatedWindowPersistence(
            save: {}, capture: { _ in .unavailable }, sleep: { _ in }
        ))
        defer {
            UniConnectCoordinator.shared.configureCreatedWindowPersistence(previousPersistence)
            if let previousEnable { setenv("UNICONNECT_TEST_ENABLE", previousEnable, 1) } else { unsetenv("UNICONNECT_TEST_ENABLE") }
        }
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectAndroidAgent-\(UUID().uuidString)", isDirectory: true)
        let boxFolder = root.appendingPathComponent("box", isDirectory: true)
        let otherFolder = root.appendingPathComponent("other", isDirectory: true)
        let configFolder = boxFolder.appendingPathComponent(".uniconnect", isDirectory: true)
        try FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        {
          "vault": {
            "agents": [
              {
                "id": "local-agent",
                "name": "Local Agent",
                "detect": { "processName": "local-agent" },
                "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
                "resumeCommand": "local-agent --session {{sessionId}}",
                "cwd": "preserve"
              }
            ]
          }
        }
        """.write(to: configFolder.appendingPathComponent("uniconnect.json"), atomically: true, encoding: .utf8)

        let boxResponse = await TerminalController.shared.mobileHostHandleRPC(.init(
            id: "android-agent-box", method: "workspace.create",
            params: ["name": "Caja con agente", "directory": boxFolder.path, "kind": "local", "initial_terminal": false],
            auth: nil
        ))
        guard case let .ok(rawBox) = boxResponse, let boxPayload = rawBox as? [String: Any],
              let workspaceID = boxPayload["created_workspace_id"] as? String,
              let box = (boxPayload["workspaces"] as? [[String: Any]])?.first(where: { ($0["id"] as? String) == workspaceID }),
              let offered = box["available_agent_targets"] as? [[String: String]] else {
            Issue.record("Expected the box and its catalogue")
            return
        }
        let workspace = try #require(manager.tabs.first { $0.id.uuidString == workspaceID })
        defer { manager.closeWorkspace(workspace, recordHistory: false) }
        let agent = try #require(offered.first { $0["title"] == "Local Agent" })
        let agentID = try #require(agent["id"])

        // ResourceCreation.Terminal(workspaceID, "Local Agent", otherFolder, null, agentID).
        let windowResponse = await TerminalController.shared.mobileHostHandleRPC(.init(
            id: "android-agent-window", method: "mobile.terminal.create",
            params: ["name": "Local Agent", "directory": otherFolder.path, "workspace_id": workspaceID, "agent": agentID],
            auth: nil
        ))
        guard case let .ok(rawWindow) = windowResponse, let windowPayload = rawWindow as? [String: Any],
              let rawID = windowPayload["created_terminal_id"] as? String,
              let panelID = UUID(uuidString: rawID) else {
            Issue.record("An agent offered by the box must not be rejected because of the window folder")
            return
        }
        defer { workspace.terminalPanel(for: panelID)?.surface.teardownSurface() }
        let record = try #require(workspace.uniConnectLocalWindowsByPanelId[panelID])
        let binding = try #require(record.tmuxBinding)
        let boxRoot = try #require(UniConnectLocalWindowRecord.validatedBoxRoot(boxFolder.path))
        let windowFolder = try #require(UniConnectLocalWindowRecord.validatedBoxRoot(otherFolder.path))
        let target = try #require(UniConnectLocalWindowLaunchTarget.customTargets(
            from: CmuxVaultAgentRegistry.load(workingDirectory: boxRoot)
        ).first { $0.id == agentID })
        let command = try #require(target.startupCommand(boxRoot: boxRoot, workingDirectory: windowFolder))
        let launch = UniConnectLocalTmuxLaunchPlan(binding: binding, workingDirectory: windowFolder, initialCommand: command)
        #expect(workspace.terminalPanel(for: panelID)?.surface.initialCommand == launch.startupCommand())
        #expect(record.workingDirectory == windowFolder)
    }

    @Test("Android: the SSH window params it sends are the ones the Mac accepts")
    func androidSSHWindowParameters() throws {
        // CreateResourceSheet for an SSH box: agent "terminal", a lowercase tmux session that
        // matches ResourceCreation's regex (1–40 of [a-z0-9_-], no dash at the ends), a folder.
        for session in ["obra", "uc_web-2", "a", String(repeating: "x", count: 40)] {
            let creation = try #require(UniConnectMobileTerminalCreation(
                name: "Servidor", tmuxSession: session, directory: "/srv/app", agentID: "terminal", isSSH: true
            ))
            #expect(creation.tmuxSession == session)
            #expect(creation.directory == "/srv/app")
        }
        // Without a folder, as when the optional field is left empty.
        #expect(UniConnectMobileTerminalCreation(
            name: "Servidor", tmuxSession: "obra", directory: nil, agentID: "terminal", isSSH: true
        ) != nil)
    }

    @Test("Only installed agents are offered locally: one missing from every folder is not")
    func installedAgentsFilter() {
        let installed = UniConnectLocalWindowLaunchTarget.installedBuiltInAgents { $0 == "claude" || $0 == "codex" }
        #expect(installed.map(\.id) == ["claude", "codex"])
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectNoAgents-\(UUID().uuidString)", isDirectory: true)
        let resolver = AgentExecutableResolver(
            environment: ["PATH": empty.path, "HOME": empty.path], includeStandardSearchDirectories: false
        )
        #expect(!resolver.isInstalled(executableName: "grok"))
        #expect(!resolver.isInstalled(executableName: "../bin/sh"))
    }

    @Test("A local box without a folder opens in the home folder, with its terminal for older clients")
    func localBoxWithoutFolder() async throws {
        // The UniConnect branch of the mobile host (off by default under XCTest), with the
        // created-window saver replaced so nothing is written outside the test.
        let previousEnable = ProcessInfo.processInfo.environment["UNICONNECT_TEST_ENABLE"]
        setenv("UNICONNECT_TEST_ENABLE", "1", 1)
        let previousPersistence = UniConnectCoordinator.shared.createdWindowPersistence
        UniConnectCoordinator.shared.configureCreatedWindowPersistence(UniConnectCreatedWindowPersistence(
            save: {}, capture: { _ in .unavailable }, sleep: { _ in }
        ))
        defer {
            UniConnectCoordinator.shared.configureCreatedWindowPersistence(previousPersistence)
            if let previousEnable { setenv("UNICONNECT_TEST_ENABLE", previousEnable, 1) } else { unsetenv("UNICONNECT_TEST_ENABLE") }
        }
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        let response = await TerminalController.shared.mobileHostHandleRPC(.init(
            id: "box-without-folder", method: "workspace.create",
            params: ["name": "Sin carpeta", "kind": "local"], auth: nil
        ))
        guard case let .ok(rawPayload) = response, let payload = rawPayload as? [String: Any],
              let workspaceID = payload["created_workspace_id"] as? String else {
            Issue.record("A local box without a folder must be created in the home folder")
            return
        }
        let workspace = try #require(manager.tabs.first { $0.id.uuidString == workspaceID })
        defer {
            for panel in workspace.panels.values { (panel as? TerminalPanel)?.surface.teardownSurface() }
            manager.closeWorkspace(workspace, recordHistory: false)
        }
        let home = try #require(UniConnectLocalWindowRecord.validatedBoxRoot(
            FileManager.default.homeDirectoryForCurrentUser.path
        ))
        #expect(workspace.uniConnectLocalBoxRoot == home)
        // No `initial_terminal`: an older client still gets its plain terminal.
        #expect(workspace.uniConnectLocalWindowsByPanelId.count == 1)
    }

    @Test("SSH with the default folder starts in the remote home, never in this Mac's")
    func sshDefaultFolderIsRemote() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let command = UniConnectSSH.remoteTmuxCommand(session: "uc-obra-1a2b", directory: nil)
        #expect(!command.contains(" -c "))
        #expect(!command.contains(home))
        #expect(UniConnectSSH.remoteTmuxCommand(session: "uc-obra-1a2b", directory: "/srv/app").contains("-c '/srv/app'"))
    }

    /// Builds a workspace with `count` terminals as tabs in a single pane so that
    /// a within-pane `reorderTab` genuinely changes their on-screen order. Returns
    /// the workspace and panel ids in spatial (tab) order.
    private func makeWorkspaceWithTabTerminals(count: Int) throws -> (Workspace, [UUID]) {
        precondition(count >= 1)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        var orderedIds: [UUID] = [try #require(workspace.focusedPanelId)]
        for _ in 1..<count {
            let panel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
            orderedIds.append(panel.id)
        }
        return (workspace, orderedIds)
    }

    /// Builds a workspace with `count` terminals laid out left-to-right via
    /// horizontal splits (each in its own pane), returning the workspace and panel
    /// ids in spatial order.
    private func makeWorkspaceWithSplitTerminals(count: Int) throws -> (Workspace, [UUID]) {
        precondition(count >= 1)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        var orderedIds: [UUID] = [try #require(workspace.focusedPanelId)]
        for _ in 1..<count {
            let previous = try #require(orderedIds.last)
            let panel = try #require(
                workspace.newTerminalSplit(from: previous, orientation: .horizontal, focus: false)
            )
            orderedIds.append(panel.id)
        }
        return (workspace, orderedIds)
    }

    @Test func orderedPanelIdsMatchesBonsplitSpatialOrder() throws {
        let (workspace, createdOrder) = try makeWorkspaceWithSplitTerminals(count: 3)

        // orderedPanelIds is derived from bonsplit's left-to-right tab ordering.
        let ordered = workspace.orderedPanelIds
        #expect(Set(ordered) == Set(createdOrder), "should contain exactly the created panels")

        // It must equal bonsplit's own allTabIds mapping (the spatial source of
        // truth), not dictionary/UUID order.
        let expected = workspace.bonsplitController.allTabIds.compactMap {
            workspace.panelIdFromSurfaceId($0)
        }
        #expect(ordered == expected)
    }

    @Test func reorderingTerminalsChangesObserverHashAndBumpsLayoutVersion() throws {
        // Tabs in one pane so a within-pane reorder genuinely changes their order.
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 3)
        #expect(ordered.count == 3)

        let versionBefore = workspace.paneLayoutVersion
        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        // Move the first terminal to the end. Same panel set, different spatial order.
        let firstTabId = try #require(workspace.surfaceIdFromPanelId(ordered[0]))
        #expect(workspace.bonsplitController.reorderTab(firstTabId, toIndex: 2))

        // Sanity: the id set is unchanged, but the order changed.
        let afterOrder = workspace.orderedPanelIds
        #expect(Set(afterOrder) == Set(ordered))
        #expect(afterOrder != ordered, "reorder should change the ordered sequence")

        // The reorder must wake the observer (bonsplit selection state is not
        // @Published, so paneLayoutVersion is the only signal).
        #expect(
            workspace.paneLayoutVersion > versionBefore,
            "a pure reorder must bump paneLayoutVersion so the observer re-evaluates"
        )

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a pure reorder must change the mobile summary hash")
    }

    @Test func renamingTerminalChangesObserverHashAndDisplayedTitle() throws {
        let (workspace, ordered) = try makeWorkspaceWithTabTerminals(count: 2)
        let panelId = try #require(ordered.first)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        // A terminal rename sets panelCustomTitles (not panelTitles); the observer
        // must still detect it, and panelTitle must resolve to the custom title that
        // the mobile workspace.list response serializes.
        workspace.setPanelCustomTitle(panelId: panelId, title: "Renamed Terminal")
        #expect(workspace.panelTitle(panelId: panelId) == "Renamed Terminal")

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a terminal rename must change the mobile summary hash")
    }

    @Test func renamingWorkspaceChangesObserverHashAndDisplayedTitle() throws {
        let (workspace, _) = try makeWorkspaceWithTabTerminals(count: 1)

        let before = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )

        workspace.setCustomTitle("Renamed Workspace")
        // The mobile workspace.list response sends workspace.title.
        #expect(workspace.title == "Renamed Workspace")

        let after = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(before != after, "a workspace rename must change the mobile summary hash")
    }
}
