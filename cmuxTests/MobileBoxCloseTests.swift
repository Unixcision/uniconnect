import Testing
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `box-close.v1` on the Mac: `workspace.close` and `terminal.close` through the mobile host,
/// with the exact params of `contracts/box-close-v1`.
///
/// `.serialized` because these drive the real `TabManager`/`Workspace`/bonsplit model and the
/// shared `TerminalController`, which must not run concurrently.
@MainActor
@Suite(.serialized)
struct MobileBoxCloseTests {
    /// A manager the mobile host resolves, with `count` workspaces; the first stays selected.
    private func makeManager(workspaces count: Int) -> TabManager {
        let manager = TabManager()
        for _ in 1..<count {
            _ = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        }
        return manager
    }

    private func call(_ method: String, _ params: [String: Any]) async -> MobileHostRPCResult {
        await TerminalController.shared.mobileHostHandleRPC(.init(
            id: UUID().uuidString, method: method, params: params, auth: nil
        ))
    }

    private func withActive<T>(_ manager: TabManager, _ body: () async throws -> T) async rethrows -> T {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        return try await body()
    }

    private func payload(_ result: MobileHostRPCResult) -> [String: Any]? {
        guard case let .ok(raw) = result else { return nil }
        return raw as? [String: Any]
    }

    private func errorCode(_ result: MobileHostRPCResult) -> (code: String, message: String)? {
        guard case let .failure(error) = result else { return nil }
        return (error.code, error.message)
    }

