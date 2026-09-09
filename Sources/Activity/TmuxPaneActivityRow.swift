import Foundation

/// Una línea de `tmux list-panes -a` con el formato de ``TmuxPaneActivityRow/formatArgument``.
struct TmuxPaneActivityRow: Equatable, Sendable {
    /// Formato que produce `sesión<TAB>comando<TAB>título<TAB>actividad` por panel.
    static let formatArgument = "#{session_name}\t#{pane_current_command}\t#{pane_title}\t#{window_activity}"

    let sessionName: String
    let currentCommand: String
    let title: String
    /// Epoch en segundos de `#{window_activity}`; `nil` si tmux no lo dio.
    let windowActivity: TimeInterval?

    init(sessionName: String, currentCommand: String, title: String, windowActivity: TimeInterval?) {
        self.sessionName = sessionName
        self.currentCommand = currentCommand
        self.title = title
        self.windowActivity = windowActivity
    }

    /// Parsea la salida completa de la sonda; ignora líneas malformadas.
    static func parse(_ output: String) -> [TmuxPaneActivityRow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return nil }
            let sessionName = String(fields[0]).trimmingCharacters(in: .whitespaces)
            guard !sessionName.isEmpty else { return nil }
            let activity = fields.count > 3
                ? TimeInterval(String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            return TmuxPaneActivityRow(
                sessionName: sessionName,
                currentCommand: String(fields[1]).trimmingCharacters(in: .whitespaces),
                title: String(fields[2]).trimmingCharacters(in: .whitespaces),
                windowActivity: activity
            )
        }
    }

    /// Una fila por sesión: la de actividad más reciente cuando hay varios paneles.
    static func latestBySession(_ rows: [TmuxPaneActivityRow]) -> [String: TmuxPaneActivityRow] {
        var result: [String: TmuxPaneActivityRow] = [:]
        for row in rows {
            guard let existing = result[row.sessionName] else {
                result[row.sessionName] = row
                continue
            }
            if (row.windowActivity ?? 0) > (existing.windowActivity ?? 0) {
                result[row.sessionName] = row
            }
        }
        return result
    }
}
