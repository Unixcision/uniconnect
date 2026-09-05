import XCTest
import Testing
import Bonsplit
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func workspaceSplitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
    switch node {
    case .pane:
        return []
    case .split(let split):
        return [split] + workspaceSplitNodes(in: split.first) + workspaceSplitNodes(in: split.second)
    }
}

#if DEBUG
@MainActor
@Suite
struct UniConnectNewTerminalRoutingTests {
    @Test(arguments: [UniConnectWorkspaceKind.local, .ssh])
    func toolbarNewTerminalKeepsClickedPaneWithoutCreatingBeforeConfirmation(kind: UniConnectWorkspaceKind) throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let source = try #require(workspace.focusedPanelId)
        let clickedPane = try #require(workspace.paneId(forPanelId: source))
        let other = try #require(workspace.newTerminalSplit(from: source, orientation: .horizontal))
        workspace.focusPanel(other.id)
        workspace.uniConnectProfile = .init(kind: kind, localRoot: NSTemporaryDirectory())
        let beforePanelIDs = Set(workspace.panels.keys)
        let beforePanes = workspace.bonsplitController.allPaneIds
        var requests: [UniConnectNewWindowPlacement] = []
        workspace.debugInterceptNewTerminalRequest = { requests.append($0); return true }

        workspace.bonsplitController.requestNewTab(kind: "terminal", inPane: clickedPane)

