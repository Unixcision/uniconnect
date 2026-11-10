import Foundation

/// What `agent_probe.py --accounts` prints (contracts/agent-tree-v1 plus accounts-v1 §2), decoded.
///
/// Only the keys «Cuentas de IA» needs. Decode with `.convertFromSnakeCase`.
struct UniConnectAccountsProbeOutput: Decodable, Sendable {
    struct Limit: Decodable, Sendable {
        let id: String
        let usedPercent: Double
        let resetsAt: String?
        let windowMinutes: Int?
    }

    struct Usage: Decodable, Sendable {
        let source: String
        let observedAt: String
        let limits: [Limit]
    }

    struct Account: Decodable, Sendable {
        let state: String
        let email: String?
        let method: String?
        let plan: String?
        let organization: String?
        let osUser: String?
        let config: String?
        let readAt: String?
        let usage: Usage?
    }

    struct Agent: Decodable, Sendable {
        let provider: String
        let asRoot: Bool?
        let account: Account?
    }

    struct Session: Decodable, Sendable {
        let name: String
        let reason: String?
        let agent: Agent?
    }

    let version: Int
    let error: String?
    let sessions: [Session]

    /// Decodes one probe line; `nil` for anything malformed or of another version.
    static func decode(_ data: Data) -> UniConnectAccountsProbeOutput? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let output = try? decoder.decode(UniConnectAccountsProbeOutput.self, from: data),
              output.version == 1 else { return nil }
        return output
    }
}
