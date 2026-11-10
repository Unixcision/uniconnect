import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Ventanas SSH por el trabajador de Linux, y Actualizar Claude: una vez por instalación, antes de
/// cerrar nada, y si falla no se cierra ninguna de sus ventanas.
@Suite("Coordinador de relanzado: SSH y Actualizar Claude", .serialized)
@MainActor
struct UniConnectRelaunchCoordinatorTests {
    /// Un SSH de mentira: contesta como el trabajador y como `claude` en el destino, y apunta qué se pidió.
    final class FakeSSH: UniConnectProcessRunning, @unchecked Sendable {
        // Llamadas secuenciales dentro de la prueba.
        var calls: [String] = []
        var loggedIn = true
        var updateWorks = true
        var requests: [[String: Any]] = []

        func run(
            executable: String, arguments: [String], environment: [String: String],
            standardInput: Data?, timeout: Duration
        ) async throws -> UniConnectProcessResult {
            let remote = arguments.last ?? ""
            func reply(_ text: String) -> UniConnectProcessResult {
                .init(terminationStatus: 0, standardOutput: Data(text.utf8), standardError: Data(), outputWasTruncated: false)
            }
            guard let outer = RelaunchShellWords(remote)?.tokens, case let .word(inner)? = outer.last,
                  let words = RelaunchShellWords(inner)?.tokens, case let .word(payload)? = words.last,
                  let data = Data(base64Encoded: payload),
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = request["action"] as? String else {
                return reply("nada")
            }
            requests.append(request)
            let pane = request["session"] as? String == "a" ? "%4" : "%8"
            switch action {
            case "inspect":
                calls.append("inspect:" + (request["session"] as? String ?? ""))
                // El trabajador mira el login dentro de inspect (claude auth status).
                guard loggedIn else { return reply(#"UC_RELAUNCH_V1 {"error": "sin_login"}"#) }
                return reply(#"UC_RELAUNCH_V1 {"key": "linux:x|gen:12", "generation": 12, "pane": {"pane": "\#(pane)"}, "pid": 7, "start": "9", "effective_id": "id-\#(pane)", "configuration": "c", "background": 0, "draft": false, "context_tokens": 1000, "message": false, "installation": {"launcher": "/root/.local/bin/claude", "version": "2.1.281", "installed": "2.1.321"}}"#)
            case "update":
                calls.append("claude update")
                return reply(updateWorks
                    ? #"UC_RELAUNCH_V1 {"state": "actualizado", "from": "2.1.281", "to": "2.1.330"}"#
                    : #"UC_RELAUNCH_V1 {"state": "fallida", "from": "2.1.281", "to": "2.1.281"}"#)
            default:
                calls.append(action + ":" + (request["session"] as? String ?? ""))
                return reply(#"UC_RELAUNCH_V1 {"state": "verificado", "effective_id": "id-\#(pane)", "escalation": "exit", "version": "2.1.330"}"#)
            }
        }
    }

    private let credential = UUID()

    private func coordinator(_ ssh: FakeSSH) -> UniConnectRelaunchCoordinator {
        let credential = credential
        let worker = UniConnectRelaunchRemoteWorker(
            processRunner: ssh,
            credentialResolver: { id in
                id == credential ? UniConnectSSHCredentialRecord(
                    connectCommand: "ssh root@15.217.153.205",
                    effectiveTarget: UniConnectSSHEffectiveTarget(user: "root", host: "15.217.153.205", port: 22)
                ) : nil
            },
            scripts: {
                UniConnectRelaunchWorkerScripts(
                    source: RelaunchWorkerSource(catalogModule: "pass", worker: "pass", identityHook: Data("pass".utf8), recoveryScript: nil),
                    catalogProviders: Data(#"{"claude": {"executable": "claude"}}"#.utf8),
                    messages: Data(#"{"version": 1, "motivo_relanzar": "para relanzarte"}"#.utf8)
                )
            },
            ambientEnvironment: { [:] }
        )
        return UniConnectRelaunchCoordinator(
            machineID: "mac",
            remoteSighting: { _ in .agent(provider: "claude") },
            remoteWorker: worker,
            remoteExecutor: UniConnectRelaunchRemoteExecutor(worker: worker, deadline: .seconds(5), pause: {})
        )
    }

    private func notbetting() throws -> Workspace {
        let workspace = Workspace()
        workspace.customTitle = "NOTBETTING"
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .ssh, credentialId: credential, hostLabel: "root@15.217.153.205", tmuxReady: true)
        let first = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.paneId(forPanelId: first))
        let second = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
        workspace.uniConnectTmuxSessionsByPanelId[first] = "a"
        workspace.uniConnectTmuxSessionsByPanelId[second.id] = "b"
        return workspace
    }

    @Test("El plan de una caja SSH viene del trabajador, con la clave del contrato y la versión instalada")
    func sshPlanComesFromTheWorker() async throws {
        let ssh = FakeSSH()
        let preview = await coordinator(ssh).preview(workspaces: [try notbetting()], verb: .agentUpdate,
                                                     options: try RelaunchUpdateOptions(model: "fable[1m]", effort: "medium"))
        #expect(preview.exclusions.isEmpty)
        #expect(Set(preview.targets.map(\.key.text)) == [
            "ssh:root@15.217.153.205:22|tmux:default|pane:%4|gen:12",
            "ssh:root@15.217.153.205:22|tmux:default|pane:%8|gen:12",
        ])
        #expect(preview.targets.allSatisfy { $0.notes.installed == "2.1.321" && $0.notes.version == "2.1.281" })
        let inspect = try #require(ssh.requests.first)
        #expect(inspect["verb"] as? String == "agent.update")
        #expect(inspect["options"] as? [String: String] == ["model": "fable[1m]", "effort": "medium"])
        #expect(inspect["socket"] as? String == "default")
        #expect(preview.needsConfirmation)
    }

    @Test("claude update corre una sola vez por instalación y antes de cerrar nada")
    func updateRunsOncePerInstallationFirst() async throws {
        let ssh = FakeSSH()
        let service = coordinator(ssh)
        let preview = await service.preview(workspaces: [try notbetting()], verb: .agentUpdate)
        ssh.calls.removeAll()

        let operation = await service.run(preview, operationID: UUID())

        #expect(ssh.calls.first == "claude update")
        #expect(ssh.calls.filter { $0 == "claude update" }.count == 1)
        #expect(ssh.calls.filter { $0.hasPrefix("start:") }.count == 2)
        #expect(operation.updates == [.init(host: "ssh:root@15.217.153.205:22", state: .updated, from: "2.1.281", to: "2.1.330")])
        let update = try #require(ssh.requests.first { $0["action"] as? String == "update" })
        #expect(update["launcher"] as? String == "/root/.local/bin/claude")
        let start = try #require(ssh.requests.first { $0["action"] as? String == "start" })
        #expect(start["updated_to"] as? String == "2.1.330")
        #expect(start["options"] as? [String: String] == [:])
        #expect((start["messages"] as? [String: Any])?["motivo_relanzar"] as? String == "para relanzarte")
        #expect(operation.results.allSatisfy { $0.state == .verified && $0.escalation == .exit })
        #expect(operation.state == .finished)
    }

    @Test("Si la actualización falla no se cierra ninguna ventana de esa instalación")
    func failedUpdateClosesNothing() async throws {
        let ssh = FakeSSH()
        ssh.updateWorks = false
        let service = coordinator(ssh)
        let preview = await service.preview(workspaces: [try notbetting()], verb: .agentUpdate)
        ssh.calls.removeAll()

        let operation = await service.run(preview)

        #expect(!ssh.calls.contains { $0.hasPrefix("start:") })
        #expect(operation.updates.first?.state == .failed)
        #expect(operation.results.allSatisfy { $0.state == .skipped && $0.cause == .updateFailed })
    }

    @Test("Sin login en el destino no se cierra nada: sin_login")
    func notLoggedInExcludesTheBox() async throws {
        let ssh = FakeSSH()
        ssh.loggedIn = false
        let preview = await coordinator(ssh).preview(workspaces: [try notbetting()], verb: .agentRelaunch)
        #expect(preview.targets.isEmpty)
        #expect(preview.exclusions.count == 2)
        #expect(preview.exclusions.allSatisfy { $0.cause == .notLoggedIn })
        #expect(!ssh.calls.contains { $0.hasPrefix("start:") })
    }
}
