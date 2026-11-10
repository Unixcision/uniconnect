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
        sessions: [String],
        credentialID: UUID? = UUID()
    ) throws -> Workspace {
        let workspace = Workspace()
        workspace.customTitle = title
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: credentialID,
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

    @Test("Una caja SSH sin credencial sale con una exclusión por ventana, no desaparece")
    func remoteBoxIsExcludedPerWindow() throws {
        let workspace = try sshWorkspace(
            title: "VALENCIARUSA",
            host: "root@185.237.234.231",
            sessions: ["valenciarusa"],
            credentialID: nil
        )

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        #expect(reading.remote.isEmpty)
        #expect(reading.exclusions.count == 1)
        let exclusion = try #require(reading.exclusions.first)
        #expect(exclusion.cause == .noCredential)
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

        // Sin ninguna lectura de la sonda no se sabe qué IA hay: no se le pregunta a ciegas.
        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        #expect(reading.exclusions.count == 3)
        #expect(reading.exclusions.allSatisfy { $0.cause == .ambiguousIdentity })
        #expect(Set(reading.exclusions.map(\.label)).count == 3)
    }

    @Test("Una ventana SSH con Claude visto por la sonda va al trabajador de su caja")
    func remoteClaudeWindowBecomesACandidate() throws {
        let workspace = try sshWorkspace(title: "NOTBETTING", host: "root@15.217.153.205", sessions: ["uc-prueba-relanzar"])
        let panelID = try #require(workspace.focusedPanelId)
        let reading = UniConnectRelaunchInventory(machineID: "mac", remoteSighting: { _ in .agent(provider: "claude") })
            .read(workspaces: [workspace], verb: .agentUpdate)

        #expect(reading.exclusions.isEmpty)
        let candidate = try #require(reading.remote.first)
        #expect(candidate.panelID == panelID)
        #expect(candidate.session == "uc-prueba-relanzar")
        #expect(candidate.socket == "default")
        #expect(candidate.provider == "claude")
        #expect(candidate.credentialID == workspace.uniConnectProfile?.credentialId)
    }

    @Test("En SSH, una ventana en su shell es sin_ia y Antigravity aún no se relanza desde el Mac")
    func remoteShellAndCodexAreExcluded() throws {
        let workspace = try sshWorkspace(title: "NOTBETTING", host: "root@15.217.153.205", sessions: ["a", "b"])
        let ids = workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }
        let reading = UniConnectRelaunchInventory(machineID: "mac", remoteSighting: { id in
            id == ids[0] ? .shell : .agent(provider: "agy")
        }).read(workspaces: [workspace])

        #expect(reading.remote.isEmpty)
        #expect(Set(reading.exclusions.map(\.cause)) == [.noAgent, .providerUnsupported])
    }

    @Test("Una ventana remota sin sesión tmux registrada tampoco desaparece")
    func remoteWindowWithoutRecordedSessionIsExcluded() throws {
        let workspace = Workspace()
        workspace.customTitle = "COMECAMPUS"
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(
            kind: .ssh,
            hostLabel: "root@187.77.175.242",
            tmuxReady: false
        )
        // Ni una sola entrada en el mapa de sesiones: la ventana existe, su tmux aún no consta.
        #expect(workspace.uniConnectTmuxSessionsByPanelId.isEmpty)

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        #expect(reading.exclusions.count == 1)
        #expect(reading.exclusions.first?.cause == .noCredential)
    }

    @Test("Dos ventanas remotas con el mismo título se distinguen en la lista")
    func remoteWindowsWithTheSameTitleStayDistinguishable() throws {
        let workspace = try sshWorkspace(
            title: "NOTBETTING",
            host: "root@15.217.153.205",
            sessions: ["claude", "claude"]
        )
        // Dos paneles recién creados comparten `displayTitle` ("Terminal"): la colisión es la
        // norma, no un caso raro.
        #expect(Set(workspace.panels.values.map(\.displayTitle)).count == 1)

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.exclusions.count == 2)
        // Dos líneas idénticas no se distinguen de una línea y una ventana perdida.
        #expect(Set(reading.exclusions.map(\.label)).count == 2)
    }

    @Test("Una ventana local sin registro sale como identidad ambigua, no omitida")
    func localWindowWithoutRecordIsExcluded() throws {
        let workspace = Workspace()
        workspace.customTitle = "PROYECTOS"
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .local, localRoot: "/tmp")
        // Sin ninguna entrada en uniConnectLocalWindowsByPanelId: no sabemos qué corre ahí.
        #expect(workspace.uniConnectLocalWindowsByPanelId.isEmpty)

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        #expect(reading.exclusions.count == 1)
        #expect(reading.exclusions.first?.cause == .ambiguousIdentity)
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
        #expect(reading.exclusions.first?.cause == .noTmux)
        #expect(reading.exclusions.first?.label.contains("sin tmux") == true)
    }

    private func localWorkspace(
        name: String,
        agent kind: RestorableAgentKind,
        sessionID: String,
        backToShell: Bool
    ) throws -> (Workspace, UUID) {
        let workspace = Workspace()
        workspace.customTitle = "PROYECTOS"
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .local, localRoot: "/tmp")
        let panelId = try #require(workspace.focusedPanelId)
        let binding = try #require(UniConnectLocalTmuxBinding(name: "uc-\(name)", socketName: "uniconnect-local"))
        var record = UniConnectLocalWindowRecord(id: panelId, visibleName: name, boxRoot: "/tmp", tmuxBinding: binding)
        _ = record.record(SessionRestorableAgentSnapshot(
            kind: kind, sessionId: sessionID, workingDirectory: "/tmp", launchCommand: nil
        ))
        if backToShell { _ = record.transitionToShell() }
        workspace.uniConnectLocalWindowsByPanelId[panelId] = record
        return (workspace, panelId)
    }

    @Test("Una ventana local en su shell sale como sin_ia, no como identidad ambigua")
    func localShellWindowHasNoAgent() throws {
        let (workspace, _) = try localWorkspace(
            name: "shell", agent: .claude, sessionID: "714b0eae-b568-4e0c-a70b-c87c0d0a801a", backToShell: true
        )

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        #expect(reading.exclusions.count == 1)
        #expect(reading.exclusions.first?.cause == .noAgent)
    }

    @Test("Una ventana local con Codex se enumera, pero no se cierra hasta validar su dialecto")
    func localCodexWindowAwaitsLiveRelaunchValidation() throws {
        let (workspace, _) = try localWorkspace(
            name: "api", agent: .codex, sessionID: "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17", backToShell: false
        )

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        let exclusion = try #require(reading.exclusions.first)
        #expect(exclusion.cause == .providerUnsupported)
        #expect(exclusion.label.contains("Codex"))
    }

    @Test("Una ventana local con Grok sale como proveedor_no_soportado y la lista dice qué IA es")
    func localGrokWindowIsUnsupportedAndNamed() throws {
        let (workspace, _) = try localWorkspace(
            name: "bot", agent: .grok, sessionID: "3f6a9c12-8d4e-4b7a-b5c1-0e2f7d9a6b84", backToShell: false
        )

        let reading = UniConnectRelaunchInventory(machineID: "mac").read(workspaces: [workspace])

        #expect(reading.items.isEmpty)
        let exclusion = try #require(reading.exclusions.first)
        #expect(exclusion.cause == .providerUnsupported)
        #expect(exclusion.label.contains("Grok"))
    }

    @Test("Pedir una sola ventana deja solo su exclusión, por identidad del panel")
    func aSingleWindowKeepsOnlyItsOwnExclusion() throws {
        let workspace = try sshWorkspace(
            title: "NOTBETTING",
            host: "root@15.217.153.205",
            sessions: ["claude", "claude"]
        )
        let wanted = try #require(workspace.focusedPanelId)

        let reading = UniConnectRelaunchInventory(machineID: "mac")
            .read(workspaces: [workspace], onlyPanels: [wanted])

        #expect(reading.items.isEmpty)
        #expect(reading.excluded.count == 1)
        #expect(reading.excluded.first?.panelID == wanted)
        #expect(reading.exclusions.first?.cause == .ambiguousIdentity)
    }
}
