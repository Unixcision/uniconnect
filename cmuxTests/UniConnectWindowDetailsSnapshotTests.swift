import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// «Detalles» sale igual en el modal que en el cable: la respuesta es la del contrato, clave a clave,
/// y cada fila dice exactamente el texto de `contracts/window-details-v1/filas.json`.
@Suite("UniConnect: Detalles de una ventana (window_details.v1)")
struct UniConnectWindowDetailsSnapshotTests {
    /// `contracts/<ruta>` como objeto JSON. Sube desde este fichero hasta encontrar `contracts/` y
    /// falla si no está (D8): un test de contrato que sale en verde sin comparar no vale.
    static func contract(_ path: String, from testFile: String = #filePath) throws -> Any {
        var components = URL(fileURLWithPath: testFile).deletingLastPathComponent().pathComponents
        var found: URL?
        while !components.isEmpty, found == nil {
            let candidate = NSString.path(withComponents: components + ["contracts", path])
            if FileManager.default.fileExists(atPath: candidate) { found = URL(fileURLWithPath: candidate) }
            components.removeLast()
        }
        let url = try #require(found, "No se encuentra contracts/\(path) subiendo desde el test")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    static func fixture(_ name: String) throws -> [String: Any] {
        try #require(try contract("window-details-v1/\(name)") as? [String: Any], "\(name) no es un objeto")
    }

    /// El payload tal y como viaja, pasado por JSON para comparar valores y no tipos de Foundation.
    static func comparable(_ object: [String: Any]) throws -> NSDictionary {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    static let responses = [
        "details-response-local.json", "details-response-ssh.json", "details-response-no-agent.json",
        "details-response-saved-shell.json", "details-response-sin-id.json", "details-response-interrupted.json",
        "details-response-no-tmux.json", "details-response-local-unreachable.json", "details-response-vault-closed.json",
    ]

    @Test("Cada respuesta del contrato se lee y se vuelve a escribir igual", arguments: UniConnectWindowDetailsSnapshotTests.responses)
    func everyResponseRoundTrips(_ name: String) throws {
        let expected = try Self.fixture(name)
        let snapshot = try #require(UniConnectWindowDetailsSnapshot(mobilePayload: expected), "\(name)")
        #expect(try Self.comparable(snapshot.mobilePayload) == Self.comparable(expected), "\(name)")
    }

    @Test("Las filas del modal son las de filas.json, letra por letra")
    func everyResponseShowsTheContractRows() throws {
        let table = try #require(try Self.contract("window-details-v1/filas.json") as? [String: Any])
        let cases = try #require(table["casos"] as? [[String: Any]], "filas.json sin «casos»")
        #expect(Set(cases.compactMap { $0["fixture"] as? String }) == Set(Self.responses))
        for entry in cases {
            let name = try #require(entry["fixture"] as? String)
            let snapshot = try #require(UniConnectWindowDetailsSnapshot(mobilePayload: try Self.fixture(name)), "\(name)")
            let rows = UniConnectWindowDetailsRows(snapshot: snapshot)
            let expectedRows = try #require(entry["filas"] as? [[String]], "\(name): filas")
            #expect(rows.allRows.map { [$0.label, $0.value] } == expectedRows, "\(name)")
            #expect(rows.notice == entry["aviso"] as? String, "\(name): aviso")
            #expect(rows.resumeNote == entry["nota_orden"] as? String, "\(name): nota_orden")
        }
    }

    @Test("Las fechas van en ISO 8601 UTC y todas las claves están, nulas si no aplican")
    func datesAndNulls() throws {
        let snapshot = UniConnectWindowDetailsSnapshot(
            workspaceID: UUID(), terminalID: UUID(),
            checkedAt: Date(timeIntervalSince1970: 1790260205),
            workspaceName: "X", kind: .local, host: nil, hostLabel: nil, windowName: "w",
            tmux: nil, agent: nil, reason: "sin_tmux"
        )
        let payload = snapshot.mobilePayload
        #expect(payload["checked_at"] as? String == "2026-09-24T14:30:05Z")
        #expect(payload["tmux"] is NSNull)
        #expect(payload["agent"] is NSNull)
        #expect(payload["reason"] as? String == "sin_tmux")
        let workspace = try #require(payload["workspace"] as? [String: Any])
        #expect(workspace["host"] is NSNull)
        #expect(workspace["host_label"] is NSNull)
        // Nunca viaja la orden de conexión ni la credencial.
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        #expect(!text.contains("connect"))
        #expect(!text.contains("credential"))
    }

    @Test("La etiqueta del host es siempre usuario@host:puerto")
    func hostLabels() {
        #expect(UniConnectWindowDetailsResolver.normalizedHostLabel("root@167.233.192.135") == "root@167.233.192.135:22")
        #expect(UniConnectWindowDetailsResolver.normalizedHostLabel("root@167.233.192.135:2222") == "root@167.233.192.135:2222")
        #expect(UniConnectWindowDetailsResolver.normalizedHostLabel("mi-alias") == "mi-alias:22")
        #expect(UniConnectWindowDetailsResolver.normalizedHostLabel("root@2001:db8::1") == "root@[2001:db8::1]:22")
        #expect(UniConnectWindowDetailsResolver.normalizedHostLabel("root@[2001:db8::1]:2200") == "root@[2001:db8::1]:2200")
        #expect(UniConnectWindowDetailsResolver.hostLabel(user: "dani", hostname: "2001:db8::1", port: 22) == "dani@[2001:db8::1]:22")
    }
}

/// La lógica de `windowDetails` con un inspector local y una sonda SSH falsos: cada respuesta del
/// contrato sale de lo guardado más lo que leyó la comprobación en vivo.
@Suite("UniConnect: lógica de Detalles con inspector y sonda falsos")
struct UniConnectWindowDetailsResolverTests {
    /// Un inspector local que contesta lo que se le diga, sin tmux ni procesos.
    private struct FakeInspector: UniConnectLocalTmuxInspecting {
        let identity: UniConnectLocalTmuxLiveIdentity?
        let state: UniConnectLocalTmuxRuntimeObservation.State?

