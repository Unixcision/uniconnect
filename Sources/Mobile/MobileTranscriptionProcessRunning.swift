import Foundation

/// Costura de proceso de la transcripción.
///
/// El servicio habla siempre con este protocolo, nunca con `Process`, para que los tests
/// puedan comprobar qué órdenes se construyen y cómo se traduce cada fallo del motor sin
/// lanzar `ffmpeg` ni `whisper-cli`.
protocol MobileTranscriptionProcessRunning: Sendable {
    /// Ejecuta un programa y espera a que termine.
    ///
    /// - Parameters:
    ///   - executable: Ruta absoluta del binario.
    ///   - arguments: Argumentos completos.
    /// - Returns: Código de salida y las dos salidas completas.
    /// - Throws: `CancellationError` si la tarea se cancela, o el error de arranque.
    func run(executable: URL, arguments: [String]) async throws -> MobileTranscriptionProcessResult
}
