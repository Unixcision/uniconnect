import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Respuesta del trabajador")
struct RelaunchWorkerReplyTests {
    private func reply(_ text: String) -> RelaunchWorkerReply? { RelaunchWorkerReply(output: Data(text.utf8)) }

    @Test("Una sola línea UC_RELAUNCH_V1, con o sin banner del shell")
    func onlyOneVersionedLine() throws {
        #expect(reply("Welcome to Ubuntu\nUC_RELAUNCH_V1 {\"state\": \"planificado\"}\n") != nil)
        #expect(reply("UC_RELAUNCH_V1 {}\nUC_RELAUNCH_V1 {}\n") == nil)
        #expect(reply("nada\n") == nil)
        #expect(reply("UC_RELAUNCH_V1 no-json\n") == nil)
        #expect(try #require(reply("UC_RELAUNCH_V1 {\"error\": \"destino_no_linux\"}")).errorCause == .destinationNotLinux)
    }

    @Test("La prueba de inspect se guarda tal cual y lo nuevo se lee si está")
    func proofKeepsEverything() throws {
        let line = #"UC_RELAUNCH_V1 {"key": "linux:d9a3|gen:128551451948017", "generation": 128551451948017, "pane": {"pane": "%815", "socket_inode": 4245009}, "pid": 1091302, "effective_id": "40aa77ea-c0c0-45b8-90f5-ba27a45f7b9e", "active": true, "warning": "tareas_de_fondo", "background": 1, "draft": false, "context_tokens": 412000, "message": true, "version": "2.1.281", "installed": "2.1.321", "futuro": {"x": 1}}"#
        let parsed = try #require(reply(line))
        let proof = try #require(RelaunchWorkerProof(reply: parsed))
        #expect(proof.generation == 128_551_451_948_017)
        #expect(proof.pane == "%815")
        #expect(proof.notes == RelaunchTargetNotes(
            warning: .backgroundTasks, background: 1, draft: false, contextTokens: 412_000, message: true,
            version: "2.1.281", installed: "2.1.321"
        ))
        let raw = try #require(try JSONSerialization.jsonObject(with: proof.raw) as? [String: Any])
        #expect((raw["generation"] as? NSNumber)?.int64Value == 128_551_451_948_017)
        #expect(raw["futuro"] != nil)
    }

    @Test("El diario se convierte en resultado con todos sus campos; un estado raro no es un éxito")
    func progressBecomesResult() throws {
        let key = RelaunchTargetKey(destination: .ssh(user: "root", host: "15.217.153.205", port: 22), tmuxServer: "default", pane: "%815", generation: 3)
        let line = #"UC_RELAUNCH_V1 {"state": "verificado", "effective_id": "40aa", "escalation": "kill_process", "dropped_options": ["--experimental-foo"], "version": "2.1.321", "background_saved": 1, "message_sent": true, "draft_restored": false}"#
        let parsed = try #require(reply(line))
        let progress = try #require(RelaunchWorkerProgress(reply: parsed))
        #expect(progress.isSettled)
        let result = progress.result(key: key, provider: "claude")
        #expect(result.json["escalation"] as? String == "kill_process")
        #expect(result.json["background_saved"] as? Int == 1)
        #expect(result.json["dropped_options"] as? [String] == ["--experimental-foo"])
        let oddReply = try #require(reply(#"UC_RELAUNCH_V1 {"state": "rarisimo"}"#))
        let odd = try #require(RelaunchWorkerProgress(reply: oddReply))
        #expect(odd.state == .failed)
        #expect(odd.cause == .unknownDialog)
    }
}
