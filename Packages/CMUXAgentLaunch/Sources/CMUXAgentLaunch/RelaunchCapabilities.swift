import Foundation

/// The `capabilities` tokens a host announces for relaunching and updating agents.
///
/// `relaunch.v1`, then one `relaunch.v1.<proveedor>.<tipo>` per supported cell, then
/// `relaunch.v1.update` and `relaunch.v1.update.claude.<tipo>` where Actualizar Claude works, and
/// `relaunch.v1.restaura` when monitors and drafts are kept (`contracts/relaunch-v1/LEEME.md`,
/// «Anuncio»). The exact list of each host is its row of `proveedores.json`.
///
/// ```swift
/// RelaunchCapabilities(local: ["claude"], ssh: ["claude"], update: ["local", "ssh"], restores: true).tokens
/// // ["relaunch.v1", "relaunch.v1.claude.local", "relaunch.v1.claude.ssh", "relaunch.v1.restaura",
/// //  "relaunch.v1.update", "relaunch.v1.update.claude.local", "relaunch.v1.update.claude.ssh"]
/// ```
public struct RelaunchCapabilities: Sendable, Equatable {
    /// Providers relaunched in local windows.
    public let local: Set<String>
    /// Providers relaunched in SSH windows.
    public let ssh: Set<String>
    /// Window kinds (`local`, `ssh`) where `agent.update` works.
    public let update: Set<String>
    /// Whether monitors and drafts are saved and given back.
    public let restores: Bool

    /// What this Mac announces: Claude local and SSH, and Codex SSH (both through the Linux worker
    /// on the destination), with `agent.update` for Claude and monitors and drafts kept.
    public static let mac = RelaunchCapabilities(local: ["claude"], ssh: ["claude", "codex"], update: ["local", "ssh"], restores: true)

    /// Creates a capability set.
    ///
    /// - Parameters:
    ///   - local: Providers relaunched in local windows.
    ///   - ssh: Providers relaunched in SSH windows.
    ///   - update: Window kinds where `agent.update` works.
    ///   - restores: Whether monitors and drafts are kept.
    public init(local: Set<String>, ssh: Set<String>, update: Set<String>, restores: Bool) {
        self.local = local
        self.ssh = ssh
        self.update = update
        self.restores = restores
    }

    /// The tokens, sorted, `relaunch.v1` included.
    public var tokens: [String] {
        var result: Set<String> = ["relaunch.v1"]
        for provider in local { result.insert("relaunch.v1.\(provider).local") }
        for provider in ssh { result.insert("relaunch.v1.\(provider).ssh") }
        if !update.isEmpty {
            result.insert("relaunch.v1.update")
            for kind in update { result.insert("relaunch.v1.update.claude.\(kind)") }
        }
        if restores { result.insert("relaunch.v1.restaura") }
        return result.sorted()
    }
}
