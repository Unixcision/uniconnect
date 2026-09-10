import Foundation

/// Petición de `mobile.audio.transcribe` ya validada: audio decodificado, formato reconocido
/// e idioma admitido. Solo ``MobileTranscriptionLimits`` la construye.
struct MobileTranscriptionRequest: Equatable, Sendable {
    /// Clip completo en binario.
    let audio: Data
    /// Formato declarado, usado únicamente para nombrar el temporal.
    let format: MobileTranscriptionAudioFormat
    /// `"es"`, `"en"` o `nil` para detección automática.
    let language: String?
    /// Dispositivo que llama (dirección aprobada del tailnet); limita la concurrencia.
    let device: String?
}
