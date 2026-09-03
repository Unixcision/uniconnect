import Foundation

// MARK: - UniConnect data model
//
// UniConnect layers a connection profile on top of its workspace model:
//
// * A workspace ("caja") is either LOCAL (a folder on this Mac) or SSH (a server).
// * An SSH workspace stores a *reference* to its connect command (the actual
//   command, which may embed an sshpass password, lives in the encrypted vault).
// * Every terminal tab ("ventana") inside an SSH workspace is bound to a named
//   tmux session on the server. Killing the app only detaches; the tmux session
//   keeps running and is re-attached on restore.
// * Local tabs persist their Claude session identity and restore with `claude --resume`.

enum UniConnectWorkspaceKind: String, Codable, Sendable, Equatable {
    case local
    case ssh
}

struct UniConnectWorkspaceProfile: Codable, Sendable, Equatable {
    var kind: UniConnectWorkspaceKind
    /// Vault key for the SSH connect command. Nil for local workspaces.
    var credentialId: UUID?
    /// Human readable, password-free label such as `root@1.2.3.4`.
    var hostLabel: String?
    /// Whether tmux has been verified (and installed if needed) on the server.
    var tmuxReady: Bool
    /// When the box was created (seconds since 1970). Optional for older snapshots.
    var createdAt: TimeInterval?
    /// Last time UniConnect touched the box (window created/closed, reconnect, edit).
    var lastActivityAt: TimeInterval?

    init(
        kind: UniConnectWorkspaceKind,
        credentialId: UUID? = nil,
        hostLabel: String? = nil,
        tmuxReady: Bool = false,
        createdAt: TimeInterval? = Date().timeIntervalSince1970,
        lastActivityAt: TimeInterval? = Date().timeIntervalSince1970
    ) {
        self.kind = kind
        self.credentialId = credentialId
        self.hostLabel = hostLabel
        self.tmuxReady = tmuxReady
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }

    mutating func touch() { lastActivityAt = Date().timeIntervalSince1970 }

    static let local = UniConnectWorkspaceProfile(kind: .local)

    var isSSH: Bool { kind == .ssh }
}

// MARK: - Readable backup / seed document
//
// This is the *human readable* document UniConnect writes on "Persistir ahora",
// exports (encrypted) and imports. Passwords only ever appear inside the
// `connect` field, which is why the file is always encrypted at rest.

struct UniConnectDocument: Codable, Equatable {
    struct Window: Codable, Equatable {
        var name: String?
        /// tmux session name on the server (SSH workspaces).
        var tmux: String?
        /// Claude Code session id (local workspaces) for `claude --resume`.
        var claudeSession: String?
        var cwd: String?
        var isPinned: Bool?
    }

    struct Workspace: Codable, Equatable {
        /// Stable live workspace identity when exported by UniConnect; absent in Markdown maps.
        var id: UUID? = nil
        var name: String
        var kind: UniConnectWorkspaceKind
        /// Hex color (e.g. "#FF8800") or nil.
        var color: String?
        var group: String?
        var isPinned: Bool?
        /// Local: working directory. SSH: initial remote directory (optional).
        var cwd: String?
        /// SSH connect command, e.g. `sshpass -p 'x' ssh root@1.2.3.4`.
        var connect: String?
        var windows: [Window]
    }

    var version: Int
    var app: String
    var savedAt: String
    var workspaces: [Workspace]

    static let currentVersion = 1

    init(workspaces: [Workspace], savedAt: Date = Date()) {
        self.version = Self.currentVersion
        self.app = "UniConnect"
        self.savedAt = ISO8601DateFormatter().string(from: savedAt)
        self.workspaces = workspaces
    }
}

// MARK: - Storage identity

/// Stable storage identity for UniConnect's application, sessions, and history.
///
/// The suffix remains part of the existing session filenames for compatibility with
/// UniConnect releases already installed; it never redirects storage into another app.
enum UniConnectIdentity {
    static let storageSuffix = "-uniconnect"
    /// Folder under Application Support that holds session/history files.
    static let sessionFolder = "UniConnect"
    static let releaseBundleIdentifier = "com.unixcision.uniconnect"
}

// MARK: - Errors

enum UniConnectError: LocalizedError {
    case vaultLocked
    case missingCredential
    case badPassphrase
    case corruptFile(String)
    case sshFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "La bóveda de UniConnect está bloqueada."
        case .missingCredential:
            return "No se encuentra el comando de conexión de esta caja."
        case .badPassphrase:
            return "Contraseña incorrecta o fichero manipulado."
        case .corruptFile(let detail):
            return "Fichero de configuración inválido: \(detail)"
        case .sshFailed(let detail):
            return "Fallo SSH: \(detail)"
        case .cancelled:
            return "Cancelado."
        }
    }
}
