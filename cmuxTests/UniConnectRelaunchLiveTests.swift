import CMUXAgentLaunch
import Foundation
import Testing
import UniConnectClaudeUpdate

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Prueba en vivo, contra una IA de verdad y desechable. Nunca corre sola: hace falta
/// `TEST_RUNNER_UC_LIVE=ssh` o `=local` (y el resto de `UC_LIVE_*`) en la llamada a xcodebuild.
///
/// - `ssh`: la sesión `UC_LIVE_SESSION` (por defecto `uc-prueba-relanzar`) del destino de
///   `UC_LIVE_SSH` (orden `ssh …` completa), y solo esa: la caja tiene una única ventana.
/// - `local`: la sesión `UC_LIVE_SESSION` del socket privado `UC_LIVE_SOCKET` de este Mac.
///
/// `UC_LIVE_FILES` es una copia, fuera del Escritorio, de `linux/` y del catálogo: el anfitrión
/// de las pruebas es la app, y abrir un fichero del Escritorio le pide permiso a la persona.
/// `UC_LIVE_VERB` (`agent.relaunch` o `agent.update`), `UC_LIVE_MODEL`, `UC_LIVE_EFFORT`, y
/// `UC_LIVE_OUT`: fichero donde se escribe el plan y el resultado en JSON.
@Suite("Relanzado en vivo", .serialized, .enabled(if: ProcessInfo.processInfo.environment["UC_LIVE"] != nil))
@MainActor
struct UniConnectRelaunchLiveTests {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    /// A copy of the repository's worker files outside the Desktop: the test host is the app, and
    /// opening a file under `~/Desktop` makes macOS ask the person for permission.
    private var repository: URL {
        URL(fileURLWithPath: environment["UC_LIVE_FILES"] ?? "/nonexistent", isDirectory: true)
    }

    private func scripts() throws -> UniConnectRelaunchWorkerScripts {
        func file(_ path: String) throws -> Data { try Data(contentsOf: repository.appendingPathComponent(path)) }
        let catalog = try file("Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json")
        let providers = try #require((try JSONSerialization.jsonObject(with: catalog) as? [String: Any])?["providers"])
        return UniConnectRelaunchWorkerScripts(
            source: RelaunchWorkerSource(
                catalogModule: String(decoding: try file("linux/uniconnect/resume_catalog.py"), as: UTF8.self),
                worker: String(decoding: try file("linux/uniconnect/relaunch_worker.py"), as: UTF8.self),
                identityHook: try file("linux/uniconnect/agent_identity_hook.py"),
                recoveryScript: try? file("linux/scripts/recovery.py")
            ),
            catalogProviders: try JSONSerialization.data(withJSONObject: providers),
            messages: try? file("contracts/relaunch-v1/mensajes.json")
        )
    }

    /// Runs ssh without `~/.ssh/config`: its `IdentityFile` lines point at the Desktop, and the test
    /// host reading them would make macOS ask for permission and hang the call.
    private struct ConfigFreeSSH: UniConnectProcessRunning {
        let inner: any UniConnectProcessRunning
        func run(
            executable: String, arguments: [String], environment: [String: String],
            standardInput: Data?, timeout: Duration
        ) async throws -> UniConnectProcessResult {
            let isSSH = executable == "/usr/bin/ssh"
            return try await inner.run(
                executable: executable, arguments: isSSH ? ["-F", "/dev/null"] + arguments : arguments,
                environment: environment, standardInput: standardInput, timeout: timeout
            )
        }
    }

    private var verb: RelaunchVerb { RelaunchVerb(rawValue: environment["UC_LIVE_VERB"] ?? "") ?? .agentRelaunch }

    private func options() throws -> RelaunchUpdateOptions {
        guard verb == .agentUpdate else { return .unchanged }
        return try RelaunchUpdateOptions(model: environment["UC_LIVE_MODEL"], effort: environment["UC_LIVE_EFFORT"])
    }

