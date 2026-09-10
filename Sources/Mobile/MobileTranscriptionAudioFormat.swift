import Foundation

/// Formatos de audio que acepta `transcribe.v1`.
///
/// El MIME solo decide la extensión del archivo temporal, que es una pista para `ffmpeg`.
/// Ni la duración ni el formato real se deducen de él: se miden sobre el audio decodificado.
enum MobileTranscriptionAudioFormat: String, CaseIterable, Equatable, Sendable {
    /// `audio/mp4`: lo que graba Android con AAC en contenedor MPEG-4.
    case mp4 = "audio/mp4"
    /// `audio/ogg`: contenedor Ogg, normalmente con Opus.
    case ogg = "audio/ogg"
    /// `audio/wav`: PCM sin comprimir; el único que whisper.cpp lee sin convertir.
    case wav = "audio/wav"

    /// Extensión del archivo temporal en el que se escribe el clip.
    var fileExtension: String {
        switch self {
        case .mp4: return "m4a"
        case .ogg: return "ogg"
        case .wav: return "wav"
        }
    }

    /// Reconoce el MIME sin distinguir mayúsculas y descartando parámetros
    /// (`audio/mp4; codecs=mp4a.40.2`), además de los alias habituales del móvil.
    ///
    /// - Parameter raw: Valor del campo `mime` de la petición.
    /// - Returns: El formato, o `nil` si no está admitido.
    static func parse(_ raw: String?) -> MobileTranscriptionAudioFormat? {
        guard let raw else { return nil }
        let base = raw
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? raw
        let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = MobileTranscriptionAudioFormat(rawValue: normalized) {
            return exact
        }
        switch normalized {
        case "audio/m4a", "audio/x-m4a", "audio/aac", "audio/mp4a-latm":
            return .mp4
        case "audio/opus", "audio/ogg; codecs=opus":
            return .ogg
        case "audio/x-wav", "audio/wave", "audio/vnd.wave":
            return .wav
        default:
            return nil
        }
    }
}
