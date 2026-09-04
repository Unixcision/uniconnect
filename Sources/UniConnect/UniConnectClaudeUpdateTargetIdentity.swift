import Foundation
import UniConnectClaudeUpdate

/// Encodes app-owned UUIDs into credential-free updater identifiers.
enum UniConnectClaudeUpdateTargetIdentity {
    static func targetID(panelID: UUID) -> ClaudeUpdateTargetID {
        ClaudeUpdateTargetID(rawValue: panelID.uuidString.lowercased())
    }

    static func panelID(from targetID: ClaudeUpdateTargetID) -> UUID? {
        UUID(uuidString: targetID.rawValue)
    }

    static func boxID(workspaceID: UUID) -> String {
        workspaceID.uuidString.lowercased()
    }
}
