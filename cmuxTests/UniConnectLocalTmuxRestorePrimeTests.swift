import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Restores isolated desktop models without starting their prepared terminal commands.
@MainActor
@Suite("Restore every durable local tmux window", .serialized)
struct UniConnectLocalTmuxRestorePrimeTests {
    @Test("Selected and background local boxes enqueue every saved terminal without changing selection")
    func restorationQueuesSelectedAndHiddenLocalTerminals() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedSnapshot = try snapshot(kind: .local, root: root)
        let backgroundSnapshot = try snapshot(kind: .local, root: root)
        let sshSnapshot = try snapshot(kind: .ssh, root: root)
        let genericSnapshot = try snapshot(kind: nil, root: root)
        let manager = TabManager(initialWorkspaceTitle: "Prueba", autoWelcomeIfNeeded: false)
        defer { tearDown(manager) }

        manager.restoreSessionSnapshot(.init(
            selectedWorkspaceIndex: 0,
            workspaces: [selectedSnapshot, backgroundSnapshot, sshSnapshot, genericSnapshot]
        ))

        let selectedID = try #require(selectedSnapshot.workspaceId)
        let backgroundID = try #require(backgroundSnapshot.workspaceId)
        #expect(manager.selectedTabId == selectedID)
        #expect(manager.pendingBackgroundWorkspaceLoadIds == [selectedID, backgroundID])
        for saved in [selectedSnapshot, backgroundSnapshot] {
            let workspace = try #require(manager.tabs.first { $0.id == saved.workspaceId })
            #expect(workspace.focusedPanelId == saved.focusedPanelId)
            #expect(workspace.backgroundPrimeTerminalPanelIDs == saved.panels.map(\.id))
            #expect(workspace.hasDurableLocalTmuxSurfaceStartWork())
            for savedPanel in saved.panels {
                let panel = try #require(workspace.terminalPanel(for: savedPanel.id))
                let record = try #require(workspace.uniConnectLocalWindowsByPanelId[panel.id])
                let savedRecord = try #require(savedPanel.terminal?.uniConnectLocalWindow)
                #expect(record.id == savedRecord.id)
                #expect(record.tmuxBinding == savedRecord.tmuxBinding)
                #expect(record.latestConversation?.sessionID == savedRecord.latestConversation?.sessionID)
                #expect(record.runtimeState == .shell)
                #expect(panel.surface.surface == nil)
                #expect(panel.surface.initialCommand == UniConnectLocalTmuxLaunchPlan(
                    binding: try #require(record.tmuxBinding),
                    workingDirectory: record.workingDirectory,
                    initialCommand: nil
                ).startupCommand())
            }
        }
        for saved in [sshSnapshot, genericSnapshot] {
            let workspace = try #require(manager.tabs.first { $0.id == saved.workspaceId })
            #expect(!workspace.hasDurableLocalTmuxSurfaceStartWork())
            #expect(!manager.pendingBackgroundWorkspaceLoadIds.contains(workspace.id))
            #expect(workspace.backgroundPrimeTerminalPanelIDs == [try #require(saved.focusedPanelId)])
        }
    }

    @Test("Closing a queued local window removes it from startup candidates")
    func closedWindowsCannotKeepRestoreQueued() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try snapshot(kind: .local, root: root)
        let manager = TabManager(initialWorkspaceTitle: "Prueba", autoWelcomeIfNeeded: false)
        defer { tearDown(manager) }
        manager.restoreSessionSnapshot(.init(selectedWorkspaceIndex: 0, workspaces: [saved]))
        let workspace = try #require(manager.selectedWorkspace)
        for panel in workspace.panels.values.compactMap({ $0 as? TerminalPanel }) {
            panel.surface.beginPortalCloseLifecycle(reason: "restore-prime-test")
        }
        #expect(workspace.backgroundPrimeTerminalPanelIDs.isEmpty)
        #expect(!workspace.hasDurableLocalTmuxSurfaceStartWork())
        #expect(!workspace.hasBackgroundPrimeTerminalSurfaceStartWork())
        #expect(workspace.hasLoadedBackgroundPrimeTerminalSurface())
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectRestorePrime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func snapshot(kind: UniConnectWorkspaceKind?, root: URL) throws -> SessionWorkspaceSnapshot {
        let panels = try (0..<2).map { index -> SessionPanelSnapshot in
            let panelID = UUID()
            let binding = UniConnectLocalTmuxBinding.newWindow(
                panelID: panelID, bundleIdentifier: "com.unixcision.uniconnect.debug.restore-prime-test"
            )
            var record = UniConnectLocalWindowRecord(id: panelID, boxRoot: root.path, tmuxBinding: binding)
            _ = record.record(.init(kind: .codex, sessionId: UUID().uuidString, workingDirectory: record.workingDirectory))
            _ = record.transitionToShell()
            return SessionPanelSnapshot(
                id: panelID, type: .terminal, title: "Terminal \(index + 1)", customTitle: nil,
                directory: record.workingDirectory, isPinned: false, isManuallyUnread: false,
                gitBranch: nil, listeningPorts: [], ttyName: nil,
                terminal: .init(
                    workingDirectory: record.workingDirectory,
                    wasAgentRunning: false,
                    uniConnectTmuxSession: kind == .ssh ? "saved-\(index)" : nil,
                    uniConnectLocalWindow: record
                ),
                browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil, project: nil
            )
        }
        let selectedPanelID = try #require(panels.first?.id)
        return SessionWorkspaceSnapshot(
            workspaceId: UUID(), processTitle: "Caja", customTitle: nil,
            customDescription: nil, customColor: nil, isPinned: false,
            terminalScrollBarHidden: nil, currentDirectory: root.path,
            focusedPanelId: selectedPanelID,
            layout: .pane(.init(panelIds: panels.map(\.id), selectedPanelId: selectedPanelID)),
            panels: panels, statusEntries: [], logEntries: [], progress: nil, gitBranch: nil, remote: nil,
            uniConnect: kind.map { .init(kind: $0, localRoot: $0 == .local ? root.path : nil) }
        )
    }

    private func tearDown(_ manager: TabManager) {
        for workspace in manager.tabs {
            for panel in workspace.panels.values.compactMap({ $0 as? TerminalPanel }) {
                panel.surface.teardownSurface()
            }
        }
    }
}
