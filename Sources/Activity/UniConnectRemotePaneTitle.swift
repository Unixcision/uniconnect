import Foundation

/// Título `comando|título` que propaga el tmux remoto de UniConnect
/// (`set-titles-string '#{pane_current_command}|#{pane_title}'`, ver `UniConnectSSH`).
///
/// El Mac no ve el proceso remoto, así que el comando viaja en el título OSC: la parte
/// anterior a la barra alimenta el agente de la actividad y la posterior es lo único
/// que se enseña en la barra lateral y en la pestaña. Un título sin barra, o cuya
/// primera parte no parece un nombre de comando, se deja intacto.
struct UniConnectRemotePaneTitle: Equatable, Sendable {
    /// Longitud máxima razonable de un nombre de proceso (`pane_current_command`).
    static let maximumCommandLength = 64

    /// `pane_current_command` remoto, o `nil` si el título no lleva prefijo.
    let command: String?
    /// `pane_title` remoto (puede quedar vacío) o el título completo si no hay prefijo.
    let title: String

    init(rawTitle: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "|"),
              Self.isCommandToken(trimmed[..<separator]) else {
            command = nil
            title = trimmed
            return
        }
        command = String(trimmed[..<separator])
        title = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lo que ven barra lateral y pestaña: nunca el prefijo con la barra vertical.
    var displayTitle: String {
        title.isEmpty ? (command ?? "") : title
    }

    /// Un nombre de proceso: letras, dígitos y `. _ + -`, sin espacios ni barras.
    static func isCommandToken(_ value: Substring) -> Bool {
        guard !value.isEmpty, value.count <= maximumCommandLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar == "." || scalar == "_" || scalar == "+" || scalar == "-"
        }
    }
}