        #expect(requests == [.tab(paneID: clickedPane, afterTabID: nil)])
        #expect(Set(workspace.panels.keys) == beforePanelIDs)
        #expect(workspace.bonsplitController.allPaneIds == beforePanes)
        #expect(workspace.focusedPanelId == other.id)
    }

    @Test
    func toolbarSplitsUseCustomRequestBeforeBonsplitMutatesLayout() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let source = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.paneId(forPanelId: source))
        let defaults = BonsplitConfiguration.SplitActionButton.defaults
        let routed = Workspace.workspaceRoutedSplitButtons(defaults, uniConnectEnabled: true)
        #expect(routed.map(\.id) == defaults.map(\.id))
        #expect(routed.map(\.icon) == defaults.map(\.icon))
        let tooltips = workspace.bonsplitController.configuration.appearance.splitButtonTooltips
        #expect(routed[2].tooltip == tooltips.splitRight)
        #expect(routed[3].tooltip == tooltips.splitDown)
        #expect(Workspace.workspaceRoutedSplitButtons(defaults, uniConnectEnabled: false) == defaults)
        workspace.bonsplitController.configuration.appearance.splitButtons = routed
        var requests: [UniConnectNewWindowPlacement] = []
        workspace.debugInterceptNewTerminalRequest = { requests.append($0); return true }

        for button in workspace.bonsplitController.configuration.appearance.splitButtons {
            if case .custom(let identifier) = button.action {
                workspace.bonsplitController.requestCustomAction(identifier, inPane: pane)
            }
        }

        #expect(requests == [
            .split(sourcePanelID: source, orientation: .horizontal, insertFirst: false),
            .split(sourcePanelID: source, orientation: .vertical, insertFirst: false)
        ])
        #expect(workspace.bonsplitController.allPaneIds == [pane])
        #expect(Set(workspace.panels.keys) == [source])
    }

    @Test
    func routedSplitTooltipsRefreshDefaultsButPreserveConfiguredText() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.applySurfaceTabBarButtons(
            [
                .init(id: "default-right", action: .builtIn(.splitRight)),
                .init(id: "blank-down", tooltip: "  ", action: .builtIn(.splitDown)),
                .init(id: "custom-right", tooltip: "My custom split", action: .builtIn(.splitRight))
            ],
            sourcePath: nil,
            globalConfigPath: "/tmp/uniconnect-tooltip-test.json",
            terminalCommandSourcePaths: [:],
            workspaceCommands: [:]
        )
        var configuration = workspace.bonsplitController.configuration
        configuration.appearance.splitButtons = Workspace.workspaceRoutedSplitButtons(
            configuration.appearance.splitButtons,
            uniConnectEnabled: true
        )
        #expect(configuration.appearance.splitButtons[2].tooltip == "My custom split")
        // Simulate a previously rendered default from before a shortcut refresh, without
        // changing shared settings or the user's preference domain.
        configuration.appearance.splitButtons[0].tooltip = "previous shortcut label"
        configuration.appearance.splitButtons[1].tooltip = "previous shortcut label"
        workspace.bonsplitController.configuration = configuration

        workspace.refreshSplitButtonTooltips()

        let appearance = workspace.bonsplitController.configuration.appearance
        #expect(appearance.splitButtons[0].tooltip == appearance.splitButtonTooltips.splitRight)
        #expect(appearance.splitButtons[1].tooltip == appearance.splitButtonTooltips.splitDown)
        #expect(appearance.splitButtons[2].tooltip == "My custom split")
    }

    @Test
    func contextNewTerminalRetainsAnchorAndCancelledSplitKeepsZoom() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let source = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.paneId(forPanelId: source))
        let anchor = try #require(workspace.surfaceIdFromPanelId(source))
        _ = try #require(workspace.newTerminalSplit(from: source, orientation: .horizontal, focus: false))
        _ = workspace.toggleSplitZoom(panelId: source)
        let beforePanes = workspace.bonsplitController.allPaneIds
        let beforePanelIDs = Set(workspace.panels.keys)
        var requests: [UniConnectNewWindowPlacement] = []
        workspace.debugInterceptNewTerminalRequest = { requests.append($0); return true }

        workspace.bonsplitController.requestTabContextAction(.newTerminalToRight, for: anchor, inPane: pane)
        let accepted = workspace.requestNewTerminal(placement: .split(
            sourcePanelID: source, orientation: .vertical, insertFirst: true
        ))

        #expect(accepted)
        #expect(requests == [
            .tab(paneID: pane, afterTabID: anchor),
            .split(sourcePanelID: source, orientation: .vertical, insertFirst: true)
        ])
        #expect(workspace.bonsplitController.isSplitZoomed)
        #expect(workspace.bonsplitController.allPaneIds == beforePanes)
        #expect(Set(workspace.panels.keys) == beforePanelIDs)
    }

    @Test
    func uiSplitReportsHandledWhileProgrammaticSplitStaysSynchronous() throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let source = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.paneId(forPanelId: source))
        var requests: [UniConnectNewWindowPlacement] = []
        workspace.debugInterceptNewTerminalRequest = { requests.append($0); return true }

        #expect(manager.requestNewTerminalSplit(tabId: workspace.id, surfaceId: source, direction: .left))
        #expect(requests == [.split(sourcePanelID: source, orientation: .horizontal, insertFirst: true)])
        #expect(workspace.bonsplitController.allPaneIds == [pane])
        let created = try #require(manager.newSplit(
            tabId: workspace.id, surfaceId: source, direction: .down, focus: false,
            initialCommand: "/usr/bin/false"
        ))
        #expect(requests.count == 1)
        #expect(workspace.terminalPanel(for: created) != nil)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
    }

    @Test
    func restoreKeepsIndependentWindowDirectoryWhenWorkspaceDefaultIsMissing() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-window-restore-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = fixture.appendingPathComponent("window", isDirectory: true)
        let missingDefault = fixture.appendingPathComponent("missing-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let savedID = try #require(snapshot.panels.first?.id)
        let record = UniConnectLocalWindowRecord(
            id: savedID, visibleName: "Independent window",
            boxRoot: missingDefault.path, workingDirectory: workingDirectory.path
        )
        snapshot.uniConnect = .init(kind: .local, localRoot: missingDefault.path)
        snapshot.panels[0].terminal = SessionTerminalPanelSnapshot(
            workingDirectory: record.workingDirectory,
            wasAgentRunning: false,
            uniConnectLocalWindow: record
        )

        _ = workspace.restoreSessionSnapshot(snapshot)

        let restored = try #require(workspace.terminalPanel(for: savedID))
        #expect(restored.requestedWorkingDirectory == record.workingDirectory)
        #expect(workspace.uniConnectLocalWindowsByPanelId[savedID]?.workingDirectory == record.workingDirectory)
        #expect(workspace.uniConnectLocalWindowsByPanelId[savedID]?.boxRoot == record.boxRoot)
        #expect(restored.surface.debugInitialInputForTesting() == nil)
    }

    @Test
    func sshLaunchClearsCopiedGhosttyCwdWithoutChangingOtherInheritedConfiguration() throws {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.workingDirectory = "/srv/remote-only"
        inherited.fontSize = 17
        inherited.command = "/usr/bin/false"
        inherited.environmentVariables = ["TERM": "xterm-256color"]
        inherited.waitAfterCommand = true

        let sshConfig = try #require(Workspace.terminalConfigForWorkspaceLaunch(
            inherited, suppressInheritedWorkingDirectory: true
        ))
        let localConfig = try #require(Workspace.terminalConfigForWorkspaceLaunch(
            inherited, suppressInheritedWorkingDirectory: false
        ))

        #expect(sshConfig.workingDirectory == nil)
        #expect(sshConfig.fontSize == inherited.fontSize)
        #expect(sshConfig.command == inherited.command)
        #expect(sshConfig.environmentVariables == inherited.environmentVariables)
        #expect(sshConfig.waitAfterCommand == inherited.waitAfterCommand)
        #expect(localConfig.workingDirectory == "/srv/remote-only")
        #expect(inherited.workingDirectory == "/srv/remote-only")
    }

    @Test
    func confirmedSSHSplitKeepsPreparedIdentityAndNeverUsesRemoteCwdLocally() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let source = try #require(workspace.focusedPanelId)
        workspace.uniConnectProfile = .init(kind: .ssh)
        workspace.panelDirectories[source] = "/srv/remote-only"
        workspace.currentDirectory = "/srv/remote-workspace"
        let expectedID = UUID()
        let placement = UniConnectNewWindowPlacement.split(
            sourcePanelID: source, orientation: .horizontal, insertFirst: false
        )
        let panel = try #require(placement.createPanel(
            in: workspace, panelID: expectedID, focus: false,
            initialCommand: "/usr/bin/false", tmuxStartCommand: "/usr/bin/false",
            suppressWorkspaceRemoteStartupCommand: true
        ))

        #expect(panel.id == expectedID)
        #expect(panel.requestedWorkingDirectory == nil)
        #expect(panel.surface.debugInitialCommand() == "/usr/bin/false")
        #expect(panel.surface.debugTmuxStartCommand() == "/usr/bin/false")
        #expect(panel.surface.debugInitialInputForTesting() == nil)
    }

    @Test
    func confirmedLocalSplitRetainsChosenDirectoryAndAgentInput() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let source = try #require(workspace.focusedPanelId)
        let expectedID = UUID()
        let panel = try #require(workspace.newTerminalSplit(
            from: source, orientation: .vertical, focus: false,
            workingDirectory: NSTemporaryDirectory(), newPanelID: expectedID,
            initialInput: "codex resume saved-session --yolo\n"
        ))

        #expect(panel.id == expectedID)
        #expect(panel.requestedWorkingDirectory == NSTemporaryDirectory())
        #expect(panel.surface.debugInitialInputForTesting() == "codex resume saved-session --yolo\n")
    }
}
#endif

