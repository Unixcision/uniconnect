import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Semántica pura de favoritos y orden (contrato `box_update`): favorito primero, posición
/// base cero dentro de su grupo recortada al rango, fijados primero y estable para el resto.
@Suite("Favoritos y orden: planificador")
struct MobileBoxArrangementPlanTests {
    private let a = "a", b = "b", c = "c", d = "d"

    @Test("La proyección pone los fijados primero sin alterar el orden relativo")
    func pinnedFirstIsStable() {
        #expect(MobileBoxArrangement<String>.pinnedFirst([a, b, c, d], pinnedIDs: [c]) == [c, a, b, d])
        #expect(MobileBoxArrangement<String>.pinnedFirst([a, b, c, d], pinnedIDs: [d, b]) == [b, d, a, c])
        #expect(MobileBoxArrangement<String>.pinnedFirst([a, b], pinnedIDs: []) == [a, b])
    }

    @Test("Fijar sin posición lleva el elemento al final de los fijados")
    func pinWithoutPosition() throws {
        let plan = try #require(MobileBoxArrangement<String>.plan(
            orderedIDs: [a, b, c], pinnedIDs: [a], target: c, isPinned: true, position: nil
        ))
        #expect(plan.orderedIDs == [a, c, b])
        #expect(plan.pinnedIDs == [a, c])
    }

    @Test("La posición es base cero dentro del grupo y se recorta al rango")
    func positionWithinGroup() throws {
        let ordered = ["p1", "p2", "u1", "u2", "u3"]
        let pinned: Set<String> = ["p1", "p2"]
        let first = try #require(MobileBoxArrangement<String>.plan(
            orderedIDs: ordered, pinnedIDs: pinned, target: "u3", isPinned: nil, position: 0
        ))
        #expect(first.orderedIDs == ["p1", "p2", "u3", "u1", "u2"])
        let clampedHigh = try #require(MobileBoxArrangement<String>.plan(
            orderedIDs: ordered, pinnedIDs: pinned, target: "u1", isPinned: nil, position: 99
        ))
        #expect(clampedHigh.orderedIDs == ["p1", "p2", "u2", "u3", "u1"])
        let clampedLow = try #require(MobileBoxArrangement<String>.plan(
            orderedIDs: ordered, pinnedIDs: pinned, target: "u2", isPinned: nil, position: -5
        ))
        #expect(clampedLow.orderedIDs == ["p1", "p2", "u2", "u1", "u3"])
        let pinnedMove = try #require(MobileBoxArrangement<String>.plan(
            orderedIDs: ordered, pinnedIDs: pinned, target: "p2", isPinned: nil, position: 0
        ))
        #expect(pinnedMove.orderedIDs == ["p2", "p1", "u1", "u2", "u3"])
        #expect(pinnedMove.index(of: "p2") == 0)
    }

    @Test("Quitar el favorito deja el elemento delante de los no fijados")
    func unpinKeepsPlace() throws {
        let plan = try #require(MobileBoxArrangement<String>.plan(
            orderedIDs: ["p1", "p2", "u1"], pinnedIDs: ["p1", "p2"], target: "p1", isPinned: false, position: nil
        ))
        #expect(plan.orderedIDs == ["p2", "p1", "u1"])
        #expect(plan.pinnedIDs == ["p2"])
    }

    @Test("Favorito y posición en la misma llamada: primero el favorito")
    func pinAndPositionTogether() throws {
        let plan = try #require(MobileBoxArrangement<String>.plan(
            orderedIDs: [a, b, c, d], pinnedIDs: [a], target: d, isPinned: true, position: 0
        ))
        #expect(plan.orderedIDs == [d, a, b, c])
        let unpinAndMove = try #require(MobileBoxArrangement<String>.plan(
            orderedIDs: [a, b, c, d], pinnedIDs: [a, b], target: a, isPinned: false, position: 1
        ))
        #expect(unpinAndMove.orderedIDs == [b, c, a, d])
    }

    @Test("Un objetivo desconocido no produce plan y los fijados ajenos se ignoran")
    func unknownTarget() {
        #expect(MobileBoxArrangement<String>.plan(orderedIDs: [a, b], pinnedIDs: [], target: c, isPinned: true, position: 0) == nil)
        let plan = MobileBoxArrangement<String>.plan(orderedIDs: [a, b], pinnedIDs: ["zombie"], target: a, isPinned: nil, position: 1)
        #expect(plan?.pinnedIDs == [])
        #expect(plan?.orderedIDs == [b, a])
    }
}

