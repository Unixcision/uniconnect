import Foundation

/// Sends bounded updater input to one exact live terminal panel.
@MainActor
protocol UniConnectClaudeTerminalWriting: Sendable {
    func sendText(_ text: String, workspaceID: UUID, panelID: UUID) -> Bool
}
