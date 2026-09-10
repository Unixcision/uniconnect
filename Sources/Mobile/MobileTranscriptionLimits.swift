import Foundation

/// Límites de `transcribe.v1` y validación de la petición.
///
/// El tope de 3 MiB no es estético: la trama del canal móvil admite 8 MiB y el base64 crece
/// un tercio, así que 3 MiB binarios (4 MiB en base64) dejan sitio al resto del JSON; con
/// 6 MiB la petición no cabría en la trama y el móvil ni siquiera recibiría `too_large`.
/// Los tests construyen unos límites pequeños para no manejar megabytes.
struct MobileTranscriptionLimits: Equatable, Sendable {
    /// Bytes binarios máximos del clip.
    let maximumAudioBytes: Int
    /// Duración máxima en segundos, verificada sobre el audio decodificado.
    let maximumSeconds: Double
    /// Presupuesto único y monotónico de toda la llamada (sondeo, conversión, motor y limpieza).
    let budget: Duration
    /// Parte del presupuesto que se reserva para borrar los temporales.
    let cleanupMargin: Duration
    /// Transcripciones simultáneas por dispositivo.
    let perDeviceLimit: Int
    /// Transcripciones simultáneas en total.
    let totalLimit: Int

    /// - Parameters:
    ///   - maximumAudioBytes: 3 MiB por defecto, por el motivo explicado arriba.
    ///   - maximumSeconds: 300 s; esto es dictado, no un servicio de grabación.
    ///   - budget: 75 s contados desde la entrada de la RPC; el móvil espera 90 s desde antes
    ///     de enviar, así que el host responde siempre antes de que se rinda.
    ///   - cleanupMargin: 5 s finales reservados a matar al hijo y borrar los temporales.
    ///   - perDeviceLimit: 1 transcripción viva por móvil.
    ///   - totalLimit: 2 transcripciones vivas en el equipo.
    init(
        maximumAudioBytes: Int = 3 * 1_048_576,
        maximumSeconds: Double = 300,
        budget: Duration = .seconds(75),
        cleanupMargin: Duration = .seconds(5),
        perDeviceLimit: Int = 1,
        totalLimit: Int = 2
    ) {
        self.maximumAudioBytes = maximumAudioBytes
        self.maximumSeconds = maximumSeconds
        self.budget = budget
        self.cleanupMargin = cleanupMargin
        self.perDeviceLimit = perDeviceLimit
        self.totalLimit = totalLimit
    }

    /// Caracteres base64 que se aceptan antes de decodificar nada, para no reservar memoria
    /// por un clip que ya se sabe demasiado grande. Incluye holgura para el relleno final.
    var maximumBase64Characters: Int {
        ((maximumAudioBytes + 2) / 3) * 4 + 4
    }

    /// Presupuesto disponible para trabajo real, ya descontada la limpieza.
    var workingBudget: Duration {
        budget - cleanupMargin
    }

    /// Valida los parámetros de la petición y decodifica el audio.
    ///
    /// - Parameters:
    ///   - base64: Campo `audio`.
    ///   - mime: Campo `mime`.
    ///   - language: Campo `language` (`"es"`, `"en"`, vacío o ausente).
    ///   - device: Dirección aprobada del móvil que llama.
    /// - Returns: La petición validada.
    /// - Throws: ``MobileTranscriptionError/invalidParams(_:)`` o ``MobileTranscriptionError/tooLarge``.
    func validate(
        base64: String?,
        mime: String?,
        language: String?,
        device: String?
    ) throws -> MobileTranscriptionRequest {
        guard let format = MobileTranscriptionAudioFormat.parse(mime) else {
            throw MobileTranscriptionError.invalidParams(
                String(
                    localized: "uniconnect.mobile.transcribe.invalidMime",
                    defaultValue: "Indica un formato de audio admitido: audio/mp4, audio/ogg o audio/wav."
                )
            )
        }
        let normalizedLanguage = try Self.normalizeLanguage(language)
        guard let base64, !base64.isEmpty else {
            throw MobileTranscriptionError.invalidParams(Self.invalidAudioMessage)
        }
        let compact = base64.filter { !$0.isWhitespace }
        guard compact.count <= maximumBase64Characters else {
            throw MobileTranscriptionError.tooLarge
        }
        guard let audio = Self.decode(compact), !audio.isEmpty else {
            throw MobileTranscriptionError.invalidParams(Self.invalidAudioMessage)
        }
        guard audio.count <= maximumAudioBytes else {
            throw MobileTranscriptionError.tooLarge
        }
        return MobileTranscriptionRequest(
            audio: audio,
            format: format,
            language: normalizedLanguage,
            device: device
        )
    }

    /// Comprueba la duración medida del audio.
    ///
    /// - Parameter seconds: Duración leída del audio decodificado, nunca deducida del MIME.
    /// - Throws: ``MobileTranscriptionError/tooLarge`` si pasa de ``maximumSeconds``.
    func verify(seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw MobileTranscriptionError.invalidParams(Self.invalidAudioMessage)
        }
        guard seconds <= maximumSeconds else {
            throw MobileTranscriptionError.tooLarge
        }
    }

    /// Decodifica base64 estricto.
    ///
    /// Se toleran los saltos de línea (los quita quien llama) y nada más: decodificar con
    /// `ignoreUnknownCharacters` haría pasar por audio una cadena con basura dentro, que se
    /// convertiría en un fallo del motor mucho más adelante en vez de en `invalid_params`.
    ///
    /// - Parameter compact: Base64 ya sin espacios.
    /// - Returns: Los bytes, o `nil` si la cadena no es base64 válido.
    private static func decode(_ compact: String) -> Data? {
        guard !compact.isEmpty, compact.count % 4 == 0 else { return nil }
        return Data(base64Encoded: compact)
    }

    private static var invalidAudioMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.invalidAudio",
            defaultValue: "El audio no llegó en base64 válido."
        )
    }

    /// Acepta `es`, `en`, sus variantes regionales (`es-ES`) y el vacío como automático.
    private static func normalizeLanguage(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "auto" { return nil }
        let base = trimmed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? trimmed
        guard base == "es" || base == "en" else {
            throw MobileTranscriptionError.invalidParams(
                String(
                    localized: "uniconnect.mobile.transcribe.invalidLanguage",
                    defaultValue: "El idioma debe ser «es», «en» o quedar vacío."
                )
            )
        }
        return base
    }
}
