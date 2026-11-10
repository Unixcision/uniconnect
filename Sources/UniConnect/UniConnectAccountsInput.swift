import Foundation

/// Immutable projection of the open workspaces and windows that «Cuentas de IA» reads.
///
/// Built on the main actor from the live models, then handed to ``UniConnectAccountsReader``,
/// which never touches app state. Passwords and connect commands never enter it: SSH boxes are
/// referred to by their vault credential id.
struct UniConnectAccountsInput: Sendable {
    enum Kind: Sendable {
        case local
        case ssh
    }

    /// One terminal window and where its tmux session lives.
    struct Window: Sendable {
        let id: UUID
        let name: String
        /// The tmux socket name (`uniconnect-local`, or `default` on SSH boxes).
        let tmuxSocket: String?
        let tmuxSession: String?
    }

    /// One open UniConnect box.
    struct Workspace: Sendable {
        let id: UUID
        let name: String
        let kind: Kind
        /// The SSH box's vault credential; `nil` locally or when the vault is closed.
        let credentialID: UUID?
        /// `local`, or `ssh:<user>@<host>:<port>` of the effective endpoint (or the saved label).
        let hostKey: String
        /// «Este Mac», or `<user>@<host>:<port>`.
        let hostLabel: String
        let windows: [Window]
    }

    let workspaces: [Workspace]
}