/// Los dos RPC del contrato sobre el modelo real (`TabManager`, `Workspace`, bonsplit) y el
/// snapshot `mobile.workspace.list`. `.serialized` porque tocan registros de superficies globales.
@MainActor
@Suite("Favoritos y orden: RPC móvil", .serialized)
struct MobileBoxUpdateRPCTests {
    private func call(_ method: String, _ params: [String: Any]) async -> MobileHostRPCResult {
        await TerminalController.shared.mobileHostHandleRPC(.init(
            id: UUID().uuidString, method: method, params: params, auth: nil
        ))
    }

    private func workspaces(_ response: MobileHostRPCResult) -> [[String: Any]]? {
        guard case let .ok(raw) = response, let payload = raw as? [String: Any] else { return nil }
        return payload["workspaces"] as? [[String: Any]]
    }

    private func terminalIDs(_ box: [String: Any]) -> [String] {
        (box["terminals"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    private func errorCode(_ response: MobileHostRPCResult) -> String? {
        guard case let .failure(error) = response else { return nil }
        return error.code
    }

    private func teardown(_ workspace: Workspace, except keep: Set<UUID>) {
        for id in Set(workspace.panels.keys).subtracting(keep) {
            workspace.terminalPanel(for: id)?.surface.teardownSurface()
        }
    }

    @Test("El snapshot anuncia box_update y lleva is_pinned en cada terminal")
    func snapshotAdvertisesCapability() async throws {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        let response = await call("mobile.workspace.list", [:])
        guard case let .ok(raw) = response, let payload = raw as? [String: Any] else {
            Issue.record("Se esperaba el snapshot")
            return
        }
        let capabilities = payload["capabilities"] as? [String] ?? []
        #expect(capabilities.contains("box_update"))
        #expect(capabilities.contains("activity.v1"))
        let box = try #require(workspaces(response)?.first)
        let terminal = try #require((box["terminals"] as? [[String: Any]])?.first)
        #expect(terminal["is_pinned"] as? Bool == false)
    }

    @Test("Fijar una ventana la pone primera sin cambiar foco ni selección; la posición va por grupo")
    func terminalPinAndPosition() async throws {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        let workspace = try #require(manager.selectedWorkspace)
        let original = Set(workspace.panels.keys)
        defer { teardown(workspace, except: original) }
        let t1 = try #require(workspace.focusedPanelId)
        let t2 = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false)).id
        let t3 = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false)).id
        let paneId = try #require(workspace.paneId(forPanelId: t1))
        let selectedBefore = workspace.bonsplitController.selectedTab(inPane: paneId)?.id
        let focusedBefore = workspace.focusedPanelId
        let ws = workspace.id.uuidString

        let pinned = await call("mobile.terminal.update", ["workspace_id": ws, "terminal_id": t3.uuidString, "is_pinned": true])
        let pinnedBox = try #require(workspaces(pinned)?.first)
        #expect(terminalIDs(pinnedBox) == [t3, t1, t2].map(\.uuidString))
        let pinnedTerminal = try #require((pinnedBox["terminals"] as? [[String: Any]])?.first)
        #expect(pinnedTerminal["is_pinned"] as? Bool == true)
        #expect(workspace.isPanelPinned(t3))
        #expect(workspace.focusedPanelId == focusedBefore)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id == selectedBefore)

