import Foundation

/// «Cuentas de IA» (`accounts.v1`): which account every agent uses, read live, and each account's usage.
///
/// The same value feeds the desktop window and `mobile.accounts.list` (``mobilePayload``). Every
/// window comes from the reading that produced this value: a host that did not answer leaves its
/// windows `host_inaccesible`, never with an earlier account. Only ``AccountSummary/history`` is
/// remembered between readings, and it is shown as history, with its dates.
struct UniConnectAccountsSnapshot: Equatable, Sendable {
    /// One usage limit of an account (`five_hour`, `seven_day`, Codex's `primary`…).
    struct Limit: Equatable, Sendable, Codable {
        let id: String
        let usedPercent: Double
        let resetsAt: Date?
        let windowMinutes: Int?
    }

    /// Free full resets an account still has (Codex), and when the first one expires.
    struct ResetCredits: Equatable, Sendable {
        let available: Int
        let nextExpiresAt: Date?
    }

    /// The last usage an agent reported for its account, and where it was seen.
    struct Usage: Equatable, Sendable {
        /// `statusline` (Claude's status line), `app_server` (Codex, live) or `rollout` (Codex's log).
        let source: String
        let observedAt: Date
        let limits: [Limit]
        var resetCredits: ResetCredits? = nil
        /// The host it was seen on; set when it is chosen for ``AccountSummary``.
        var hostKey: String?
    }

    /// The account of one agent, as read now.
    struct Account: Equatable, Sendable {
        let email: String?
        let method: String?
        let plan: String?
        let organization: String?
        let osUser: String?
        let config: String?
        let readAt: Date?
        let usage: Usage?
    }

    /// The agent running in a window.
    struct Agent: Equatable, Sendable {
        let provider: String
        let displayName: String
        let asRoot: Bool
    }

    /// Whether a host could be read in this reading.
    enum HostState: String, Sendable {
        case ok
        case hostUnreachable = "host_inaccesible"
        case vaultClosed = "boveda_cerrada"
    }

    /// One host read for this snapshot (this Mac, or an SSH endpoint).
    struct Host: Equatable, Sendable, Identifiable {
        let key: String
        let label: String
        /// `local` or `ssh`.
        let kind: String
        let state: HostState
        let checkedAt: Date
        /// Why it could not be read: `sin_respuesta`, `sin_python3`, `ssh_fallo`, `salida_no_valida`,
        /// `tmux_no_disponible`, `tmux_fallo`; `nil` when it was read.
        var error: String? = nil
        /// What SSH or the shell said when it failed (one sanitized line), to diagnose it.
        var errorDetail: String? = nil
        var id: String { key }
    }

    /// What a window shows, by the first rule of `accounts-v1` §3 that applies.
    enum WindowState: String, Sendable, CaseIterable {
        case ok
        case noSession = "sin_sesion"
        case unreadable = "no_legible"
        case unknown = "desconocida"
        case noAgent = "sin_ia"
        case ambiguous = "identidad_ambigua"
        case deadPane = "panel_muerto"
        case hostUnreachable = "host_inaccesible"
        case noTmux = "sin_tmux"
        case sessionNotLive = "sesion_no_viva"

        /// Windows hidden while «Ventanas sin IA» is off.
        var isWithoutAgent: Bool { self == .noAgent || self == .noTmux || self == .deadPane }

        /// Windows counted under «Sin leer».
        var isUnread: Bool {
            self == .unreadable || self == .unknown || self == .hostUnreachable
                || self == .sessionNotLive || self == .ambiguous
        }
    }

    /// One terminal window and the account of its agent.
    struct Window: Equatable, Sendable, Identifiable {
        let workspaceID: UUID
        let workspace: String
        let terminalID: UUID
        let window: String
        let hostKey: String
        let tmuxSession: String?
        let state: WindowState
        let agent: Agent?
        let account: Account?
        var id: UUID { terminalID }
    }

    /// One recorded usage sample of an account.
    struct HistoryPoint: Equatable, Sendable, Codable {
        let at: Date
        /// `used_percent` by limit id.
        let limits: [String: Double]
    }

    /// One account (provider + email) with every window that uses it.
    struct AccountSummary: Equatable, Sendable, Identifiable {
        let key: String
        let provider: String
        let displayName: String
        let email: String
        let plan: String?
        let organization: String?
        let windows: Int
        let hostKeys: [String]
        let usage: Usage?
        let history: [HistoryPoint]
        var id: String { key }
    }

    let checkedAt: Date
    let hosts: [Host]
    let windows: [Window]
    let accounts: [AccountSummary]

    /// The host with `key`, if it was read.
    func host(_ key: String) -> Host? {
        hosts.first { $0.key == key }
    }

    /// The same reading restricted to one workspace (`mobile.accounts.list` with `workspace_id`).
    func restricted(toWorkspace workspaceID: UUID) -> UniConnectAccountsSnapshot {
        let kept = windows.filter { $0.workspaceID == workspaceID }
        let hostKeys = Set(kept.map(\.hostKey))
        let accountKeys = Set(kept.compactMap { window -> String? in
            guard let email = window.account?.email, let agent = window.agent else { return nil }
            return UniConnectAccountsSnapshot.accountKey(provider: agent.provider, email: email)
        })
        return UniConnectAccountsSnapshot(
            checkedAt: checkedAt,
            hosts: hosts.filter { hostKeys.contains($0.key) },
            windows: kept,
            accounts: accounts.filter { accountKeys.contains($0.key) }
        )
    }

    /// `<provider>:<email>`: the same email in Claude and in Codex are two accounts.
    static func accountKey(provider: String, email: String) -> String {
        "\(provider):\(email)"
    }
}
