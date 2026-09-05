import AppKit
import SwiftUI

/// Owns the private-network authorization window, composed once by the executable.
@MainActor
final class UniConnectMobileAccessWindowController {
    private let model: UniConnectMobileAccessViewModel
    private var window: NSWindow?

    init(model: UniConnectMobileAccessViewModel) {
        self.model = model
    }

    func show() {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: UniConnectMobileAccessView(model: model)
        ))
        window.title = String(localized: "uniconnect.mobile.access.title", defaultValue: "Acceso remoto")
        window.identifier = NSUserInterfaceItemIdentifier("uniconnect.mobileAccess")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 660))
        window.minSize = NSSize(width: 440, height: 400)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
