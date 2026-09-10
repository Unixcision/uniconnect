import Foundation

/// Salida cruda de whisper.cpp convertida en una línea de dictado.
///
/// whisper intercala anotaciones de no-habla entre corchetes (`[BLANK_AUDIO]`, `[Music]`,
/// `[_TT_320]`…) que no son texto dictado y que el móvil no debe pegar en el compositor.
/// El filtro se limita a esa lista conocida: quitar cualquier cosa entre corchetes borraría
/// `[pendiente]`, `[por confirmar]` o cualquier otra línea que el usuario haya dictado de
/// verdad, y perder texto del usuario es mucho peor que dejar pasar un marcador raro.
struct MobileWhisperTranscript: Equatable, Sendable {
    /// Nombres de marcador conocidos, comparados sin distinguir mayúsculas.
    static let knownMarkers: Set<String> = [
        "blank_audio",
        "silence",
        "music",
        "applause",
        "laughter",
        "noise",
        "sound",
        "inaudible",
        "no_speech",
        "speaker_change",
    ]

    /// Prefijos de marcador interno de whisper (`[_TT_320]`, `[_BEG_]`, `[_SOT_]`…).
    static let knownMarkerPrefixes = ["_tt_", "_beg_", "_sot_", "_eot_", "_solm_", "_not_", "_lang_"]

    /// Texto tal y como lo escribió el motor en su salida estándar.
    let raw: String

    /// - Parameter raw: Salida estándar completa de whisper.cpp.
    init(raw: String) {
        self.raw = raw
    }

    /// Una sola línea de dictado, sin marcadores de no-habla ni espacios sobrantes.
    ///
    /// Las líneas se unen con un espacio porque whisper parte el dictado en segmentos, no en
    /// párrafos: lo que llega al compositor del móvil es una frase seguida.
    var text: String {
        raw
            .split(whereSeparator: \.isNewline)
            .map { Self.stripMarkers(from: String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reconoce un marcador por su contenido, ya sin los corchetes.
    ///
    /// - Parameter inner: Texto entre corchetes, por ejemplo `BLANK_AUDIO` o `_TT_320`.
    /// - Returns: `true` solo para los marcadores de whisper; `pendiente` devuelve `false`.
    static func isMarker(inner: String) -> Bool {
        let normalized = inner
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        guard !normalized.isEmpty else { return false }
        if knownMarkers.contains(normalized) { return true }
        return knownMarkerPrefixes.contains { normalized.hasPrefix($0) }
    }

    /// Quita de una línea los marcadores conocidos y colapsa los espacios que dejan.
    ///
    /// Un corchete sin cerrar se deja tal cual: es texto dictado, no un marcador a medias.
    private static func stripMarkers(from line: String) -> String {
        var kept = ""
        var pending = ""
        var isInsideBrackets = false
        for character in line {
            if isInsideBrackets {
                if character == "]" {
                    isInsideBrackets = false
                    if !isMarker(inner: pending) {
                        kept.append("[")
                        kept.append(contentsOf: pending)
                        kept.append("]")
                    }
                    pending = ""
                } else if character == "[" {
                    // Un corchete anidado prueba que el anterior no delimitaba un marcador.
                    kept.append("[")
                    kept.append(contentsOf: pending)
                    pending = ""
                } else {
                    pending.append(character)
                }
                continue
            }
            if character == "[" {
                isInsideBrackets = true
            } else {
                kept.append(character)
            }
        }
        if isInsideBrackets {
            kept.append("[")
            kept.append(contentsOf: pending)
        }
        return kept
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
