import AppKit
import Foundation

/// «Dictado»'s way into UniConnect's terminals: the focused one of the frontmost window, and a
/// paste into a given one.
///
/// The paste is the same as the socket's `send` (`TerminalPanel.sendText`): it reaches the program
/// as a paste, bracketed when the program asked for that, so Claude or Codex take a multi-word
/// dictation as typed text and nothing is sent until Enter is pressed. After a paste the keyboard
/// goes back to UniConnect's window if the box had it, so Enter reaches the terminal.
@MainActor
final class UniConnectDictationTerminalBridge: UniConnectDictationTerminals {
    func focusedTarget() -> UniConnectDictationTarget? {
        guard let workspace = AppDelegate.shared?.activeTabManagerForCommands()?.selectedWorkspace,
              let panel = workspace.focusedTerminalPanel else { return nil }
        return UniConnectDictationTarget(
            workspaceID: workspace.id,
            panelID: panel.id,
            name: Self.name(of: panel.id, in: workspace)
        )
    }

    func paste(_ text: String, into target: UniConnectDictationTarget) -> Bool {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: target.workspaceID),
              let panel = workspace.panels[target.panelID] as? TerminalPanel,
              panel.sendText(text) else { return false }
        if NSApp.keyWindow is UniConnectDictationPanel {
            NSApp.mainWindow?.makeKey()
        }
        return true
    }

    func submit(in target: UniConnectDictationTarget) async -> Bool {
        // Bounded, intended delay (the phone waits 80 ms): a TUI that sees Return in the same read
        // as the end of a paste takes it as part of the paste instead of as «send».
        try? await Task.sleep(for: .milliseconds(150))
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: target.workspaceID),
              let panel = workspace.panels[target.panelID] as? TerminalPanel else { return false }
        return panel.sendNamedKey("enter")
    }

    /// «Espacio · ventana», or just the space when the window has no name of its own.
    private static func name(of panelID: UUID, in workspace: Workspace) -> String {
        let space = workspace.customTitle ?? workspace.title
        let window = workspace.panelCustomTitles[panelID]
            ?? workspace.uniConnectLocalWindowsByPanelId[panelID]?.visibleName
            ?? workspace.panelTitles[panelID]
        guard let window, !window.isEmpty, window != space else { return space }
        return "\(space) · \(window)"
    }
}
