import Foundation

/// Lo que el título de la ventana y el comando en primer plano dicen de la IA.
///
/// Reglas comprobadas en producción: Claude Code encabeza el título con `✳ tema`
/// cuando no trabaja y con otra marca (`·`) cuando trabaja; Codex antepone un
/// spinner braille (U+2800–U+28FF) mientras trabaja y lo quita al parar; Gemini y
/// Agy no marcan nada. Si el proceso en primer plano es un shell, no hay IA.
struct AgentActivityTitleSignal: Equatable, Sendable {
    /// Comandos que son un shell: la ventana no tiene IA aunque el título diga algo.
    static let shellCommands: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "login",
    ]
    /// Marca con la que Claude Code encabeza el título cuando no trabaja.
    static let claudeIdleMarker: Character = "✳"
    /// Marcas con las que Claude Code encabeza el título mientras trabaja.
    static let claudeWorkingMarkers: Set<Character> = ["·", "•", "✶", "✻", "✽", "✢", "∗"]

    let agent: AgentActivity.Agent?
    /// `.working` o `.idle` cuando el título lo dice; `nil` cuando no dice nada.
    let state: AgentActivity.State?
    /// El proceso en primer plano es un shell: no hay IA en la ventana.
    let isShell: Bool

    init(title: String?, currentCommand: String?) {
        let command = Self.normalizedCommand(currentCommand)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let command, Self.shellCommands.contains(command) {
            agent = nil
            state = nil
            isShell = true
            return
        }
        let resolvedAgent = Self.agent(fromCommand: command) ?? Self.agent(fromTitle: trimmedTitle)
        agent = resolvedAgent
        isShell = false
        state = Self.state(for: resolvedAgent, title: trimmedTitle)
    }

    /// Último componente del comando, sin el guion de shell de login y en minúsculas.
    static func normalizedCommand(_ rawCommand: String?) -> String? {
        guard var command = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return nil }
        if command.hasPrefix("-") {
            command.removeFirst()
        }
        command = command.split(separator: " ").first.map(String.init) ?? command
        return (command as NSString).lastPathComponent.lowercased()
    }

    /// Primer escalar dentro del bloque braille (spinner de Codex).
    static func startsWithBrailleSpinner(_ title: String) -> Bool {
        guard let scalar = title.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(scalar.value)
    }

    private static func agent(fromCommand command: String?) -> AgentActivity.Agent? {
        guard let command else { return nil }
        switch command {
        case "claude": return .claude
        case "codex": return .codex
        case "gemini": return .gemini
        case "agy", "antigravity": return .agy
        default: return nil
        }
    }

    private static func agent(fromTitle title: String) -> AgentActivity.Agent? {
        guard !title.isEmpty else { return nil }
        if startsWithBrailleSpinner(title) {
            return .codex
        }
        if let first = title.first, first == claudeIdleMarker || first == "·" {
            return .claude
        }
        let lowered = title.lowercased()
        if lowered.contains("claude") { return .claude }
        if lowered.contains("codex") { return .codex }
        if lowered.contains("gemini") { return .gemini }
        if lowered.contains("antigravity") || lowered.hasPrefix("agy") { return .agy }
        return nil
    }

    private static func state(for agent: AgentActivity.Agent?, title: String) -> AgentActivity.State? {
        guard let agent, !title.isEmpty else { return nil }
        switch agent {
        case .claude:
            guard let first = title.first else { return nil }
            if first == claudeIdleMarker { return .idle }
            if claudeWorkingMarkers.contains(first) { return .working }
            return nil
        case .codex:
            return startsWithBrailleSpinner(title) ? .working : .idle
        case .gemini, .agy:
            return nil
        }
    }
}
