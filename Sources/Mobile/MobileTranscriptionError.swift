import Foundation

/// Fallos de `transcribe.v1`, con el código del contrato y un mensaje en español.
///
/// Ningún mensaje lleva el audio, el texto transcrito ni rutas del equipo: el móvil los
/// enseña tal cual y `unsupported` es además la señal para volver a su dictado local.
enum MobileTranscriptionError: Error, Equatable, Sendable {
    /// Base64, MIME, idioma o contexto mal formados.
    case invalidParams(String)
    /// Más de 3 MiB o más de 5 minutos, medidos sobre el audio decodificado.
    case tooLarge
    /// No hay motor, no hay modelo o falta el conversor para un clip comprimido.
    case unsupported(String)
    /// Ya hay una transcripción de este dispositivo, o dos en total, en marcha.
    case busy
    /// El motor falló, se agotó el presupuesto o no se pudo preparar el audio.
    case ioFailed(String)

    /// Código del contrato móvil.
    var code: String {
        switch self {
        case .invalidParams: return "invalid_params"
        case .tooLarge: return "too_large"
        case .unsupported: return "unsupported"
        case .busy: return "busy"
        case .ioFailed: return "io_failed"
        }
    }

    /// Texto legible que viaja al móvil.
    var message: String {
        switch self {
        case let .invalidParams(message), let .unsupported(message), let .ioFailed(message):
            return message
        case .tooLarge:
            return String(
                localized: "uniconnect.mobile.transcribe.tooLarge",
                defaultValue: "El audio supera el máximo admitido (3 MiB o 5 minutos)."
            )
        case .busy:
            return String(
                localized: "uniconnect.mobile.transcribe.busy",
                defaultValue: "El equipo ya está transcribiendo otro audio; inténtalo en unos segundos."
            )
        }
    }
}
