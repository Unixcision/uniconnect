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
        #expect(UniConnectMobileTerminalCreation(
            name: "SSH", tmuxSession: nil, directory: nil, agentID: nil, isSSH: true
        ) == nil)
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
            if kind == .ssh { #expect(ids == ["terminal"]) }
            else { #expect(ids.isSuperset(of: ["claude", "codex", "agy", "grok"])) }
            #expect(targets.allSatisfy { Set($0.keys) == ["id", "title"] })
        }
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
