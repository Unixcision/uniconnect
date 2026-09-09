import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Derivación pura del `kind` de los avisos móviles (`attention` | `finished` | `info`).
@Suite("Tipo de aviso (kind)")
struct TerminalNotificationKindTests {
    @Test("El cuarto campo del payload solo cuenta si es un kind válido")
    func wireValue() {
        #expect(TerminalNotificationKind(wireValue: " Attention ") == .attention)
        #expect(TerminalNotificationKind(wireValue: "finished") == .finished)
        #expect(TerminalNotificationKind(wireValue: "info") == .info)
        #expect(TerminalNotificationKind(wireValue: "otra cosa") == nil)
        #expect(TerminalNotificationKind(wireValue: "") == nil)
    }

    @Test(
        "Hook notification de Claude: manda notification_type",
        arguments: [
            ("permission_prompt", TerminalNotificationKind.attention),
            ("elicitation_dialog", .attention),
            ("elicitation_url_dialog", .attention),
            ("agent_needs_input", .attention),
            ("idle_prompt", .finished),
            ("agent_completed", .finished),
            ("Permission_Prompt ", .attention),
            ("algo_nuevo", .info),
        ]
    )
    func claudeNotificationType(type: String, expected: TerminalNotificationKind) {
        let kind = TerminalNotificationKind.forClaudeHook(
            subcommand: "notification",
            notificationType: type,
            message: "Texto que no debe influir"
        )
        #expect(kind == expected)
    }

    @Test("Los subcomandos stop e idle de Claude son finished")
    func claudeStopIsFinished() {
        #expect(TerminalNotificationKind.forClaudeHook(subcommand: "stop", notificationType: nil, message: "Task completed") == .finished)
        #expect(TerminalNotificationKind.forClaudeHook(subcommand: "idle", notificationType: nil, message: nil) == .finished)
        #expect(TerminalNotificationKind.forClaudeHook(subcommand: "prompt-submit", notificationType: nil, message: nil) == .info)
    }

    @Test("Sin notification_type se usan las pistas del texto")
    func claudeMessageCues() {
        #expect(TerminalNotificationKind.forClaudeHook(subcommand: "notification", notificationType: nil, message: "Claude needs your permission to run ls") == .attention)
        #expect(TerminalNotificationKind.forClaudeHook(subcommand: "notification", notificationType: nil, message: "Claude needs your attention") == .attention)
        #expect(TerminalNotificationKind.forClaudeHook(subcommand: "notification", notificationType: nil, message: "Task completed") == .finished)
        #expect(TerminalNotificationKind.forClaudeHook(subcommand: "notification", notificationType: nil, message: "Abandoned the build") == .info)
        #expect(TerminalNotificationKind.forClaudeHook(subcommand: "notification", notificationType: nil, message: nil) == .info)
    }

    @Test("Hooks genéricos: primero el evento, luego el estado clasificado")
    func agentHooks() {
        #expect(TerminalNotificationKind.forAgentHook(event: "PermissionRequest", status: nil) == .attention)
        #expect(TerminalNotificationKind.forAgentHook(event: "Stop", status: "idle") == .finished)
        #expect(TerminalNotificationKind.forAgentHook(event: "Stop", status: "error") == .finished)
        #expect(TerminalNotificationKind.forAgentHook(event: "agent-turn-complete", status: nil) == .finished)
        #expect(TerminalNotificationKind.forAgentHook(event: nil, status: "needsInput") == .attention)
        #expect(TerminalNotificationKind.forAgentHook(event: nil, status: "idle") == .finished)
        #expect(TerminalNotificationKind.forAgentHook(event: nil, status: "error") == .info)
        #expect(TerminalNotificationKind.forAgentHook(event: nil, status: nil) == .info)
    }

    @Test("Sin kind explícito decide la actividad de la ventana")
    func activityFallback() {
        #expect(TerminalNotificationKind.derived(explicit: .info, activityState: .waiting) == .info)
        #expect(TerminalNotificationKind.derived(explicit: nil, activityState: .waiting) == .attention)
        #expect(TerminalNotificationKind.derived(explicit: nil, activityState: .idle) == .finished)
        #expect(TerminalNotificationKind.derived(explicit: nil, activityState: .working) == .info)
        #expect(TerminalNotificationKind.derived(explicit: nil, activityState: .unknown) == .info)
        #expect(TerminalNotificationKind.derived(explicit: nil, activityState: nil) == .info)
    }

    @Test("Los avisos persistidos sin kind se leen como info y el kind sobrevive al viaje")
    func snapshotPersistence() throws {
        let legacy = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","subtitle":"s","body":"b","createdAt":1,"isRead":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionNotificationSnapshot.self, from: legacy)
        let restored = decoded.terminalNotification(tabId: UUID(), surfaceId: nil, panelId: nil)
        #expect(restored.kind == .info)

        let notification = TerminalNotification(
            id: UUID(), tabId: UUID(), surfaceId: nil,
            title: "t", subtitle: "s", body: "b",
            createdAt: Date(timeIntervalSince1970: 1), isRead: false,
            kind: .attention
        )
        let encoded = try JSONEncoder().encode(SessionNotificationSnapshot(notification: notification))
        let roundTrip = try JSONDecoder().decode(SessionNotificationSnapshot.self, from: encoded)
        #expect(roundTrip.terminalNotification(tabId: UUID(), surfaceId: nil, panelId: nil).kind == .attention)
    }

    @Test("El registro móvil lleva kind en su JSON")
    func mobileRecordCarriesKind() {
        let notification = TerminalNotification(
            id: UUID(), tabId: UUID(), surfaceId: nil,
            title: "t", subtitle: "s", body: "b",
            createdAt: Date(timeIntervalSince1970: 1), isRead: false,
            kind: .finished
        )
        #expect(notification.mobileNotificationRecord.jsonObject()["kind"] as? String == "finished")
    }
}
