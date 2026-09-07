import AppKit
import CmuxSettingsUI
import SwiftUI

/// Retains the Settings window independently of SwiftUI scene restoration.
@MainActor
final class SettingsWindowController {
    private let runtime: SettingsRuntime
    private var window: NSWindow?

    init(runtime: SettingsRuntime) {
        self.runtime = runtime
    }

    func show() {
        if let window {
            SettingsWindowPresenter.configure(window: window)
            SettingsWindowPresenter.refocusIfVisible()
            return
        }
        let target = SettingsWindowPresenter.consumePendingNavigationTarget()
        _ = SettingsWindowPresenter.consumePendingContentNavigationTarget()
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsWindowContent(runtime: runtime, initialTarget: target)
        ))
        window.title = String(localized: "settings.title", defaultValue: "Ajustes")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 980, height: 680))
        window.center()
        self.window = window
        SettingsWindowPresenter.configure(window: window)
        SettingsWindowPresenter.refocusIfVisible()
    }
}
