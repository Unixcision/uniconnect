import Foundation

/// Main-actor terminal writer resolved through an injected set of app windows.
@MainActor
final class UniConnectClaudeTerminalWriter: UniConnectClaudeTerminalWriting {
    typealias TabManagersProvider = @MainActor @Sendable () -> [TabManager]

    private let tabManagersProvider: TabManagersProvider

    init(tabManagersProvider: @escaping TabManagersProvider) {
        self.tabManagersProvider = tabManagersProvider
    }

    func sendText(_ text: String, workspaceID: UUID, panelID: UUID) -> Bool {
        guard text.utf8.count <= 16_384, !text.contains("\0") else { return false }
        for manager in tabManagersProvider() {
            guard let workspace = manager.tabs.first(where: { $0.id == workspaceID }),
                  let terminal = workspace.panels[panelID] as? TerminalPanel else {
                continue
            }
            return terminal.sendText(text)
        }
        return false
    }
}
