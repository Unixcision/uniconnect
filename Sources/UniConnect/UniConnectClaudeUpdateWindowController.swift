import AppKit
import SwiftUI

/// Hosts the updater and blocks unrelated windows only while sessions are being replaced.
@MainActor
final class UniConnectClaudeUpdateWindowController: NSWindowController, NSWindowDelegate {
    private let model: UniConnectClaudeUpdateModel
    private let onClose: () -> Void
    private var suppressCloseCallback = false
    private var ownsSafetyModalSession = false

    init(
        model: UniConnectClaudeUpdateModel,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.onClose = onClose
        let root = UniConnectClaudeUpdateView(
            model: model,
            onConfirm: onConfirm,
            onCancel: onCancel,
            onClose: onClose
        )
        let hostingController = NSHostingController(rootView: root)
        let window = NSPanel(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "claudeUpdate.title", defaultValue: "Update Claude")
        window.setContentSize(NSSize(width: 520, height: 560))
        window.minSize = NSSize(width: 460, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.stage != .running
    }

    func windowDidClose(_ notification: Notification) {
        endSafetyModal()
        guard !suppressCloseCallback else { return }
        onClose()
    }

    /// Runs a modal event loop for the mutation and mandatory-restoration portion of the flow.
    func beginSafetyModal() {
        guard let window, !ownsSafetyModalSession, NSApp.modalWindow == nil else { return }
        ownsSafetyModalSession = true
        NSApp.runModal(for: window)
    }

    /// Releases other UniConnect windows after all armed restoration obligations are reconciled.
    func endSafetyModal() {
        guard ownsSafetyModalSession else { return }
        ownsSafetyModalSession = false
        NSApp.stopModal()
    }

    func closeWithoutCallback() {
        endSafetyModal()
        suppressCloseCallback = true
        close()
        suppressCloseCallback = false
    }
}
