import Foundation

/// Respuesta de `mobile.audio.transcribe`.
struct MobileTranscriptionOutcome: Equatable, Sendable {
    /// Una sola línea de dictado: sin marcas de tiempo ni anotaciones entre corchetes.
    let text: String
    /// Motor y modelo, sin rutas del equipo (`whisper.cpp/ggml-large-v3-turbo-q5_0.bin`).
    let engine: String
    /// Duración medida del audio, en segundos.
    let seconds: Double
    /// Lo que tardó el host en responder, en milisegundos.
    let tookMs: Int
}
