import AppKit
import SwiftUI

/// Reports one immutable rail row to its window's single AppKit flyout controller.
struct UniConnectSidebarFlyoutAnchor: NSViewRepresentable {
    let snapshot: UniConnectChipSnapshot
    let actions: UniConnectChipActions
    let isFocused: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> UniConnectSidebarFlyoutAnchorView {
        let view = UniConnectSidebarFlyoutAnchorView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: UniConnectSidebarFlyoutAnchorView, context: Context) {
        update(nsView)
    }

    static func dismantleNSView(_ nsView: UniConnectSidebarFlyoutAnchorView, coordinator: ()) {
        nsView.unregisterCurrentSource()
    }

    private func update(_ view: UniConnectSidebarFlyoutAnchorView) {
        view.snapshot = snapshot
        view.actions = actions
        view.reduceMotion = reduceMotion
        view.reduceTransparency = reduceTransparency
        view.setFocused(isFocused)
        view.publishContextIfPossible()
    }
}
