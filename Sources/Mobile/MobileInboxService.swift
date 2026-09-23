import Foundation

/// Servicio de `inbox.v1`: lo que hay en `~/UniConnect/Entrada`, para el móvil.
///
/// El móvil necesita tres cosas de la carpeta en la que `file_put.v1` deja lo que sube: ver
/// qué hay (tamaño, fecha y tipo, para la vista previa y para volver a pegar la ruta), leerlo
/// por trozos (vista previa y reproducción) y borrar con criterio sabiendo antes cuánto se
/// libera. Mismo contrato que `linux/uniconnect/inbox.py`.
///
/// Nunca sale de la carpeta: cada ruta se resuelve y se comprueba que cuelga de ella, los
/// enlaces simbólicos no se siguen y los `.part` de subidas en marcha ni se listan ni se
/// borran. Toda la E/S corre en este actor, fuera del hilo principal.
actor MobileInboxService {
    /// Tamaño máximo de un trozo de `read`.
    static let readChunkBytes = 1_048_576
    /// Máximo de entradas por página de `list`.
    static let maximumPage = 500

    private let baseDirectory: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - baseDirectory: Carpeta de entrada; por defecto `~/UniConnect/Entrada`.
    ///   - fileManager: Sistema de archivos; los tests pasan uno sobre un directorio temporal.
    ///   - now: Reloj para «anterior a N días».
    init(
        baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("UniConnect", isDirectory: true)
            .appendingPathComponent("Entrada", isDirectory: true),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: - Recorrido seguro

    private struct File {
        let url: URL
        let relative: String
        let size: Int
        let modified: Date
    }

    private var realRoot: String {
        baseDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Archivos normales de la bandeja; sin ocultos, sin `.part`, sin seguir enlaces.
    private func files() -> [File] {
        let root = realRoot
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [File] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            ) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, !url.lastPathComponent.hasSuffix(".part") else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            result.append(File(
                url: url, relative: String(path.dropFirst(root.count + 1)),
                size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return result
    }

    /// Ruta relativa a la bandeja → archivo, solo si es un archivo normal dentro de ella.
    private func resolve(_ relative: String) throws -> File {
        guard !relative.isEmpty, relative.utf8.count <= 1024, !relative.contains("\0"),
              !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw MobileInboxError.outsideInbox
        }
        let url = URL(fileURLWithPath: realRoot, isDirectory: true).appendingPathComponent(relative)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw MobileInboxError.notFound
        }
        // attributesOfItem no sigue el último enlace: un enlace simbólico se ve como tal y se rechaza.
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              !url.lastPathComponent.hasSuffix(".part"),
              url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(realRoot + "/") else {
            throw MobileInboxError.outsideInbox
        }
        return File(
            url: url, relative: relative,
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }

    // MARK: - inbox.list

    /// Lo más nuevo primero, con el total de la carpeta entera (no solo de la página).
    func list(limit: Int = 200, offset: Int = 0) -> MobileInboxListing {
        let all = files().sorted { $0.modified > $1.modified }
        let page = all.dropFirst(max(0, offset)).prefix(max(0, min(limit, Self.maximumPage)))
        return MobileInboxListing(
            root: realRoot,
            count: all.count,
            totalBytes: all.reduce(0) { $0 + $1.size },
            oldest: all.last?.modified,
            newest: all.first?.modified,
            entries: page.map {
                MobileInboxEntry(
                    path: $0.relative, absolute: $0.url.standardizedFileURL.path, name: $0.url.lastPathComponent,
                    size: $0.size, modified: $0.modified, kind: MobileInboxKind(fileName: $0.url.lastPathComponent)
                )
            }
        )
    }

    // MARK: - inbox.delete

    /// Borra lo que cumple TODOS los criterios dados (o `everything`, o `paths` concretas).
    ///
    /// Sin ningún criterio no borra nada: un filtro vacío que lo borrase todo es el accidente
    /// que no se deshace. Con `dryRun` devuelve lo mismo sin tocar el disco.
    func delete(_ criteria: MobileInboxDeletion) throws -> MobileInboxDeletionResult {
        let chosen: [File]
        if let paths = criteria.paths {
            guard paths.count <= Self.maximumPage else { throw MobileInboxError.invalidParams }
            chosen = try paths.map(resolve)
        } else {
            guard criteria.everything || criteria.olderThanDays != nil || criteria.largerThanBytes != nil else {
                throw MobileInboxError.missingCriterion
            }
            let limit = criteria.olderThanDays.map { now().addingTimeInterval(-$0 * 86_400) }
            chosen = files().filter { file in
                criteria.everything || ((limit.map { file.modified < $0 } ?? true)
                    && (criteria.largerThanBytes.map { file.size > $0 } ?? true))
            }
        }
        var deleted = 0
        var freed = 0
        if criteria.dryRun {
            deleted = chosen.count
            freed = chosen.reduce(0) { $0 + $1.size }
        } else {
            for file in chosen where (try? fileManager.removeItem(at: file.url)) != nil {
                deleted += 1
                freed += file.size
            }
            removeEmptyDirectories()
        }
        let remaining = files()
        let remainingBytes = remaining.reduce(0) { $0 + $1.size } - (criteria.dryRun ? freed : 0)
        return MobileInboxDeletionResult(
            dryRun: criteria.dryRun, deleted: deleted, freedBytes: freed,
            remainingCount: remaining.count - (criteria.dryRun ? deleted : 0), remainingBytes: remainingBytes
        )
    }

    /// Quita las carpetas de día que se han quedado vacías; nunca la raíz.
    private func removeEmptyDirectories() {
        let root = URL(fileURLWithPath: realRoot, isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  (try? fileManager.contentsOfDirectory(atPath: child.path).isEmpty) == true else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    // MARK: - inbox.read

    /// Un trozo del archivo, para la vista previa o para reproducirlo en el móvil.
    func read(path: String, offset: Int, length: Int) throws -> MobileInboxChunk {
        guard offset >= 0, length > 0 else { throw MobileInboxError.invalidParams }
        let file = try resolve(path)
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(length, Self.readChunkBytes)) ?? Data()
        return MobileInboxChunk(path: path, size: file.size, offset: offset, data: data,
                                endOfFile: offset + data.count >= file.size)
    }
}

/// Tipo de un archivo para la vista previa, por extensión.
enum MobileInboxKind: String, Sendable, Equatable {
    case image, video, audio, document, other

    init(fileName: String) {
        let ext = fileName.contains(".") ? (fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? "") : ""
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg": self = .image
        case "mp4", "mov", "m4v", "webm", "mkv", "avi", "3gp": self = .video
        case "mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "amr": self = .audio
        case "pdf", "txt", "md", "csv", "json", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip": self = .document
        default: self = .other
        }
    }
}

/// Una entrada de la bandeja.
struct MobileInboxEntry: Sendable, Equatable {
    let path: String
    let absolute: String
    let name: String
    let size: Int
    let modified: Date
    let kind: MobileInboxKind
}

/// Una página de la bandeja y el total de la carpeta.
struct MobileInboxListing: Sendable, Equatable {
    let root: String
    let count: Int
    let totalBytes: Int
    let oldest: Date?
    let newest: Date?
    let entries: [MobileInboxEntry]
}

/// Qué borrar. Los criterios se suman; `paths` los sustituye.
struct MobileInboxDeletion: Sendable, Equatable {
    var everything = false
    var olderThanDays: Double?
    var largerThanBytes: Int?
    var paths: [String]?
    var dryRun = false
}

/// Qué se borró (o se borraría, con `dryRun`) y qué queda.
struct MobileInboxDeletionResult: Sendable, Equatable {
    let dryRun: Bool
    let deleted: Int
    let freedBytes: Int
    let remainingCount: Int
    let remainingBytes: Int
}

/// Un trozo leído.
struct MobileInboxChunk: Sendable, Equatable {
    let path: String
    let size: Int
    let offset: Int
    let data: Data
    let endOfFile: Bool
}

/// Errores de `inbox.v1`, con el código que ve el móvil.
enum MobileInboxError: Error, Equatable {
    case outsideInbox, notFound, missingCriterion, invalidParams

    var code: String {
        switch self {
        case .notFound: "not_found"
        default: "invalid_params"
        }
    }

    var message: String {
        switch self {
        case .outsideInbox:
            String(localized: "uniconnect.mobile.inbox.outside", defaultValue: "Ruta fuera de la bandeja de entrada.")
        case .notFound:
            String(localized: "uniconnect.mobile.inbox.notFound", defaultValue: "El archivo ya no está en la bandeja de entrada.")
        case .missingCriterion:
            String(localized: "uniconnect.mobile.inbox.missingCriterion", defaultValue: "Falta un criterio de borrado.")
        case .invalidParams:
            String(localized: "uniconnect.mobile.inbox.invalidParams", defaultValue: "Parámetros de la bandeja no válidos.")
        }
    }
}
