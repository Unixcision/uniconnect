import Foundation

/// Qué espera un aviso del usuario: una respuesta (`attention`), nada porque el turno
/// terminó (`finished`) o solo informa (`info`).
///
/// Viaja como `kind` en `mobile.notifications.list` y en el evento `notification.created`,
/// se persiste con el aviso y se decide al crearlo. Este archivo lo comparten la app y el
/// CLI (`cmux claude-hook`, hooks genéricos) para que ambos hablen el mismo vocabulario.
enum TerminalNotificationKind: String, Codable, Sendable, CaseIterable {
    /// El agente espera al usuario: permiso, pregunta, elicitation, needs input.
    case attention
    /// El turno terminó: Stop, idle_prompt, agent_completed.
    case finished
    /// Todo lo demás.
    case info

    /// Valores de `notification_type` del hook `Notification` de Claude Code que piden respuesta.
    static let claudeAttentionTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]
    /// Valores de `notification_type` que anuncian que el turno terminó.
    static let claudeFinishedTypes: Set<String> = ["idle_prompt", "agent_completed"]

    /// Cuarto campo opcional del payload `title|subtitle|body|kind` de los comandos `notify*`.
    init?(wireValue: String) {
        self.init(rawValue: wireValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Aviso creado por `cmux claude-hook <subcommand>`.
    ///
    /// - Parameters:
    ///   - subcommand: `notification`, `stop` o `idle`.
    ///   - notificationType: `notification_type` de la entrada del hook, si viene.
    ///   - message: Texto del aviso, usado solo cuando no hay tipo reconocible.
    static func forClaudeHook(
        subcommand: String,
        notificationType: String?,
        message: String?
    ) -> TerminalNotificationKind {
        switch subcommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "stop", "idle":
            return .finished
        case "notification", "notify":
            if let type = normalized(notificationType) {
                if claudeAttentionTypes.contains(type) { return .attention }
                if claudeFinishedTypes.contains(type) { return .finished }
            }
            return forMessageCues(message) ?? .info
        default:
            return .info
        }
    }

    /// Aviso de un hook genérico (Codex, Gemini, Agy, Grok…): decide el evento y, si no
    /// dice nada, el estado clasificado (`needsInput`, `idle`, `error`).
    static func forAgentHook(event: String?, status: String?) -> TerminalNotificationKind {
        if let event = normalized(event) {
            if event.contains("permission") || event == "askuserquestion" || event == "exitplanmode" {
                return .attention
            }
            if event == "stop" || event == "idle" || event.contains("turn-complete") || event.contains("turn_complete") {
                return .finished
            }
        }
        switch normalized(status) {
        case "needsinput", "needs_input", "needs-input":
            return .attention
        case "idle", "completed", "finished":
            return .finished
        default:
            return .info
        }
    }

    /// Pistas en el texto cuando no hay tipo explícito; `nil` si no dice nada.
    static func forMessageCues(_ message: String?) -> TerminalNotificationKind? {
        guard let lowered = message?.lowercased(), !lowered.isEmpty else { return nil }
        let attentionPhrases = ["needs your input", "needs your attention", "question"]
        if attentionPhrases.contains(where: { lowered.contains($0) }) {
            return .attention
        }
        let tokens = lowered.split { !$0.isLetter }.map(String.init)
        if tokens.contains(where: { $0.hasPrefix("permission") || $0.hasPrefix("approv") }) {
            return .attention
        }
        if tokens.contains(where: { $0 == "done" || $0 == "idle" || $0.hasPrefix("complet") || $0.hasPrefix("finish") }) {
            return .finished
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }
}
