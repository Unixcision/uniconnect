import AppKit
import SwiftUI

extension cmuxApp {
    /// Builds File › Recently Closed without reintroducing the removed History menu.
    @ViewBuilder
    func recentlyClosedMenuContent(manager: TabManager) -> some View {
        let _ = closedItemHistoryStore.revision
        let snapshot = closedItemHistoryStore.menuSnapshot(maxItemCount: 40)

        if snapshot.items.isEmpty {
            Button(String(localized: "menu.file.recentlyClosed.empty", defaultValue: "No Closed Windows or Boxes")) {}
                .disabled(true)
        } else {
            ForEach(snapshot.items) { item in
                Menu(item.menuTitle) {
                    Button {
                        if AppDelegate.shared?.reopenClosedHistoryItem(
                            id: item.id,
                            preferredTabManager: manager
                        ) != true {
                            NSSound.beep()
                        }
                    } label: {
                        Label(String(localized: "menu.file.recentlyClosed.reopen", defaultValue: "Reopen"), systemImage: "arrow.uturn.backward")
                    }

                    Button(role: .destructive) {
                        confirmDeleteClosedHistoryItem(id: item.id)
                    } label: {
                        Label(
                            String(localized: "menu.file.recentlyClosed.delete", defaultValue: "Delete Permanently…"),
                            systemImage: "trash"
                        )
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                confirmClearClosedHistory(manager: manager)
            } label: {
                Label(String(localized: "menu.file.recentlyClosed.clear", defaultValue: "Clear List…"), systemImage: "trash.slash")
            }
        }
    }

    private func confirmDeleteClosedHistoryItem(id: UUID) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "menu.file.recentlyClosed.delete.confirm.title",
            defaultValue: "Delete This Closed Item Permanently?"
        )
        alert.informativeText = String(
            localized: "menu.file.recentlyClosed.delete.confirm.message",
            defaultValue: "It will no longer be available to reopen. Remote tmux sessions are not affected."
        )
        alert.addButton(withTitle: String(localized: "menu.file.recentlyClosed.delete.confirm.action", defaultValue: "Delete"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = closedItemHistoryStore.removeRecord(id: id)
    }

    private func confirmClearClosedHistory(manager: TabManager) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "menu.file.recentlyClosed.clear.confirm.title",
            defaultValue: "Clear Recently Closed?"
        )
        alert.informativeText = String(
            localized: "menu.file.recentlyClosed.clear.confirm.message",
            defaultValue: "Every closed item will be removed from this list. Remote tmux sessions are not affected."
        )
        alert.addButton(withTitle: String(localized: "menu.file.recentlyClosed.clear.confirm.action", defaultValue: "Clear List"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppDelegate.shared?.clearRecentlyClosedHistory(preferredTabManager: manager)
    }
}
