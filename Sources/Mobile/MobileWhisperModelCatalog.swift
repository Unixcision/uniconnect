import Foundation

/// Modelos de whisper.cpp instalados en la carpeta de UniConnect.
///
/// La carpeta es `~/Library/Application Support/UniConnect/whisper` y el host nunca descarga
/// nada: si está vacía, `transcribe.v1` responde `unsupported` y el móvil dicta en local.
/// La elección es determinista y prefiere los modelos rápidos de este Mac; `large` sin
/// cuantizar queda el último de los conocidos porque es el que puede agotar el presupuesto.
struct MobileWhisperModelCatalog: Sendable {
    /// Orden de preferencia por trozo del nombre, de mejor a peor para dictado corto.
    static let preferenceOrder = [
        "large-v3-turbo",
        "turbo",
        "medium",
        "small",
        "base",
        "tiny",
        "large",
    ]

    /// Carpeta por defecto de los modelos.
    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("UniConnect", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
    }

    private let directory: URL
    // FileManager es seguro entre hilos según Apple para estas operaciones, y aquí solo
    // se lee de él; guardarlo no hace insegura la copia del valor entre tareas.
    private nonisolated(unsafe) let fileManager: FileManager

    /// - Parameters:
    ///   - directory: Carpeta de modelos; los tests pasan una temporal.
    ///   - fileManager: Sistema de archivos inyectado.
    init(directory: URL = MobileWhisperModelCatalog.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Modelo elegido, o `nil` si la carpeta no tiene ningún `.bin`.
    func preferredModel() -> URL? {
        Self.choose(from: installedModelNames()).map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    /// Nombres de los `.bin` presentes, ordenados alfabéticamente para que la elección no
    /// dependa del orden del sistema de archivos.
    func installedModelNames() -> [String] {
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries
            .filter { $0.lowercased().hasSuffix(".bin") && !$0.hasPrefix(".") }
            .sorted()
    }

    /// Aplica el orden de preferencia sobre una lista de nombres ya ordenada.
    ///
    /// - Parameter names: Nombres de archivo (no rutas).
    /// - Returns: El nombre elegido, o `nil` si la lista está vacía.
    static func choose(from names: [String]) -> String? {
        names.min { left, right in
            let leftRank = rank(of: left)
            let rightRank = rank(of: right)
            if leftRank != rightRank { return leftRank < rightRank }
            return left < right
        }
    }

    /// Posición en ``preferenceOrder``; un nombre desconocido va después de todos los conocidos.
    private static func rank(of name: String) -> Int {
        let lowered = name.lowercased()
        for (index, needle) in preferenceOrder.enumerated() where lowered.contains(needle) {
            return index
        }
        return preferenceOrder.count
    }
}
