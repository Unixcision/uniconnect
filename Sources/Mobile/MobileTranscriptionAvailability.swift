import Foundation

/// Si este equipo puede anunciar `transcribe.v1`, con memoria corta.
///
/// La lista de capacidades se calcula en cada `mobile.workspace.list`, que el móvil pide a
/// menudo, así que la respuesta se guarda un rato en vez de recorrer el disco cada vez. El
/// rato es corto a propósito: quien deje un modelo nuevo en la carpeta no tiene que reiniciar
/// UniConnect para que el móvil deje de dictar en local.
struct MobileTranscriptionAvailability: Sendable {
    /// Cuánto vale una respuesta antes de volver a mirar el disco.
    static let defaultLifetime: Duration = .seconds(60)

    private let lifetime: Duration
    private let probe: @Sendable () -> Bool
    private var checkedAt: ContinuousClock.Instant?
    private var lastAnswer = false

    /// - Parameters:
    ///   - lifetime: Validez de la respuesta guardada.
    ///   - probe: Comprobación real; los tests pasan una que no toca el disco.
    init(
        lifetime: Duration = MobileTranscriptionAvailability.defaultLifetime,
        probe: @escaping @Sendable () -> Bool = { MobileTranscriptionAvailability.canTranscribe() }
    ) {
        self.lifetime = lifetime
        self.probe = probe
    }

    /// Responde si hay motor y modelo, mirando el disco solo cuando la respuesta ha caducado.
    ///
    /// - Parameter now: Instante actual; los tests lo mueven a mano.
    /// - Returns: `true` si `transcribe.v1` se puede anunciar.
    mutating func isAvailable(now: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        if let checkedAt, now - checkedAt < lifetime {
            return lastAnswer
        }
        lastAnswer = probe()
        checkedAt = now
        return lastAnswer
    }

    /// Comprobación real: hacen falta el motor, el conversor y al menos un modelo instalado.
    ///
    /// El conversor cuenta tanto como el motor. Lo que graba el móvil es AAC en contenedor
    /// MPEG-4, que whisper.cpp no lee, así que sin `ffmpeg` el equipo anunciaría la capacidad y
    /// fallaría en el primer dictado, justo cuando el usuario ya ha hablado. Es mejor no
    /// anunciarla y que el móvil dicte en local desde el principio.
    ///
    /// - Returns: `true` si `transcribe.v1` puede funcionar en este equipo.
    static func canTranscribe() -> Bool {
        let toolchain = MobileTranscriptionToolchain.resolve()
        guard toolchain.whisperCLI != nil, toolchain.ffmpeg != nil else { return false }
        return MobileWhisperModelCatalog().preferredModel() != nil
    }
}
