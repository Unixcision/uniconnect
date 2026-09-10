import Foundation

/// Carpeta privada donde vive el audio de un dictado mientras se transcribe.
///
/// Cada llamada usa su propio directorio 0700 llamado `<pid>-<identificador>`, dentro de la
/// caché de UniConnect, y el clip se escribe con `O_EXCL|O_NOFOLLOW` y modo 0600. El
/// directorio se borra en todas las salidas: acierto, fallo del motor, plazo agotado y
/// cancelación. Lo que deje un cierre a la fuerza lo recoge ``sweepOrphans()`` al arrancar.
struct MobileTranscriptionWorkspace: Sendable {
    /// Carpeta por defecto: `~/Library/Caches/UniConnect/transcribe`.
    static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent("UniConnect", isDirectory: true)
            .appendingPathComponent("transcribe", isDirectory: true)
    }

    /// Carpeta que contiene los directorios de trabajo.
    let root: URL
    // FileManager es seguro entre hilos según Apple para estas operaciones, y aquí solo
    // se lee de él; guardarlo no hace insegura la copia del valor entre tareas.
    private nonisolated(unsafe) let fileManager: FileManager
    private let processIdentifier: pid_t

    /// - Parameters:
    ///   - root: Carpeta contenedora; los tests pasan una temporal.
    ///   - fileManager: Sistema de archivos inyectado.
    ///   - processIdentifier: Proceso dueño de los directorios que se creen aquí.
    init(
        root: URL = MobileTranscriptionWorkspace.defaultRoot,
        fileManager: FileManager = .default,
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.root = root
        self.fileManager = fileManager
        self.processIdentifier = processIdentifier
    }

    /// Crea el directorio de esta llamada.
    ///
    /// - Returns: El directorio recién creado, con permisos 0700.
    /// - Throws: El error del sistema de archivos si no se pudo crear.
    func makeCallDirectory() throws -> URL {
        let name = "\(processIdentifier)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    /// Escribe el clip recibido sin seguir enlaces y sin pisar nada.
    ///
    /// - Parameters:
    ///   - data: Audio decodificado.
    ///   - url: Destino dentro del directorio de la llamada.
    /// - Throws: ``MobileTranscriptionError/ioFailed(_:)`` si el archivo no se pudo crear.
    func write(_ data: Data, to url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw MobileTranscriptionError.ioFailed(Self.ioFailedMessage)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw MobileTranscriptionError.ioFailed(Self.ioFailedMessage)
        }
    }

    /// Borra el directorio de una llamada, verificando que ya no está.
    ///
    /// `removeItem` puede fallar dejando el audio en el disco, así que se comprueba y se
    /// reintenta reabriendo los permisos antes de darlo por perdido.
    ///
    /// - Parameter directory: Directorio devuelto por ``makeCallDirectory()``.
    /// - Returns: `true` si ya no queda nada en el disco.
    @discardableResult
    func remove(_ directory: URL) -> Bool {
        try? fileManager.removeItem(at: directory)
        guard fileManager.fileExists(atPath: directory.path) else { return true }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? fileManager.removeItem(at: directory)
        return !fileManager.fileExists(atPath: directory.path)
    }

    /// Borra los directorios de trabajo cuyo proceso dueño ya no existe.
    ///
    /// La edad no prueba nada (un equipo suspendido o un dictado largo dejan directorios
    /// viejos con dueño vivo), así que la prueba es el propio proceso: un `pid` que ya no
    /// responde es un directorio abandonado. Un nombre que no siga ese patrón es de otro y se
    /// queda donde está, que en este equipo pueden convivir dos UniConnect.
    func sweepOrphans() {
        let entries = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries {
            guard let owner = Self.owner(ofDirectoryNamed: entry), !Self.isAlive(owner) else { continue }
            try? fileManager.removeItem(at: root.appendingPathComponent(entry, isDirectory: true))
        }
    }

    /// Extrae el `pid` del nombre de un directorio de trabajo.
    ///
    /// - Parameter name: Nombre de la entrada, sin ruta.
    /// - Returns: El proceso dueño, o `nil` si el nombre no lo lleva.
    static func owner(ofDirectoryNamed name: String) -> pid_t? {
        guard let separator = name.firstIndex(of: "-"), separator > name.startIndex else { return nil }
        let head = name[name.startIndex..<separator]
        guard !head.isEmpty, head.allSatisfy(\.isNumber), let value = pid_t(head), value > 0 else {
            return nil
        }
        return name.index(after: separator) < name.endIndex ? value : nil
    }

    /// `true` si el proceso sigue existiendo. Un `pid` que ya no responde da `ESRCH`; un
    /// proceso de otro usuario da `EPERM`, y ese sí está vivo.
    private static func isAlive(_ identifier: pid_t) -> Bool {
        kill(identifier, 0) == 0 || errno != ESRCH
    }

    private static var ioFailedMessage: String {
        String(
            localized: "uniconnect.mobile.transcribe.ioFailed",
            defaultValue: "No se pudo transcribir el audio en el equipo."
        )
    }
}
