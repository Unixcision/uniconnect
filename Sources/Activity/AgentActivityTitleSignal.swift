import Foundation

/// Lo que el título de la ventana y el comando en primer plano dicen de la IA.
///
/// El comando (`pane_current_command` de tmux, el prefijo `comando|título` que propaga
/// el tmux remoto o el proceso en primer plano de la PTY) identifica la IA; un shell
/// significa que no hay IA; un intérprete (`node`, `python3`…) es un agente vivo sin
/// nombre. El título solo aporta evidencia POSITIVA de trabajo: Codex antepone un
/// spinner braille (U+2800–U+28FF) mientras trabaja. Claude Code pone `✳ tema` tanto
/// trabajando como parado, así que ese prefijo identifica a Claude pero nunca cambia
/// el estado.
struct AgentActivityTitleSignal: Equatable, Sendable {
    /// Comandos que son un shell: la ventana no tiene IA aunque el título diga algo.
    static let shellCommands: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "login",
    ]
    /// Comandos tras los que el proceso real no es visible desde el Mac (remoto o multiplexado).
    static let opaqueCommands: Set<String> = ["ssh", "mosh", "mosh-client", "tmux", "screen", "et"]
    /// Intérpretes bajo los que corren los agentes instalados con npm o pip (Gemini, Claude
    /// de npm, Agy…): IA viva aunque no sepamos cuál.
    static let agentRuntimeCommands: Set<String> = ["node", "python3", "python", "bun", "deno"]
    /// Prefijo con el que Claude Code titula la ventana; identifica al agente, no su estado.
    static let claudeTitleMarker: Character = "✳"

    let agent: AgentActivity.Agent?
    /// `.working` cuando el título lleva el spinner braille; `nil` en cualquier otro caso.
    let state: AgentActivity.State?
    /// El proceso en primer plano es un shell: no hay IA en la ventana.
    let isShell: Bool
    /// El proceso en primer plano oculta el real (ssh, tmux…): la pantalla es la única pista.
    let hidesForegroundProcess: Bool
    /// El proceso en primer plano es un intérprete de agentes: hay IA viva sin nombre.
    let isAgentRuntime: Bool

    init(title: String?, currentCommand: String?) {
        let command = Self.normalizedCommand(currentCommand)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let command, Self.shellCommands.contains(command) {
            agent = nil
            state = nil
            isShell = true
            hidesForegroundProcess = false
            isAgentRuntime = false
            return
        }
        agent = Self.agent(fromCommand: command) ?? Self.agent(fromTitle: trimmedTitle)
        state = Self.startsWithBrailleSpinner(trimmedTitle) ? .working : nil
        isShell = false
        hidesForegroundProcess = command.map { Self.opaqueCommands.contains($0) } ?? true
        isAgentRuntime = command.map { Self.agentRuntimeCommands.contains($0) } ?? false
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
        if title.first == claudeTitleMarker {
            return .claude
        }
        let lowered = title.lowercased()
        if lowered.contains("claude") { return .claude }
        if lowered.contains("codex") { return .codex }
        if lowered.contains("gemini") { return .gemini }
        if lowered.contains("antigravity") || lowered.hasPrefix("agy") { return .agy }
        return nil
    }
}
