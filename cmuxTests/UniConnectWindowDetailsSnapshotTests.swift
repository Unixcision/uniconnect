import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// «Detalles» sale igual en el modal que en el cable: la respuesta es la del contrato, clave a clave.
@Suite("UniConnect: Detalles de una ventana (window_details.v1)")
struct UniConnectWindowDetailsSnapshotTests {
    private func fixture(_ name: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/window-details-v1/\(name)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// El payload tal y como viaja: pasado por JSON, sin las fechas, que dependen del reloj.
    private func comparable(_ object: [String: Any]) throws -> NSDictionary {
        let data = try JSONSerialization.data(withJSONObject: object)
        var parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        parsed.removeValue(forKey: "checked_at")
        if var agent = parsed["agent"] as? [String: Any] {
            agent.removeValue(forKey: "observed_at")
            parsed["agent"] = agent
        }
        return parsed as NSDictionary
    }

    private func claude(
        _ id: String, cwd: String, asRoot: Bool
    ) throws -> UniConnectWindowDetailsSnapshot.Agent {
        let resume = try #require(try AgentNoPromptPolicy().resume(provider: "claude", sessionID: id, asRoot: asRoot))
        return .init(
            provider: "claude", displayName: "Claude Code", sessionID: id, workingDirectory: cwd,
            asRoot: asRoot, source: "ficha", state: .active, observedAt: Date(),
            resume: .init(
                argv: resume.argv, environment: resume.environment,
                command: resume.shellLine(workingDirectory: cwd), noPromptVerified: resume.noPromptVerified
            )
        )
    }

    private let xunis = UniConnectWindowDetailsSnapshot.Host(user: "root", hostname: "167.233.192.135", port: 22)

    @Test("Local con Claude en marcha")
    func localWithClaude() throws {
        guard let expected = fixture("details-response-local.json") else { return }
        let snapshot = UniConnectWindowDetailsSnapshot(
            workspaceID: try #require(UUID(uuidString: "b3a1c9e2-4d5f-4a6b-8c7d-9e0f1a2b3c4d")),
            terminalID: try #require(UUID(uuidString: "e86e9114-031c-4752-941d-1079c170a639")),
            checkedAt: Date(),
            workspaceName: "PROYECTOS",
            kind: .local,
            host: nil,
            hostLabel: nil,
            windowName: "MULTIGRAM-CLAUDE",
            tmux: .init(socket: "uniconnect-local", session: "uc-e86e9114031c4752941d1079c170a639",
                        sessionID: "$12", paneID: "%14", live: true),
            agent: try claude("714b0eae-b568-4e0c-a70b-c87c0d0a801a",
                              cwd: "/Users/danielgomezmartin/Desktop/PROYECTOS/MULTIGRAM", asRoot: false),
            reason: nil
        )
        #expect(try comparable(snapshot.mobilePayload) == comparable(expected))
    }

    @Test("SSH con Claude como root lleva IS_SANDBOX en la orden")
    func sshWithRootClaude() throws {
        guard let expected = fixture("details-response-ssh.json") else { return }
        let snapshot = UniConnectWindowDetailsSnapshot(
            workspaceID: try #require(UUID(uuidString: "5d6f2c1e-8a4b-4f0e-9c3d-2b1a0e9f8c7d")),
            terminalID: try #require(UUID(uuidString: "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")),
            checkedAt: Date(),
            workspaceName: "XUNISSCRAPPER",
            kind: .ssh,
            host: xunis,
            hostLabel: "root@167.233.192.135:22",
            windowName: "claudebets",
            tmux: .init(socket: "default", session: "claudebets", sessionID: "$0", paneID: "%0", live: true),
            agent: try claude("473ed1de-4397-45ef-b00b-6b17fd7382b0", cwd: "/root/xunis", asRoot: true),
            reason: nil
        )
        #expect(try comparable(snapshot.mobilePayload) == comparable(expected))
    }

    @Test("SSH sin IA: agent null y reason sin_ia")
    func sshWithoutAgent() throws {
        guard let expected = fixture("details-response-no-agent.json") else { return }
        let snapshot = UniConnectWindowDetailsSnapshot(
            workspaceID: try #require(UUID(uuidString: "5d6f2c1e-8a4b-4f0e-9c3d-2b1a0e9f8c7d")),
            terminalID: try #require(UUID(uuidString: "c7d8e9f0-1a2b-4c3d-8e4f-5a6b7c8d9e0f")),
            checkedAt: Date(),
            workspaceName: "XUNISSCRAPPER",
            kind: .ssh,
            host: xunis,
            hostLabel: "root@167.233.192.135:22",
            windowName: "hgabot",
            tmux: .init(socket: "default", session: "hgabot", sessionID: "$3", paneID: "%3", live: true),
            agent: nil,
            reason: "sin_ia"
        )
        #expect(try comparable(snapshot.mobilePayload) == comparable(expected))
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
}
