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
// * Local tabs are durable window containers. They keep a non-destructive history of
//   every resumable agent used there, independently from the process currently running.

enum UniConnectWorkspaceKind: String, Codable, Sendable, Equatable {
    case local
    case ssh
}

struct UniConnectWorkspaceProfile: Codable, Sendable, Equatable {
    var kind: UniConnectWorkspaceKind
    /// Import/export identity that survives app session restoration.
    var importIdentity: UUID?
    /// Vault key for the SSH connect command. Nil for local workspaces.
    var credentialId: UUID?
    /// Human readable, password-free label such as `root@1.2.3.4`.
    var hostLabel: String?
    /// Whether tmux has been verified (and installed if needed) on the server.
    var tmuxReady: Bool
    /// Authoritative folder trusted by every local window in this box. Nil for SSH.
    var localRoot: String?
    /// When the box was created (seconds since 1970). Optional for older snapshots.
    var createdAt: TimeInterval?
    /// Last time UniConnect touched the box (window created/closed, reconnect, edit).
    var lastActivityAt: TimeInterval?

    init(
        kind: UniConnectWorkspaceKind,
        importIdentity: UUID? = nil,
        credentialId: UUID? = nil,
        hostLabel: String? = nil,
        tmuxReady: Bool = false,
        localRoot: String? = nil,
        createdAt: TimeInterval? = Date().timeIntervalSince1970,
        lastActivityAt: TimeInterval? = Date().timeIntervalSince1970
    ) {
        self.kind = kind
        self.importIdentity = importIdentity
        self.credentialId = credentialId
        self.hostLabel = hostLabel
        self.tmuxReady = tmuxReady
        self.localRoot = localRoot
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }

    mutating func touch() { lastActivityAt = Date().timeIntervalSince1970 }

    static let local = UniConnectWorkspaceProfile(kind: .local)

    var isSSH: Bool { kind == .ssh }
}

// MARK: - Readable backup / seed document
//
// This is the document UniConnect uses for readable local backups, portable
// encrypted exports, and imports. A local backup clears every `connect` value and
// keeps only `credentialId`; its encrypted companion vault owns the connection
// command. Portable exports may carry `connect` because their whole payload is
// encrypted with the user's passphrase.

struct UniConnectDocument: Codable, Equatable {
    struct Window: Codable, Equatable {
        var name: String?
        /// tmux session name on the server (SSH workspaces).
        var tmux: String?
        /// Claude Code session id (local workspaces) for `claude --resume`.
        var claudeSession: String?
        /// Per-window local cwd. It must remain inside the workspace's trusted `cwd` root.
        var cwd: String?
        var isPinned: Bool?
        /// Durable local-window state. Nil for SSH and version-1 documents.
        var localWindow: UniConnectLocalWindowRecord? = nil
    }

    struct Workspace: Codable, Equatable {
        /// Stable import/export identity; absent in hand-written Markdown maps.
        var id: UUID? = nil
        var name: String
        var kind: UniConnectWorkspaceKind
        /// Hex color (e.g. "#FF8800") or nil.
        var color: String?
        var group: String?
        var isPinned: Bool?
        /// Local: immutable trusted box root. SSH: initial remote directory (optional).
        var cwd: String?
        /// SSH connect command, e.g. `sshpass -p 'x' ssh root@1.2.3.4`.
        var connect: String?
        /// Opaque immutable vault revision used by readable local backups. Nil for local boxes.
        var credentialId: UUID? = nil
        var windows: [Window]
    }

    var version: Int
    var app: String
    var savedAt: String
    var workspaces: [Workspace]

    static let currentVersion = 2

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
            return String(
                localized: "uniconnect.error.vaultLocked",
                defaultValue: "The UniConnect vault is locked."
            )
        case .missingCredential:
            return String(
                localized: "uniconnect.error.missingCredential",
                defaultValue: "The connection command for this box could not be found."
            )
        case .badPassphrase:
            return String(
                localized: "uniconnect.error.badPassphrase",
                defaultValue: "The password is incorrect or the file has been tampered with."
            )
        case .corruptFile(let detail):
            return String(
                format: String(
                    localized: "uniconnect.error.corruptFile",
                    defaultValue: "Invalid configuration file: %@"
                ),
                detail
            )
        case .sshFailed(let detail):
            return String(
                format: String(
                    localized: "uniconnect.error.sshFailed",
                    defaultValue: "SSH failed: %@"
                ),
                detail
            )
        case .cancelled:
            return String(
                localized: "uniconnect.error.cancelled",
                defaultValue: "Cancelled."
            )
        }
    }
}
