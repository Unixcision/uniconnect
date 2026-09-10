import Foundation

/// Lo que dejó un proceso hijo de la transcripción (`ffprobe`, `ffmpeg` o `whisper-cli`).
struct MobileTranscriptionProcessResult: Equatable, Sendable {
    /// Código de salida.
    let exitStatus: Int32
    /// Salida estándar completa.
    let standardOutput: Data
    /// Salida de error completa; se usa para decidir, nunca se reenvía al móvil.
    let standardError: Data

    /// `true` si el proceso terminó bien.
    var didSucceed: Bool { exitStatus == 0 }

    /// Salida estándar como texto.
    var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }
}