    private func write(_ preview: UniConnectRelaunchCoordinator.Preview, _ operation: RelaunchOperation?) throws {
        var report: [String: Any] = [
            "targets": preview.targets.map(\.json),
            "excluded": preview.exclusions.map { ["label": $0.label, "cause": $0.cause.rawValue] },
            "estimated_tokens": preview.estimatedTokens,
        ]
        if let operation { report["operation"] = operation.json }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let out = environment["UC_LIVE_OUT"] { try data.write(to: URL(fileURLWithPath: out)) }
    }

    @Test("SSH: el trabajador de Linux relanza o actualiza la sesión de prueba")
    func ssh() async throws {
        guard environment["UC_LIVE"] == "ssh", let command = environment["UC_LIVE_SSH"],
              let user = environment["UC_LIVE_USER"], let host = environment["UC_LIVE_HOST"] else { return }
        let session = environment["UC_LIVE_SESSION"] ?? "uc-prueba-relanzar"
        let scripts = try scripts()
        let credential = UUID()
        let runner = ConfigFreeSSH(inner: UniConnectControlledProcessRunner())
        let worker = UniConnectRelaunchRemoteWorker(
            processRunner: runner,
            credentialResolver: { id in
                id == credential ? UniConnectSSHCredentialRecord(
                    connectCommand: command,
                    effectiveTarget: UniConnectSSHEffectiveTarget(user: user, host: host, port: 22)
                ) : nil
            },
            scripts: { scripts }
        )
        let coordinator = UniConnectRelaunchCoordinator(
            machineID: "mac", remoteSighting: { _ in .agent(provider: "claude") }, remoteWorker: worker
        )
        let workspace = Workspace()
        workspace.customTitle = "PRUEBA"
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .ssh, credentialId: credential, hostLabel: "\(user)@\(host)", tmuxReady: true)
        let panel = try #require(workspace.focusedPanelId)
        workspace.uniConnectTmuxSessionsByPanelId[panel] = session

        let preview = await coordinator.preview(workspaces: [workspace], verb: verb, options: try options())
        try write(preview, nil)
        try #require(preview.targets.count == 1, "la sesión de prueba no entró en el plan")
        guard environment["UC_LIVE_PLAN_ONLY"] == nil else { return }
        let operation = await coordinator.run(preview)
        try write(preview, operation)
        #expect(operation.results.first?.state == .verified)
    }

    @Test("Local: el Claude de un socket privado de este Mac se relanza o actualiza")
    func local() async throws {
        guard environment["UC_LIVE"] == "local", let socket = environment["UC_LIVE_SOCKET"],
              let session = environment["UC_LIVE_SESSION"] else { return }
        let runner = UniConnectControlledProcessRunner()
        let installation = UniConnectRelaunchLocalInstallation(processRunner: runner)
        let claude = UniConnectRelaunchLocalClaude()
        let inspection = await claude.inspect(socket: socket, session: session, verb: verb)
        guard case let .proof(proof, notes) = inspection else {
            Issue.record("no se acreditó: \(inspection)")
            return
        }
        let target = UniConnectRelaunchExecutor.Target(
            key: RelaunchTargetKey(destination: .local(machineID: "mac"), tmuxServer: socket, pane: session, generation: 1),
            label: "PRUEBA · \(session)", provider: "claude", socket: socket, session: session, previousArgv: [],
            route: .localClaude(proof), notes: notes
        )
        let status = await installation.status(launcherPath: proof.launcherPath ?? "", path: proof.searchPath)
        print("instalación: \(status)")
        let coordinator = UniConnectRelaunchCoordinator(machineID: "mac", localClaude: claude, localInstallation: installation)
        let preview = UniConnectRelaunchCoordinator.Preview(verb: verb, options: try options(), targets: [target], excluded: [])
        try write(preview, nil)
        guard environment["UC_LIVE_PLAN_ONLY"] == nil else { return }
        let operation = await coordinator.run(preview)
        try write(preview, operation)
        #expect(operation.results.first?.state == .verified)
    }
}