        func runtimeObservations(
            for targets: [UniConnectLocalTmuxRuntimeObservation.Target]
        ) async -> [UniConnectLocalTmuxRuntimeObservation] {
            guard let state else { return [] }
            return targets.map { UniConnectLocalTmuxRuntimeObservation(target: $0, state: state) }
        }

        func generation(for binding: UniConnectLocalTmuxBinding, workspaceID: UUID, panelID: UUID) async -> UUID? { nil }

        func verifiedOwner(
            of peer: UniConnectLocalTmuxProcessIdentity,
            among owners: [UniConnectLocalTmuxOwner]
        ) async -> UniConnectLocalTmuxOwner? { nil }

        func liveIdentity(binding: UniConnectLocalTmuxBinding) async -> UniConnectLocalTmuxLiveIdentity? { identity }
    }

    private let resolver = UniConnectWindowDetailsResolver(policy: try? AgentNoPromptPolicy())
    private let xunis = UniConnectWindowDetailsSnapshot.Host(user: "root", hostname: "167.233.192.135", port: 22)
    private let multigram = "/Users/danielgomezmartin/Desktop/PROYECTOS/MULTIGRAM"

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso), "\(iso)")
    }

    /// Lo guardado de la ventana de un fixture: identidad, espacio, ventana y tmux salen de él.
    private func saved(
        _ fixture: [String: Any],
        host: UniConnectWindowDetailsSnapshot.Host?,
        profileHostLabel: String? = nil,
        agent: UniConnectWindowDetailsResolver.SavedAgent?
    ) throws -> UniConnectWindowDetailsResolver.Saved {
        let workspace = try #require(fixture["workspace"] as? [String: Any])
        let window = try #require(fixture["window"] as? [String: Any])
        let tmux = fixture["tmux"] as? [String: Any]
        return UniConnectWindowDetailsResolver.Saved(
            workspaceID: try #require((fixture["workspace_id"] as? String).flatMap(UUID.init(uuidString:))),
            terminalID: try #require((fixture["terminal_id"] as? String).flatMap(UUID.init(uuidString:))),
            workspaceName: try #require(workspace["name"] as? String),
            kind: try #require((workspace["kind"] as? String).flatMap(UniConnectWindowDetailsSnapshot.Kind.init(rawValue:))),
            host: host,
            profileHostLabel: profileHostLabel,
            windowName: try #require(window["name"] as? String),
            tmuxSocket: tmux?["socket"] as? String,
            tmuxSession: tmux?["session"] as? String,
            agent: agent
        )
    }

    private func expectMatches(
        _ fixtureName: String,
        saved input: UniConnectWindowDetailsResolver.Saved,
        check: UniConnectWindowDetailsResolver.LiveCheck,
        confirmed: Bool
    ) throws {
        let expected = try UniConnectWindowDetailsSnapshotTests.fixture(fixtureName)
        let now = try date(try #require(expected["checked_at"] as? String))
        let result = resolver.details(input, check: check, now: now)
        #expect(result.confirmed == confirmed, "\(fixtureName)")
        #expect(
            try UniConnectWindowDetailsSnapshotTests.comparable(result.details.mobilePayload)
                == UniConnectWindowDetailsSnapshotTests.comparable(expected),
            "\(fixtureName)"
        )
    }

    /// La sonda falsa: la salida del contrato, tal y como la emite agent_probe.py.
    private func probeOutput() throws -> AgentProbeReport {
        let object = try UniConnectWindowDetailsSnapshotTests.contract("agent-tree-v1/sonda-salida.json")
        return try #require(AgentProbeReport.decode(output: try JSONSerialization.data(withJSONObject: object)))
    }

    @Test("SSH con Claude como root en marcha")
    func sshActiveClaude() throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-ssh.json")
        let check = UniConnectWindowDetailsResolver.remoteCheck(
            report: try probeOutput(), session: "claudebets", checkedAt: try date("2026-09-24T14:30:04Z")
        )
        try expectMatches("details-response-ssh.json", saved: try saved(fixture, host: xunis, agent: nil),
                          check: check, confirmed: true)
    }

    @Test("SSH sin IA ni guardada ni en marcha")
    func sshWithoutAgent() throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-no-agent.json")
        let check = UniConnectWindowDetailsResolver.remoteCheck(
            report: try probeOutput(), session: "hgabot", checkedAt: try date("2026-09-24T14:30:04Z")
        )
        try expectMatches("details-response-no-agent.json", saved: try saved(fixture, host: xunis, agent: nil),
                          check: check, confirmed: true)
    }

    @Test("IA en marcha sin id: sin session_id, sin source y sin orden")
    func sshAgentWithoutID() throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-sin-id.json")
        let check = UniConnectWindowDetailsResolver.remoteCheck(
            report: try probeOutput(), session: "ufabetbot", checkedAt: try date("2026-09-24T14:30:04Z")
        )
        try expectMatches("details-response-sin-id.json", saved: try saved(fixture, host: xunis, agent: nil),
                          check: check, confirmed: true)
    }

    @Test("IA guardada y ahora en un shell: lo guardado con reason sin_ia")
    func savedAgentAtAShell() throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-saved-shell.json")
        let report = AgentProbeReport(socket: "default", uid: 0, sessions: [
            .init(name: "bets-codex", sessionID: "$8", paneID: "%9", reason: "sin_ia", agent: nil,
                  panes: [.init(paneID: "%9")]),
        ])
        let check = UniConnectWindowDetailsResolver.remoteCheck(
            report: report, session: "bets-codex", checkedAt: try date("2026-09-24T14:30:04Z")
        )
        let agent = UniConnectWindowDetailsResolver.SavedAgent(
            provider: "codex", sessionID: "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17", workingDirectory: "/root/bets",
            asRoot: nil, state: .saved, observedAt: try date("2026-09-24T12:05:31Z")
        )
        try expectMatches("details-response-saved-shell.json", saved: try saved(fixture, host: xunis, agent: agent),
                          check: check, confirmed: true)
    }

    @Test("Con la bóveda cerrada: sin host, etiqueta normalizada y root por la etiqueta")
    func vaultClosed() throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-vault-closed.json")
        let agent = UniConnectWindowDetailsResolver.SavedAgent(
            provider: "claude", sessionID: "473ed1de-4397-45ef-b00b-6b17fd7382b0", workingDirectory: "/root/xunis",
            asRoot: nil, state: .saved, observedAt: try date("2026-09-24T14:29:04Z")
        )
        // Una etiqueta antigua sin puerto se enseña con :22.
        try expectMatches(
            "details-response-vault-closed.json",
            saved: try saved(fixture, host: nil, profileHostLabel: "root@167.233.192.135", agent: agent),
            check: .failed, confirmed: false
        )
    }

    @Test("Una sonda sin respuesta, con error o recortada deja lo guardado con host_inaccesible")
    func remoteFailures() throws {
        #expect(UniConnectWindowDetailsResolver.remoteCheck(report: nil, session: "x", checkedAt: Date()) == .failed)
        let failed = AgentProbeReport(socket: "default", uid: 0, server: false, error: "tmux_fallo", sessions: [])
        #expect(UniConnectWindowDetailsResolver.remoteCheck(report: failed, session: "x", checkedAt: Date()) == .failed)
        let cut = AgentProbeReport(socket: "default", uid: 0, truncated: true, sessions: [])
        #expect(UniConnectWindowDetailsResolver.remoteCheck(report: cut, session: "x", checkedAt: Date()) == .failed)
        let at = Date(timeIntervalSince1970: 5)
        let complete = AgentProbeReport(socket: "default", uid: 0, sessions: [])
        #expect(UniConnectWindowDetailsResolver.remoteCheck(report: complete, session: "x", checkedAt: at)
            == .sessionNotRunning(checkedAt: at))
    }

    private func localTarget(_ fixture: [String: Any]) throws -> (UniConnectLocalTmuxBinding, UniConnectLocalTmuxRuntimeObservation.Target) {
        let tmux = try #require(fixture["tmux"] as? [String: Any])
        // Sin #require anidados: Swift 6.4 (Xcode 27) los rechaza como expansión recursiva.
        let session = try #require(tmux["session"] as? String)
        let socket = try #require(tmux["socket"] as? String)
        let binding = try #require(UniConnectLocalTmuxBinding(name: session, socketName: socket))
        let panel = try #require((fixture["terminal_id"] as? String).flatMap(UUID.init(uuidString:)))
        let workspace = try #require((fixture["workspace_id"] as? String).flatMap(UUID.init(uuidString:)))
        let record = UniConnectLocalWindowRecord(id: panel, boxRoot: "/Users/danielgomezmartin/Desktop/PROYECTOS", tmuxBinding: binding)
        return (binding, .init(
            owner: .init(workspaceID: workspace, panelID: panel, binding: binding, surfaceGeneration: UUID()),
            record: record
        ))
    }

    @Test("Local con Claude en marcha, leído por el inspector")
    func localActiveClaude() async throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-local.json")
        let (binding, target) = try localTarget(fixture)
        let inspector = FakeInspector(
            identity: UniConnectLocalTmuxLiveIdentity(sessionID: "$12", paneID: "%14"),
            state: .discovered(AgentObservedConversation(
                provider: .claude, sessionID: "714b0eae-b568-4e0c-a70b-c87c0d0a801a",
                workingDirectory: multigram, asRoot: false, source: .sessionFile, processID: 4242
            ))
        )
        let live = await UniConnectWindowDetailsResolver.localCheck(
            inspector: inspector, binding: binding, target: target, savedDirectory: nil
        )
        guard case let .sessionSeen(sessionID, paneID, agent, reason, hostUserID, _) = live else {
            Issue.record("\(live)")
            return
        }
        let check = UniConnectWindowDetailsResolver.LiveCheck.sessionSeen(
            sessionID: sessionID, paneID: paneID, agent: agent, reason: reason, hostUserID: hostUserID,
            checkedAt: try date("2026-09-24T14:30:04Z")
        )
        try expectMatches("details-response-local.json", saved: try saved(fixture, host: nil, agent: nil),
                          check: check, confirmed: true)
    }

    @Test("Local interrumpida con su tmux parado: la comprobación va bien y no hay nada en marcha")
    func localInterrupted() async throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-interrupted.json")
        let (binding, target) = try localTarget(fixture)
        let live = await UniConnectWindowDetailsResolver.localCheck(
            inspector: FakeInspector(identity: nil, state: nil), binding: binding, target: target, savedDirectory: nil
        )
        guard case .sessionNotRunning = live else {
            Issue.record("\(live)")
            return
        }
        let agent = UniConnectWindowDetailsResolver.SavedAgent(
            provider: "claude", sessionID: "9d4b2e6f-1a3c-4e8b-b7d0-5f2c8a1e6b93",
            workingDirectory: "/Users/danielgomezmartin/Desktop/PROYECTOS/TIPSTERTRUST",
            asRoot: false, state: .interrupted, observedAt: try date("2026-09-24T13:58:12Z")
        )
        try expectMatches("details-response-interrupted.json", saved: try saved(fixture, host: nil, agent: agent),
                          check: live, confirmed: true)
    }

    @Test("Local con la sesión viva pero el panel sin verificar: lo guardado y host_inaccesible")
    func localCheckFailed() async throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-local-unreachable.json")
        let (binding, target) = try localTarget(fixture)
        let live = await UniConnectWindowDetailsResolver.localCheck(
            inspector: FakeInspector(identity: UniConnectLocalTmuxLiveIdentity(sessionID: "$12", paneID: "%14"), state: nil),
            binding: binding, target: target, savedDirectory: nil
        )
        #expect(live == .failed)
        let agent = UniConnectWindowDetailsResolver.SavedAgent(
            provider: "claude", sessionID: "714b0eae-b568-4e0c-a70b-c87c0d0a801a", workingDirectory: multigram,
            asRoot: false, state: .saved, observedAt: try date("2026-09-24T14:29:56Z")
        )
        try expectMatches("details-response-local-unreachable.json", saved: try saved(fixture, host: nil, agent: agent),
                          check: live, confirmed: false)
    }

    @Test("Ventana antigua sin tmux")
    func withoutTmux() throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-no-tmux.json")
        try expectMatches("details-response-no-tmux.json", saved: try saved(fixture, host: nil, agent: nil),
                          check: .sessionNotRunning(checkedAt: Date()), confirmed: true)
    }

    @Test("Ambigua o panel muerto no ponen la IA guardada en marcha")
    func ambiguousAndDeadPanes() throws {
        let fixture = try UniConnectWindowDetailsSnapshotTests.fixture("details-response-saved-shell.json")
        let agent = UniConnectWindowDetailsResolver.SavedAgent(
            provider: "codex", sessionID: "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17", workingDirectory: "/root/bets",
            asRoot: true, state: .saved, observedAt: nil
        )
        let input = try saved(fixture, host: xunis, agent: agent)
        let dead = resolver.details(input, check: UniConnectWindowDetailsResolver.remoteCheck(
            report: try probeOutput(), session: "caida", checkedAt: Date()
        ), now: Date()).details
        #expect(dead.reason == "sin_ia")
        #expect(dead.agent?.state == .saved)
        let ambiguous = resolver.details(input, check: UniConnectWindowDetailsResolver.remoteCheck(
            report: try probeOutput(), session: "pruebas", checkedAt: Date()
        ), now: Date()).details
        #expect(ambiguous.reason == "identidad_ambigua")
        #expect(ambiguous.agent?.state == .saved)
        #expect(UniConnectWindowDetailsRows(snapshot: ambiguous).rows.contains(
            UniConnectWindowDetailsRows.Row(label: "IA", value: "Hay más de una IA en esta ventana")
        ))
    }
}
