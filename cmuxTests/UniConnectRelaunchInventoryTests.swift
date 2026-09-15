import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Lo que impide que una caja entera desaparezca de la lista sin que nadie lo note.
///
/// Una ventana omitida se lee como una ventana olvidada, y una caja omitida se lee como una caja
/// vacía. El inventario puede negarse a actuar sobre lo que no alcanza; lo que no puede es callarlo.
@Suite("Inventario de relanzado")
@MainActor
struct UniConnectRelaunchInventoryTests {
    private func sshWorkspace(
        title: String,
        host: String,
        sessions: [String]
    ) throws -> Workspace {
        let workspace = Workspace()
        workspace.customTitle = title
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            hostLabel: host,
            tmuxReady: true
        )
        let firstPanelId = try #require(workspace.focusedPanelId)
        var panelIds = [firstPanelId]
        if sessions.count > 1 {
            let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
            for _ in 1..<sessions.count {
                let extra = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
                panelIds.append(extra.id)
            }
        }
        for (panelId, session) in zip(panelIds, sessions) {
            workspace.uniConnectTmuxSessionsByPanelId[panelId] = session
        }
        return workspace
    }

    @Test("Una caja SSH sale con una exclusión por ventana, no desaparece")
    func remoteBoxIsExcludedPerWindow() throws {
        let workspace = try sshWorkspace(
            title: "VALENCIARUSA",
            host: "root@185.237.234.231",
            sessions: ["valenciarusa"]
        )

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        #expect(reading.exclusions.count == 1)
        let exclusion = try #require(reading.exclusions.first)
        #expect(exclusion.cause == .unsupported)
        #expect(exclusion.label.contains("VALENCIARUSA"))
        #expect(exclusion.label.contains("root@185.237.234.231"))
    }

    @Test("Cada ventana de la caja remota se nombra por separado")
    func everyRemoteWindowIsNamed() throws {
        let workspace = try sshWorkspace(
            title: "NOTBETTING",
            host: "root@15.217.153.205",
            sessions: ["claudefixerrors", "claudesupport", "miamigoclaude"]
        )

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        #expect(reading.exclusions.count == 3)
        #expect(reading.exclusions.allSatisfy { $0.cause == .unsupported })
        #expect(Set(reading.exclusions.map(\.label)).count == 3)
    }

    @Test("Una ventana local sin tmux se excluye con motivo en vez de caerse en silencio")
    func localWindowWithoutTmuxIsExcluded() throws {
        let workspace = Workspace()
        workspace.customTitle = "PROYECTOS"
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .local, localRoot: "/tmp")
        let panelId = try #require(workspace.focusedPanelId)
        workspace.uniConnectLocalWindowsByPanelId[panelId] = UniConnectLocalWindowRecord(
            id: UUID(),
            visibleName: "sin tmux",
            boxRoot: "/tmp"
        )

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        #expect(reading.exclusions.count == 1)
        #expect(reading.exclusions.first?.cause == .unsupported)
        #expect(reading.exclusions.first?.label.contains("sin tmux") == true)
    }
}