        let moved = await call("mobile.terminal.update", ["workspace_id": ws, "terminal_id": t2.uuidString, "position": 0])
        let movedBox = try #require(workspaces(moved)?.first)
        #expect(terminalIDs(movedBox) == [t3, t2, t1].map(\.uuidString))
        #expect(workspace.focusedPanelId == focusedBefore)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id == selectedBefore)

        let clamped = await call("mobile.terminal.update", ["workspace_id": ws, "terminal_id": t2.uuidString, "position": 40])
        #expect(terminalIDs(try #require(workspaces(clamped)?.first)) == [t3, t1, t2].map(\.uuidString))

        let unpinned = await call("mobile.terminal.update", ["workspace_id": ws, "terminal_id": t3.uuidString, "is_pinned": false])
        let unpinnedBox = try #require(workspaces(unpinned)?.first)
        #expect(terminalIDs(unpinnedBox) == [t3, t1, t2].map(\.uuidString))
        #expect(!workspace.isPanelPinned(t3))
        #expect(workspace.paneId(forPanelId: t3) == paneId)
    }

    @Test("Identificadores ausentes o desconocidos y cambios vacíos son invalid_params")
    func invalidParameters() async throws {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        let workspace = try #require(manager.selectedWorkspace)
        let ws = workspace.id.uuidString
        let terminal = try #require(workspace.focusedPanelId).uuidString

        #expect(errorCode(await call("mobile.workspace.update", ["is_pinned": true])) == "invalid_params")
        #expect(errorCode(await call("mobile.workspace.update", ["workspace_id": UUID().uuidString, "is_pinned": true])) == "invalid_params")
        #expect(errorCode(await call("mobile.workspace.update", ["workspace_id": ws])) == "invalid_params")
        #expect(errorCode(await call("mobile.workspace.update", ["workspace_id": ws, "is_pinned": "sí"])) == "invalid_params")
        #expect(errorCode(await call("mobile.workspace.update", ["workspace_id": ws, "position": "uno"])) == "invalid_params")
        #expect(errorCode(await call("mobile.terminal.update", ["workspace_id": ws, "is_pinned": true])) == "invalid_params")
        #expect(errorCode(await call("mobile.terminal.update", ["workspace_id": ws, "terminal_id": UUID().uuidString, "is_pinned": true])) == "invalid_params")
        #expect(errorCode(await call("mobile.terminal.update", ["workspace_id": ws, "terminal_id": terminal])) == "invalid_params")
        #expect(!workspace.isPanelPinned(try #require(workspace.focusedPanelId)))
    }

    @Test("Fijar y recolocar espacios sigue el orden fijados primero de la barra lateral")
    func workspacePinAndPosition() async throws {
        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previous) }
        let first = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        defer {
            for workspace in [second, third] { teardown(workspace, except: []) }
        }
        manager.selectWorkspace(first)
        let selectedBefore = manager.selectedTabId

        let pinned = await call("mobile.workspace.update", ["workspace_id": third.id.uuidString, "is_pinned": true])
        let pinnedBoxes = try #require(workspaces(pinned))
        #expect(pinnedBoxes.map { $0["id"] as? String } == [third, first, second].map(\.id.uuidString))
        #expect(pinnedBoxes.first?["is_pinned"] as? Bool == true)
        #expect(manager.selectedTabId == selectedBefore)

        let moved = await call("mobile.workspace.update", ["workspace_id": second.id.uuidString, "position": 0])
        #expect(try #require(workspaces(moved)).map { $0["id"] as? String } == [third, second, first].map(\.id.uuidString))
        #expect(manager.selectedTabId == selectedBefore)

        let unpinned = await call("mobile.workspace.update", ["workspace_id": third.id.uuidString, "is_pinned": false])
        #expect(try #require(workspaces(unpinned)).map { $0["id"] as? String } == [third, second, first].map(\.id.uuidString))
        #expect(!third.isPinned)
    }
}
