import Foundation

/// Orden de `ffprobe` que mide la duración de un clip comprimido, y lectura de su salida.
///
/// Sirve para responder `too_large` antes de gastar un segundo de conversión o de motor: un
/// clip de una hora recomprimido a 3 MiB cabe de sobra en el límite de tamaño, y solo su
/// duración medida lo delata.
struct MobileAudioProbeCommand: Equatable, Sendable {
    /// Ruta del clip a medir.
    let input: URL

    /// - Parameter input: Archivo temporal con el audio tal y como llegó del móvil.
    init(input: URL) {
        self.input = input
    }

    /// Argumentos de `ffprobe`, que imprime la duración en segundos y nada más.
    var arguments: [String] {
        [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            input.path,
        ]
    }

    /// Interpreta la salida estándar de `ffprobe`.
    ///
    /// - Parameter output: Salida estándar completa del proceso.
    /// - Returns: La duración en segundos, o `nil` si `ffprobe` no supo medirla (`N/A`, vacío).
    static func seconds(from output: String) -> Double? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let value = Double(trimmed), value.isFinite, value >= 0 else { continue }
            return value
        }
        return nil
    }
}
