import Foundation

/// Detecta en las últimas líneas visibles una pregunta de permiso pendiente.
///
/// Solo se consulta cuando la salida está en calma: una IA que pide permiso deja de
/// escribir y la pregunta queda al pie de la pantalla.
struct AgentActivityScreenSignal: Equatable, Sendable {
    /// Líneas del pie de pantalla que se inspeccionan.
    static let defaultLineWindow = 12
    /// Fragmentos (en minúsculas) que delatan una pregunta de permiso.
    static let waitingPatterns: [String] = [
        // Claude Code
        "do you want to proceed",
        "❯ 1. yes",
        "esc to cancel",
        "do you want to make this edit",
        "do you want to create",
        "do you want to run",
        // Gemini CLI y Agy
        "allow execution",
        "apply this change",
        "allow once",
        "allow always",
        // Codex
        "approve",
        "would you like to run",
    ]

    /// Hay una pregunta de permiso visible.
    let isWaitingForUser: Bool

    init(visibleText: String?, lineWindow: Int = AgentActivityScreenSignal.defaultLineWindow) {
        guard let visibleText, !visibleText.isEmpty else {
            isWaitingForUser = false
            return
        }
        let tail = Self.tailLines(Self.stripANSI(visibleText), count: lineWindow)
            .joined(separator: "\n")
            .lowercased()
        isWaitingForUser = Self.matchesWaitingPattern(tail)
    }

    /// Elimina secuencias CSI y OSC por si el texto llega con códigos de control.
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let patterns = [
            "\u{1B}\\[[0-?]*[ -/]*[@-~]",
            "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
        ]
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    /// Últimas `count` líneas no vacías.
    static func tailLines(_ text: String, count: Int) -> [String] {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(max(count, 0)))
    }

    private static func matchesWaitingPattern(_ loweredTail: String) -> Bool {
        if waitingPatterns.contains(where: { loweredTail.contains($0) }) {
            return true
        }
        // Codex: «Allow …» junto a la respuesta «[y/n]».
        return loweredTail.contains("[y/n]") && loweredTail.contains("allow")
    }
}
