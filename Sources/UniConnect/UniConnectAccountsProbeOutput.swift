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

    struct ResetCredits: Decodable, Sendable {
        let available: Int
        let nextExpiresAt: String?
    }

    struct Usage: Decodable, Sendable {
        let source: String
        let observedAt: String
        let limits: [Limit]
        let resetCredits: ResetCredits?
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

    /// What `--codex-reset` did (`accounts-v1` §5).
    struct CodexReset: Decodable, Sendable {
        let outcome: String?
        let usage: Usage?
        let error: String?
    }

    let version: Int
    let error: String?
    let sessions: [Session]
    let codexReset: CodexReset?

    /// Decodes the probe's JSON line; `nil` for anything malformed or of another version.
    ///
    /// Takes the last line that is a JSON object, so a remote shell that prints a banner or a
    /// greeting before the probe runs does not hide the answer.
    static func decode(_ data: Data) -> UniConnectAccountsProbeOutput? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let lines = data.split(separator: UInt8(ascii: "\n")).reversed()
        for line in lines where line.first == UInt8(ascii: "{") {
            if let output = try? decoder.decode(UniConnectAccountsProbeOutput.self, from: Data(line)),
               output.version == 1 {
                return output
            }
        }
        return nil
    }
}
