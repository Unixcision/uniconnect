import Foundation

/// Detecta en las últimas líneas visibles una pregunta de permiso pendiente.
///
/// Se consulta solo con la salida en calma: una IA que pide permiso deja de escribir y
/// la pregunta queda al pie de la pantalla. El texto capturado no sale de aquí: el
/// resto del ciclo solo ve el veredicto.
struct AgentActivityScreenSignal: Equatable, Sendable {
    /// Líneas del pie de pantalla que se inspeccionan.
    static let defaultLineWindow = 12
    /// Fragmentos (en minúsculas) que por sí solos delatan una pregunta de permiso.
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
        "would you like to run",
        "allow command",
        "approve this command",
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

    /// Las dos expresiones de ``stripANSI(_:)``, compiladas una vez: compilarlas en cada
    /// lectura de pantalla era parte del coste del ciclo de actividad.
    private static let ansiExpressions: [NSRegularExpression] = [
        "\u{1B}\\[[0-?]*[ -/]*[@-~]",
        "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Elimina secuencias CSI y OSC por si el texto llega con códigos de control.
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = text
        for regex in ansiExpressions {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    /// Últimas `count` líneas no vacías, recorriendo el texto desde el final: solo se tocan
    /// las líneas del pie, no la pantalla entera.
    static func tailLines(_ text: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        var lines: [String] = []
        var end = text.endIndex
        while lines.count < count {
            let start = text[..<end].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let line = text[start..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
            guard start > text.startIndex else { break }
            end = text.index(before: start)
        }
        return lines.reversed()
    }

    private static func matchesWaitingPattern(_ loweredTail: String) -> Bool {
        if waitingPatterns.contains(where: { loweredTail.contains($0) }) {
            return true
        }
        // Codex: «Allow …» o «Approve …» junto a la respuesta «[y/n]».
        let asksYesNo = loweredTail.contains("[y/n]") || loweredTail.contains("(y/n)")
        return asksYesNo && (loweredTail.contains("allow") || loweredTail.contains("approve"))
    }
}
