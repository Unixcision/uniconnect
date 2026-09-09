import Foundation

/// A qué está ligada una transferencia `file_put.v1`: el dispositivo móvil autenticado y la
/// caja con la revisión de credencial capturadas en `begin`. Si cualquiera cambia, los
/// trozos y el commit se rechazan con `not_found`.
struct MobileFilePutBinding: Equatable, Sendable {
    /// Dirección aprobada de la sesión móvil; `nil` solo en llamadas sin transporte (tests).
    let peerAddress: String?
    let workspaceID: UUID
    /// Credencial de la caja SSH (`nil` en cajas locales).
    let credentialID: UUID?
    /// Revisión de la credencial tal y como estaba en `begin`.
    let credentialRecord: UniConnectSSHCredentialRecord?

    init(peerAddress: String?, workspaceID: UUID, credentialID: UUID?, credentialRecord: UniConnectSSHCredentialRecord?) {
        self.peerAddress = peerAddress
        self.workspaceID = workspaceID
        self.credentialID = credentialID
        self.credentialRecord = credentialRecord
    }

    /// La caja es SSH y el archivo debe saltar al servidor tras guardarse en el host.
    var isSSH: Bool { credentialRecord != nil }
}

/// Respuesta de `mobile.file.begin`.
struct MobileFilePutBegin: Equatable, Sendable {
    let transferID: UUID
    /// Bytes crudos máximos por trozo (≤ 1 MiB).
    let chunkBytes: Int
}

/// Respuesta de `mobile.file.commit`.
struct MobileFilePutCommit: Equatable, Sendable {
    enum Location: String, Sendable {
        case host
        case remote
    }

    /// Ruta en el host (siempre presente: el host conserva su copia).
    let path: String
    let location: Location
    /// Ruta en el servidor cuando el salto SSH terminó bien.
    let remotePath: String?
    /// Motivo legible cuando la caja es SSH y el salto falló (`location` queda en `host`).
    let remoteError: String?

    init(path: String, location: Location, remotePath: String? = nil, remoteError: String? = nil) {
        self.path = path
        self.location = location
        self.remotePath = remotePath
        self.remoteError = remoteError
    }
}

/// Fallos de `file_put.v1`, con el código del contrato y un mensaje en español.
enum MobileFilePutError: Error, Equatable, Sendable {
    case invalidParams(String)
    case tooLarge
    case notFound
    case ioFailed(String)

    var code: String {
        switch self {
        case .invalidParams: return "invalid_params"
        case .tooLarge: return "too_large"
        case .notFound: return "not_found"
        case .ioFailed: return "io_failed"
        }
    }

    var message: String {
        switch self {
        case let .invalidParams(message), let .ioFailed(message):
            return message
        case .tooLarge:
            return String(localized: "uniconnect.mobile.file.tooLarge", defaultValue: "El archivo supera el tamaño máximo (200 MiB).")
        case .notFound:
            return String(localized: "uniconnect.mobile.file.notFound", defaultValue: "No se encontró la transferencia.")
        }
    }
}

/// Resultado del salto al servidor de una caja SSH.
enum MobileFileRemoteCopyResult: Equatable, Sendable {
    case copied(remotePath: String)
    case failed(String)
}

/// Costura del salto SSH: copia el archivo ya guardado en el host al servidor de la caja con
/// la misma credencial que usa la caja. Los tests inyectan una implementación falsa.
protocol MobileFileRemoteCopying: Sendable {
    func copy(
        localURL: URL,
        name: MobileFilePutName,
        credentialRecord: UniConnectSSHCredentialRecord,
        timeout: TimeInterval
    ) async -> MobileFileRemoteCopyResult
}
