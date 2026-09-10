import Foundation

/// Orden de `whisper-cli` para un dictado corto.
///
/// `-nt` quita las marcas de tiempo y `-np` los mensajes de progreso, así que la salida
/// estándar queda solo con el texto; el resto de la charla del motor se va por la salida de
/// error y nunca llega al móvil.
struct MobileWhisperCLICommand: Equatable, Sendable {
    /// Tope de hilos: por encima, whisper deja de escalar y se come el equipo entero.
    static let maximumThreads = 8

    /// Modelo `.bin` elegido.
    let model: URL
    /// WAV ya en el formato que whisper lee.
    let audio: URL
    /// `"es"`, `"en"` o `nil` para detección automática.
    let language: String?
    /// Hilos del motor.
    let threads: Int

    /// - Parameters:
    ///   - model: Modelo elegido por ``MobileWhisperModelCatalog``.
    ///   - audio: WAV PCM de 16 bits, mono y 16 kHz.
    ///   - language: Idioma pedido, ya validado.
    ///   - threads: Hilos; usa ``threadCount(cores:)`` para derivarlo del equipo.
    init(model: URL, audio: URL, language: String?, threads: Int) {
        self.model = model
        self.audio = audio
        self.language = language
        self.threads = threads
    }

    /// Argumentos de `whisper-cli`.
    var arguments: [String] {
        [
            "-m", model.path,
            "-f", audio.path,
            "-l", language ?? "auto",
            "-t", String(threads),
            "-nt",
            "-np",
        ]
    }

    /// Hilos a pedir en un equipo con `cores` núcleos.
    ///
    /// Se deja uno libre para que el escritorio siga respondiendo mientras se dicta, y el
    /// resultado se acota a ``maximumThreads``.
    ///
    /// - Parameter cores: Núcleos activos del equipo.
    /// - Returns: Un número de hilos entre 1 y ``maximumThreads``.
    static func threadCount(cores: Int) -> Int {
        min(max(cores - 1, 1), maximumThreads)
    }
}