    private func workspaceIDs(_ payload: [String: Any]) -> [String] {
        (payload["workspaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    private func terminalIDs(_ payload: [String: Any], workspace: UUID) -> [String]? {
        let boxes = payload["workspaces"] as? [[String: Any]] ?? []
        guard let box = boxes.first(where: { ($0["id"] as? String) == workspace.uuidString }),
              let terminals = box["terminals"] as? [[String: Any]] else { return nil }
        return terminals.compactMap { $0["id"] as? String }
    }

    @Test("workspace.list announces box_close next to box_update")
    func listAdvertisesBoxClose() async throws {
        let manager = makeManager(workspaces: 1)
        let result = await withActive(manager) { await call("workspace.list", [:]) }
        let capabilities = try #require(payload(result)?["capabilities"] as? [String])
        #expect(capabilities.contains("box_close"))
        #expect(capabilities.contains("box_update"))
    }

    @Test("terminal.close closes that window like the desktop and answers the whole list")
    func terminalCloseClosesOnlyThatWindow() async throws {
        let manager = makeManager(workspaces: 2)
        let workspace = try #require(manager.selectedWorkspace)
        let other = try #require(manager.tabs.first { $0.id != workspace.id })
        let kept = try #require(workspace.focusedPanelId)
        let closing = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        #expect(workspace.focusedPanelId == kept)

        let result = await withActive(manager) {
            await call("terminal.close", [
                "workspace_id": workspace.id.uuidString, "terminal_id": closing.id.uuidString,
            ])
        }

        let answer = try #require(payload(result))
        #expect(answer["closed_terminal_id"] as? String == closing.id.uuidString)
        #expect(answer["closed_workspace_id"] == nil)
        // The whole list: this manager's workspaces (and those of the host app's own window).
        #expect(Set(workspaceIDs(answer)).isSuperset(of: [workspace.id.uuidString, other.id.uuidString]))
        #expect(terminalIDs(answer, workspace: workspace.id) == [kept.uuidString])
        #expect((answer["capabilities"] as? [String])?.contains("box_close") == true)
        #expect(workspace.panels[closing.id] == nil)
        #expect(workspace.panels[kept] != nil)
        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTabId == workspace.id)
        #expect(workspace.focusedPanelId == kept)
    }

    @Test("workspace.close closes the workspace and its windows without touching the selected one")
    func workspaceCloseClosesTheWorkspace() async throws {
        let manager = makeManager(workspaces: 3)
        let selected = try #require(manager.selectedWorkspace)
        let closing = try #require(manager.tabs.last)
        #expect(closing.id != selected.id)
        _ = try #require(closing.newTerminalSurfaceInFocusedPane(focus: false))
        // The desktop asks before closing a pinned workspace; the phone already asked.
        manager.setPinned(closing, pinned: true)
        #expect(closing.isPinned)

        let result = await withActive(manager) {
            await call("workspace.close", ["workspace_id": closing.id.uuidString])
        }

        let answer = try #require(payload(result))
        #expect(answer["closed_workspace_id"] as? String == closing.id.uuidString)
        #expect(!workspaceIDs(answer).contains(closing.id.uuidString))
        #expect(Set(workspaceIDs(answer)).isSuperset(of: manager.tabs.map(\.id.uuidString)))
        #expect(!manager.tabs.contains { $0.id == closing.id })
        #expect(closing.panels.isEmpty)
        #expect(manager.selectedTabId == selected.id)
    }

    @Test("Closing the last panel of a workspace closes the workspace, as the desktop does")
    func lastPanelClosesItsWorkspace() async throws {
        let manager = makeManager(workspaces: 2)
        let closing = try #require(manager.tabs.last)
        let only = try #require(closing.panels.keys.first)
        #expect(closing.panels.count == 1)

        let result = await withActive(manager) {
            await call("terminal.close", [
                "workspace_id": closing.id.uuidString, "terminal_id": only.uuidString,
            ])
        }

        let answer = try #require(payload(result))
        #expect(answer["closed_terminal_id"] as? String == only.uuidString)
        #expect(answer["closed_workspace_id"] as? String == closing.id.uuidString)
        #expect(!manager.tabs.contains { $0.id == closing.id })
        #expect(!workspaceIDs(answer).contains(closing.id.uuidString))
    }

    @Test("A pinned window is not closed, as on the desktop, and says why in Spanish")
    func pinnedWindowIsRefused() async throws {
        let manager = makeManager(workspaces: 1)
        let workspace = try #require(manager.selectedWorkspace)
        let pinned = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        workspace.setPanelPinned(panelId: pinned.id, pinned: true)

        let result = await withActive(manager) {
            await call("terminal.close", [
                "workspace_id": workspace.id.uuidString, "terminal_id": pinned.id.uuidString,
            ])
        }

        let error = try #require(errorCode(result))
        #expect(error.code == "close_failed")
        #expect(error.message.contains("fijada"))
        #expect(workspace.panels[pinned.id] != nil)
    }

    @Test("The last workspace of the app is not closed: it would quit UniConnect")
    func lastWorkspaceOfTheAppIsRefused() async throws {
        let manager = makeManager(workspaces: 1)
        let workspace = try #require(manager.selectedWorkspace)
        let panels = Set(workspace.panels.keys)

        let result = await withActive(manager) {
            await call("workspace.close", ["workspace_id": workspace.id.uuidString])
        }

        #expect(errorCode(result)?.code == "close_failed")
        #expect(manager.tabs.map(\.id) == [workspace.id])
        #expect(Set(workspace.panels.keys) == panels)
    }

    @Test("Unknown ids answer not_found and malformed ones invalid_params, changing nothing")
    func errorsChangeNothing() async throws {
        let manager = makeManager(workspaces: 2)
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedPanelId)
        let before = Set(workspace.panels.keys)
        let cases: [(String, [String: Any], String)] = [
            ("workspace.close", ["workspace_id": UUID().uuidString], "not_found"),
            ("terminal.close", ["workspace_id": workspace.id.uuidString, "terminal_id": UUID().uuidString], "not_found"),
            ("terminal.close", ["workspace_id": UUID().uuidString, "terminal_id": panel.uuidString], "not_found"),
            ("workspace.close", [:], "invalid_params"),
            ("workspace.close", ["workspace_id": "no-es-un-id"], "invalid_params"),
            ("terminal.close", ["workspace_id": workspace.id.uuidString], "invalid_params"),
            ("terminal.close", ["workspace_id": workspace.id.uuidString, "terminal_id": "x"], "invalid_params"),
            ("terminal.close", ["terminal_id": panel.uuidString], "invalid_params"),
        ]
        for (method, params, expected) in cases {
            let result = await withActive(manager) { await call(method, params) }
            let error = try #require(errorCode(result), "\(method) \(params) must fail")
            #expect(error.code == expected, "\(method) \(params)")
            #expect(!error.message.isEmpty)
        }
        #expect(manager.tabs.count == 2)
        #expect(Set(workspace.panels.keys) == before)
    }
}
