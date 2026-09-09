import Foundation

/// Nombre de archivo saneado para `file_put.v1`: sin rutas, sin caracteres raros, con
/// longitud acotada y con la extensión conservada; `candidate(_:)` produce los nombres
/// con sufijo `-2`, `-3`… que evitan pisar un archivo existente.
struct MobileFilePutName: Equatable, Sendable {
    /// Longitud máxima del nombre completo en bytes UTF-8.
    static let maximumUTF8Bytes = 120
    /// Longitud máxima de la extensión (sin el punto).
    static let maximumExtensionLength = 16
    /// Nombre cuando el móvil no manda nada usable.
    static let fallbackStem = "archivo"

    /// Nombre sin extensión.
    let stem: String
    /// Extensión con el punto (`.jpg`) o cadena vacía.
    let ext: String

    init(rawName: String) {
        let sanitized = Self.sanitize(rawName)
        let (stem, ext) = Self.split(sanitized)
        self.stem = stem
        self.ext = ext
    }

    /// Nombre completo sin sufijo.
    var fileName: String { stem + ext }

    /// `stem.ext` para el ordinal 1 y `stem-n.ext` a partir del 2.
    func candidate(_ ordinal: Int) -> String {
        ordinal <= 1 ? fileName : "\(stem)-\(ordinal)\(ext)"
    }

    /// Quita rutas, caracteres de control y símbolos peligrosos para el shell; nunca devuelve vacío.
    static func sanitize(_ raw: String) -> String {
        let lastComponent = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        let forbidden: Set<Character> = [
            "/", "\\", ":", "*", "?", "\"", "<", ">", "|", "'", "`", "$", ";", "&", "\0",
        ]
        var cleaned = String(lastComponent.trimmingCharacters(in: .whitespacesAndNewlines).map { character -> Character in
            if forbidden.contains(character) || character.isWhitespace { return "_" }
            if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "_" }
            return character
        })
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "_" }) {
            cleaned = fallbackStem
        }
        return cleaned
    }

    private static func split(_ name: String) -> (stem: String, ext: String) {
        var stem = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let candidate = String(name[name.index(after: dot)...])
            if !candidate.isEmpty, candidate.count <= maximumExtensionLength,
               candidate.allSatisfy({ $0.isLetter || $0.isNumber }) {
                stem = String(name[..<dot])
                ext = "." + candidate
            }
        }
        while (stem + ext).utf8.count > maximumUTF8Bytes, stem.count > 1 {
            stem.removeLast()
        }
        if stem.isEmpty { stem = fallbackStem }
        return (stem, ext)
    }
}
