import CryptoKit
import Foundation

/// Servicio de `file_put.v1`: recibe un archivo del móvil en trozos, lo guarda en
/// `~/UniConnect/Entrada/<AAAAMMDD>/<nombre>` y, si la caja es SSH, lo reenvía al servidor.
///
/// Reglas del contrato: el nombre definitivo se reserva en `begin` (archivo `.part` creado en
/// exclusiva, sufijo `-2`, `-3`… decidido entonces) para que dos subidas concurrentes no se
/// pisen; cada trozo y el commit deben llegar con la misma ligadura (dispositivo, caja y
/// revisión de credencial); los trozos van en orden desde 0 y nunca superan el tamaño
/// anunciado; el commit verifica el SHA-256; una transferencia sin trozos durante
/// ``expiry`` caduca y se borra. Toda la E/S corre en este actor, fuera del hilo principal.
actor MobileFilePutService {
    /// Bytes crudos por trozo que se anuncian en `begin`.
    static let chunkBytes = 1_048_576
    /// Tamaño máximo anunciable.
    static let maximumSize = 200 * 1_048_576
    /// Caducidad sin trozos.
    static let defaultExpiry: Duration = .seconds(600)

    private struct Transfer {
        let binding: MobileFilePutBinding
        let terminalID: UUID?
        let name: MobileFilePutName
        let declaredSize: Int
        let mime: String?
        let directory: URL
        let partURL: URL
        let reservedOrdinal: Int
        var receivedBytes = 0
        var nextIndex = 0
        var hasher = SHA256()
        var expiryTask: Task<Void, Never>?
    }

    private let baseDirectory: URL
    private let fileManager: FileManager
    private let remoteCopier: any MobileFileRemoteCopying
    private let clock: any Clock<Duration>
    private let expiry: Duration
    private let remoteTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private var transfers: [UUID: Transfer] = [:]

    /// - Parameters:
    ///   - baseDirectory: Carpeta de entrada; por defecto `~/UniConnect/Entrada`.
    ///   - fileManager: Sistema de archivos; los tests pasan uno con un directorio temporal.
    ///   - remoteCopier: Salto SSH; los tests inyectan uno falso.
    ///   - clock: Reloj de la caducidad.
    ///   - expiry: Tiempo sin trozos tras el que la transferencia se borra.
    ///   - remoteTimeout: Plazo del salto SSH (el móvil espera 120 s al commit).
    ///   - now: Fecha para la carpeta del día.
    init(
        baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("UniConnect", isDirectory: true)
            .appendingPathComponent("Entrada", isDirectory: true),
        fileManager: FileManager = .default,
        remoteCopier: any MobileFileRemoteCopying = MobileFileSSHCopier(),
        clock: any Clock<Duration> = ContinuousClock(),
        expiry: Duration = MobileFilePutService.defaultExpiry,
        remoteTimeout: TimeInterval = 100,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.remoteCopier = remoteCopier
        self.clock = clock
        self.expiry = expiry
        self.remoteTimeout = remoteTimeout
        self.now = now
    }

    /// Ligadura de una transferencia viva, para que el host la recalcule antes de cada trozo.
    func binding(of transferID: UUID) -> MobileFilePutBinding? {
        transfers[transferID]?.binding
    }

    /// Reserva el nombre y crea el `.part`; el tamaño se valida aquí para no aceptar trozos en vano.
    func begin(
        name rawName: String,
        size: Int,
        mime: String?,
        terminalID: UUID?,
        binding: MobileFilePutBinding
    ) throws -> MobileFilePutBegin {
        guard size >= 0 else {
            throw MobileFilePutError.invalidParams(
                String(localized: "uniconnect.mobile.file.invalidSize", defaultValue: "Indica el tamaño del archivo en bytes.")
            )
        }
        guard size <= Self.maximumSize else { throw MobileFilePutError.tooLarge }
        let name = MobileFilePutName(rawName: rawName)
        let directory = baseDirectory.appendingPathComponent(Self.dayFolder(for: now()), isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MobileFilePutError.ioFailed(Self.ioFailedMessage)
        }
        guard let reservation = reserve(name: name, in: directory) else {
            throw MobileFilePutError.ioFailed(Self.ioFailedMessage)
        }
        let transferID = UUID()
        var transfer = Transfer(
            binding: binding,
            terminalID: terminalID,
            name: name,
            declaredSize: size,
            mime: mime,
            directory: directory,
            partURL: reservation.partURL,
            reservedOrdinal: reservation.ordinal
        )
        transfer.expiryTask = makeExpiryTask(for: transferID)
        transfers[transferID] = transfer
        return MobileFilePutBegin(transferID: transferID, chunkBytes: Self.chunkBytes)
    }

    /// Añade el trozo `index` (base64) y devuelve los bytes recibidos hasta ahora.
    func appendChunk(
        transferID: UUID,
        index: Int,
        base64: String,
        binding: MobileFilePutBinding
    ) throws -> Int {
        guard var transfer = transfers[transferID], transfer.binding == binding else {
            throw MobileFilePutError.notFound
        }
        guard index == transfer.nextIndex else {
            throw MobileFilePutError.invalidParams(
                String(localized: "uniconnect.mobile.file.chunkOrder", defaultValue: "Trozo fuera de orden o repetido.")
            )
        }
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              data.count <= Self.chunkBytes else {
            throw MobileFilePutError.invalidParams(
                String(localized: "uniconnect.mobile.file.invalidChunk", defaultValue: "El trozo no es base64 válido o supera chunk_bytes.")
            )
        }
        guard transfer.receivedBytes + data.count <= transfer.declaredSize else {
            discard(transferID)
            throw MobileFilePutError.tooLarge
        }
        do {
            let handle = try FileHandle(forWritingTo: transfer.partURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            discard(transferID)
            throw MobileFilePutError.ioFailed(Self.ioFailedMessage)
        }
        transfer.hasher.update(data: data)
        transfer.receivedBytes += data.count
        transfer.nextIndex += 1
        transfer.expiryTask?.cancel()
        transfer.expiryTask = makeExpiryTask(for: transferID)
        transfers[transferID] = transfer
        return transfer.receivedBytes
    }

    /// Verifica tamaño y SHA-256, renombra el `.part` sin sobrescribir y salta al servidor si toca.
    func commit(transferID: UUID, sha256 expected: String, binding: MobileFilePutBinding) async throws -> MobileFilePutCommit {
        guard let transfer = transfers[transferID], transfer.binding == binding else {
            throw MobileFilePutError.notFound
        }
        transfer.expiryTask?.cancel()
        transfers.removeValue(forKey: transferID)
        guard transfer.receivedBytes == transfer.declaredSize else {
            try? fileManager.removeItem(at: transfer.partURL)
            throw MobileFilePutError.invalidParams(
                String(localized: "uniconnect.mobile.file.sizeMismatch", defaultValue: "Se recibieron menos bytes de los anunciados.")
            )
        }
        let digest = transfer.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            try? fileManager.removeItem(at: transfer.partURL)
            throw MobileFilePutError.invalidParams(
                String(localized: "uniconnect.mobile.file.shaMismatch", defaultValue: "El archivo recibido no coincide con su sha256.")
            )
        }
        guard let finalURL = finalize(transfer) else {
            try? fileManager.removeItem(at: transfer.partURL)
            throw MobileFilePutError.ioFailed(Self.ioFailedMessage)
        }
        guard let credentialRecord = transfer.binding.credentialRecord else {
            return MobileFilePutCommit(path: finalURL.path, location: .host)
        }
        switch await remoteCopier.copy(
            localURL: finalURL,
            name: transfer.name,
            credentialRecord: credentialRecord,
            timeout: remoteTimeout
        ) {
        case let .copied(remotePath):
            return MobileFilePutCommit(path: finalURL.path, location: .remote, remotePath: remotePath)
        case let .failed(message):
            return MobileFilePutCommit(path: finalURL.path, location: .host, remoteError: message)
        }
    }

    /// Descarta la transferencia y su `.part`.
    func abort(transferID: UUID, binding: MobileFilePutBinding) throws {
        guard let transfer = transfers[transferID], transfer.binding == binding else {
            throw MobileFilePutError.notFound
        }
        discard(transferID)
    }

    /// Transferencias vivas (para pruebas y diagnóstico).
    var activeTransferIDs: [UUID] { Array(transfers.keys) }

    // MARK: - Internos

    private static var ioFailedMessage: String {
        String(localized: "uniconnect.mobile.file.ioFailed", defaultValue: "No se pudo guardar el archivo en el equipo.")
    }

    static func dayFolder(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// Crea `<candidato>.part` en exclusiva con el primer ordinal libre (ni definitivo ni `.part`).
    private func reserve(name: MobileFilePutName, in directory: URL) -> (ordinal: Int, partURL: URL)? {
        for ordinal in 1...10_000 {
            let candidate = name.candidate(ordinal)
            let finalURL = directory.appendingPathComponent(candidate, isDirectory: false)
            let partURL = directory.appendingPathComponent(candidate + ".part", isDirectory: false)
            guard !fileManager.fileExists(atPath: finalURL.path) else { continue }
            do {
                try Data().write(to: partURL, options: .withoutOverwriting)
                return (ordinal, partURL)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Mueve el `.part` al primer nombre definitivo libre a partir del reservado, sin sobrescribir.
    private func finalize(_ transfer: Transfer) -> URL? {
        for ordinal in transfer.reservedOrdinal...(transfer.reservedOrdinal + 10_000) {
            let finalURL = transfer.directory.appendingPathComponent(transfer.name.candidate(ordinal), isDirectory: false)
            guard !fileManager.fileExists(atPath: finalURL.path) else { continue }
            do {
                try fileManager.moveItem(at: transfer.partURL, to: finalURL)
                return finalURL
            } catch {
                continue
            }
        }
        return nil
    }

    private func discard(_ transferID: UUID) {
        guard let transfer = transfers.removeValue(forKey: transferID) else { return }
        transfer.expiryTask?.cancel()
        try? fileManager.removeItem(at: transfer.partURL)
    }

    private func makeExpiryTask(for transferID: UUID) -> Task<Void, Never> {
        Task { [expiry, clock] in
            // Retardo acotado y cancelable con reloj inyectado: la caducidad es el comportamiento.
            do {
                try await clock.sleep(for: expiry)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.discard(transferID)
        }
    }
}
