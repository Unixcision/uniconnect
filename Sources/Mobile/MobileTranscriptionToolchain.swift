import Foundation

/// Binarios que `transcribe.v1` necesita en este equipo.
///
/// La app no hereda el `PATH` del intérprete del usuario, así que se buscan en las rutas
/// habituales de Homebrew y del sistema. No se instala ni se descarga nada: lo que falte se
/// traduce en `unsupported` con el motivo, y el móvil vuelve a su dictado local.
struct MobileTranscriptionToolchain: Equatable, Sendable {
    /// `whisper-cli` (o el antiguo `whisper-cpp` / `main`).
    let whisperCLI: URL?
    /// `ffmpeg`, obligatorio para cualquier clip que no sea ya WAV PCM 16 kHz mono.
    let ffmpeg: URL?
    /// `ffprobe`, opcional: acota la duración antes de convertir.
    let ffprobe: URL?

    /// Carpetas donde se busca, en orden.
    static let defaultSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
    ]

    /// Nombres admitidos del motor, de más nuevo a más antiguo.
    static let whisperExecutableNames = ["whisper-cli", "whisper-cpp", "main"]

    /// Busca los binarios.
    ///
    /// - Parameters:
    ///   - searchPaths: Carpetas a recorrer; los tests pasan una temporal.
    ///   - fileManager: Sistema de archivos inyectado.
    static func resolve(
        searchPaths: [String] = MobileTranscriptionToolchain.defaultSearchPaths,
        fileManager: FileManager = .default
    ) -> MobileTranscriptionToolchain {
        MobileTranscriptionToolchain(
            whisperCLI: locate(whisperExecutableNames, in: searchPaths, fileManager: fileManager),
            ffmpeg: locate(["ffmpeg"], in: searchPaths, fileManager: fileManager),
            ffprobe: locate(["ffprobe"], in: searchPaths, fileManager: fileManager)
        )
    }

    private static func locate(_ names: [String], in searchPaths: [String], fileManager: FileManager) -> URL? {
        for name in names {
            for path in searchPaths {
                let candidate = URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
