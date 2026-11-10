import AppKit
import SwiftUI

/// The «Cuentas de IA» window: a separate, movable, resizable window that remembers its frame,
/// with «Siempre delante». It reads only while visible.
@MainActor
final class UniConnectAccountsWindowController: NSObject, NSWindowDelegate {
    private let model: UniConnectAccountsModel
    private var window: NSWindow?

    init(model: UniConnectAccountsModel) {
        self.model = model
    }

    func show() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            model.startAutoRefresh()
            return
        }
        let root = UniConnectAccountsView(model: model) { [weak self] onTop in
            self?.window?.level = onTop ? .floating : .normal
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = String(localized: "uniconnect.accounts.title", defaultValue: "Cuentas de IA")
        window.identifier = NSUserInterfaceItemIdentifier("uniconnect.accounts")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.center()
        window.setFrameAutosaveName("uniconnect.accounts")
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        model.startAutoRefresh()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopAutoRefresh()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.stopAutoRefresh()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.startAutoRefresh()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        if window.occlusionState.contains(.visible) {
            model.startAutoRefresh()
        } else {
            model.stopAutoRefresh()
        }
    }
}
