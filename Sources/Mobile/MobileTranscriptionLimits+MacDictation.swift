import Foundation

extension MobileTranscriptionLimits {
    /// Límites del botón de dictado del Mac.
    ///
    /// El clip no viaja por el canal móvil, así que no hay trama que respetar y la grabación
    /// puede durar 15 minutos:
    /// - 16 MiB: 15 minutos de AAC a 32 kbit/s ocupan unos 3,6 MB; sobra margen.
    /// - 900 s: lo que deja grabar el botón antes de parar solo.
    /// - 420 s de presupuesto: whisper large-v3-turbo lee 15 minutos en bastante menos, aun con
    ///   el Mac cargado de IAs.
    /// - Dos a la vez: un dictado nuevo y un «Volver a transcribir» no se estorban.
    static let macDictation = MobileTranscriptionLimits(
        maximumAudioBytes: 16 * 1_048_576,
        maximumSeconds: 900,
        budget: .seconds(420),
        cleanupMargin: .seconds(5),
        perDeviceLimit: 2,
        totalLimit: 2
    )
}