private func firstWorkspaceDescendant<ViewType: NSView>(
    ofType type: ViewType.Type,
    in root: NSView
) -> ViewType? {
    if let match = root as? ViewType {
        return match
    }

    for subview in root.subviews {
        if let match = firstWorkspaceDescendant(ofType: type, in: subview) {
            return match
        }
    }

    return nil
}

@MainActor
private func waitForWorkspaceSplitView(
    in hostingView: NSView,
    contentView: NSView,
    expectedDividerPosition: Double,
    accuracy: Double,
    timeout: TimeInterval = 2.0,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> NSSplitView {
    let deadline = Date.now.addingTimeInterval(timeout)
    var lastRenderedDividerPosition: Double?

    repeat {
        contentView.layoutSubtreeIfNeeded()

        if let splitView = firstWorkspaceDescendant(ofType: NSSplitView.self, in: hostingView),
           splitView.arrangedSubviews.count == 2 {
            splitView.layoutSubtreeIfNeeded()

            let availableWidth = splitView.bounds.width - splitView.dividerThickness
            if availableWidth > 0 {
                let renderedDividerPosition = splitView.arrangedSubviews[0].frame.width / availableWidth
                lastRenderedDividerPosition = Double(renderedDividerPosition)

                if abs(Double(renderedDividerPosition) - expectedDividerPosition) <= accuracy {
                    return splitView
                }
            }
        }

        _ = RunLoop.current.run(
            mode: .default,
            before: min(Date.now.addingTimeInterval(0.01), deadline)
        )
    } while Date.now < deadline

    let lastRatioDescription = lastRenderedDividerPosition.map { String(describing: $0) } ?? "nil"
    XCTFail(
        "Timed out waiting for rendered uniconnect.json split ratio \(expectedDividerPosition); last ratio: \(lastRatioDescription)",
        file: file,
        line: line
    )
    return try XCTUnwrap(
        firstWorkspaceDescendant(ofType: NSSplitView.self, in: hostingView),
        "Expected rendered Bonsplit NSSplitView",
        file: file,
        line: line
    )
}

@MainActor
final class WorkspaceSplitStartupCommandTests: XCTestCase {
    func testCustomLayoutSplitRatioSurvivesInitialBonsplitViewLayout() throws {
        let workspace = Workspace()
        let expectedDividerPosition = 0.33
        let layout = CmuxLayoutNode.split(CmuxSplitDefinition(
            direction: .horizontal,
            split: expectedDividerPosition,
            children: [
                .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, name: "Left")
                ])),
                .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, name: "Right")
                ]))
            ]
        ))

        workspace.applyCustomLayout(layout, baseCwd: NSTemporaryDirectory())

        let modelSplitBeforeRender = try XCTUnwrap(workspaceSplitNodes(in: workspace.bonsplitController.treeSnapshot()).first)
        XCTAssertEqual(
            modelSplitBeforeRender.dividerPosition,
            expectedDividerPosition,
            accuracy: 0.000_1,
            "uniconnect.json split ratio should be applied to the Bonsplit model before rendering"
        )

        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: workspace.bonsplitController) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = try XCTUnwrap(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        _ = try waitForWorkspaceSplitView(
            in: hostingView,
            contentView: contentView,
            expectedDividerPosition: expectedDividerPosition,
            accuracy: 0.03
        )

        let modelSplitAfterRender = try XCTUnwrap(workspaceSplitNodes(in: workspace.bonsplitController.treeSnapshot()).first)
        XCTAssertEqual(
            modelSplitAfterRender.dividerPosition,
            expectedDividerPosition,
            accuracy: 0.000_1,
            "Bonsplit initial view layout should not rewrite the uniconnect.json split ratio back to 0.5"
        )
    }

    func testTabManagerSplitCarriesRequestedWorkingDirectoryAndStartupCommand() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused terminal")
            return
        }

        let requestedDirectory = "/tmp/uniconnect-split-startup-\(UUID().uuidString)"
        let startupCommand = "/tmp/uniconnect-tmux-command-\(UUID().uuidString).sh"
        let tmuxStartCommand = "node /opt/oh-my-codex/dist/omx.js hud --watch"
        let initialDividerPosition = 0.875
        guard let splitPanelId = manager.newSplit(
            tabId: workspace.id,
            surfaceId: sourcePanelId,
            direction: .down,
            focus: false,
            workingDirectory: requestedDirectory,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialDividerPosition: initialDividerPosition
        ) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        guard let splitPanel = workspace.terminalPanel(for: splitPanelId) else {
            XCTFail("Expected split terminal panel to resolve")
            return
        }
        XCTAssertEqual(splitPanel.requestedWorkingDirectory, requestedDirectory)
        XCTAssertEqual(
            splitPanel.surface.debugInitialCommand(),
            startupCommand,
            "Programmatic tmux-compatible splits must launch their command as the pane process"
        )
        XCTAssertEqual(
            splitPanel.surface.debugTmuxStartCommand(),
            tmuxStartCommand,
            "Programmatic tmux-compatible splits must preserve the original tmux command for pane format queries"
        )
        guard let split = workspaceSplitNodes(in: workspace.bonsplitController.treeSnapshot()).first else {
            XCTFail("Expected split terminal panel to create a split node")
            return
        }
        XCTAssertEqual(split.orientation, "vertical")
        XCTAssertEqual(
            split.dividerPosition,
            initialDividerPosition,
            accuracy: 0.000_1,
            "Programmatic tmux-compatible splits should enter layout with their requested divider"
        )
    }

    func testNewTerminalSurfaceCarriesRequestedWorkingDirectoryAndStartupCommand() {
        let workspace = Workspace()
        guard let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused pane in new workspace")
            return
        }

        let requestedDirectory = "/tmp/uniconnect-surface-startup-\(UUID().uuidString)"
        let startupCommand = "/tmp/uniconnect-surface-command-\(UUID().uuidString).sh"
        let tmuxStartCommand = "node /opt/oh-my-codex/dist/omx.js hud --watch"
        guard let surface = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: requestedDirectory,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand
        ) else {
            XCTFail("Expected terminal surface to be created")
            return
        }

        XCTAssertEqual(surface.requestedWorkingDirectory, requestedDirectory)
        XCTAssertEqual(surface.surface.debugInitialCommand(), startupCommand)
        XCTAssertEqual(surface.surface.debugTmuxStartCommand(), tmuxStartCommand)
    }

    func testRespawnTerminalSurfacePreservesPaneTabAndSurfaceIdentity() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let placeholderCommand = "/bin/sh -c 'printf placeholder; while :; do sleep 86400; done'"
        let attachCommand = "/bin/sh -c 'opencode attach http://127.0.0.1:4096 --session subagent --dir /tmp/omo'"
        let requestedDirectory = "/tmp/uniconnect-respawn-\(UUID().uuidString)"
        let startupEnvironment = [
            "CMUX_OMO_SUBAGENT": "1",
            "OMO_SUBAGENT_DESC": "test"
        ]

        let placeholderPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: true,
            initialCommand: placeholderCommand,
            tmuxStartCommand: placeholderCommand,
            startupEnvironment: startupEnvironment
        ))
        let originalPanelId = placeholderPanel.id
        let originalPane = try XCTUnwrap(workspace.paneId(forPanelId: originalPanelId))
        let originalPaneId = originalPane.id
        let originalTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(originalPanelId))
        let originalPaneCount = workspace.bonsplitController.allPaneIds.count
        let originalTabCount = workspace.bonsplitController.tabs(inPane: originalPane).count
        let originalWaitAfterCommand = placeholderPanel.surface.debugWaitAfterCommand()

        let respawnedPanel = try XCTUnwrap(workspace.respawnTerminalSurface(
            panelId: originalPanelId,
            command: attachCommand,
            workingDirectory: requestedDirectory,
            tmuxStartCommand: attachCommand
        ))

        XCTAssertEqual(respawnedPanel.id, originalPanelId)
        XCTAssertTrue(workspace.terminalPanel(for: originalPanelId) === respawnedPanel)
        let currentPane = try XCTUnwrap(workspace.paneId(forPanelId: originalPanelId))
        XCTAssertEqual(currentPane.id, originalPaneId)
        XCTAssertEqual(workspace.surfaceIdFromPanelId(originalPanelId), originalTabId)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, originalPaneCount)
        XCTAssertTrue(workspace.bonsplitController.allPaneIds.contains(where: { $0.id == originalPaneId }))
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: currentPane).count, originalTabCount)
        XCTAssertTrue(workspace.bonsplitController.tabs(inPane: currentPane).contains(where: { $0.id == originalTabId }))
        XCTAssertEqual(respawnedPanel.requestedWorkingDirectory, requestedDirectory)
        XCTAssertEqual(respawnedPanel.surface.debugInitialCommand(), attachCommand)
        XCTAssertEqual(respawnedPanel.surface.debugTmuxStartCommand(), attachCommand)
        XCTAssertEqual(respawnedPanel.surface.debugWaitAfterCommand(), originalWaitAfterCommand)
        for (key, value) in startupEnvironment {
            XCTAssertEqual(respawnedPanel.surface.startupEnvironmentValue(key), value)
        }
        XCTAssertTrue(
            TerminalSurfaceRegistry.shared.surface(id: originalPanelId) === respawnedPanel.surface,
            "Respawn should replace the registered terminal surface for the existing cmux surface id"
        )
    }

    func testSessionRestoreRelaunchesOMXHudTmuxStartCommand() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let requestedDirectory = "/tmp/uniconnect-hud-restore-\(UUID().uuidString)"
        let originalStartupScript = "/tmp/uniconnect-tmux-command-\(UUID().uuidString).sh"
        let tmuxStartCommand = "env OMX_SESSION_ID=omx-test node '/opt/oh-my-codex/dist/cli/omx.js' hud --watch"
        let hudPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .vertical,
            insertFirst: false,
            focus: false,
            workingDirectory: requestedDirectory,
            initialCommand: originalStartupScript,
            tmuxStartCommand: tmuxStartCommand,
            initialDividerPosition: 0.82
        ))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let hudSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == hudPanel.id })
        XCTAssertEqual(hudSnapshot.terminal?.tmuxStartCommand, tmuxStartCommand)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredHudPanel = try XCTUnwrap(
            restored.panels.values
                .compactMap { $0 as? TerminalPanel }
                .first { $0.surface.debugTmuxStartCommand() == tmuxStartCommand }
        )
        let restoredStartupScript = try XCTUnwrap(restoredHudPanel.surface.debugInitialCommand())
        XCTAssertNotEqual(
            restoredStartupScript,
            originalStartupScript,
            "Restored HUD panes must launch through a fresh script, not a deleted tmux temp script"
        )
        XCTAssertTrue(restoredStartupScript.contains("cmux-session-terminal-command"))
        XCTAssertEqual(restoredHudPanel.requestedWorkingDirectory, requestedDirectory)
    }

    func testSessionSnapshotDoesNotPersistGenericTmuxStartCommand() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let genericCommand = "sleep 600"
        let panel = try XCTUnwrap(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            initialCommand: "/tmp/uniconnect-command-\(UUID().uuidString).sh",
            tmuxStartCommand: genericCommand
        ))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panel.id })
        XCTAssertNil(panelSnapshot.terminal?.tmuxStartCommand)
        XCTAssertNil(Workspace.restorableTmuxStartCommand(genericCommand))
    }
}
