import AppKit

/// Full-window passthrough host that captures hits only in the card and corridor.
@MainActor
final class UniConnectSidebarFlyoutContainerView: NSView {
    var interactiveLayout: UniConnectSidebarFlyoutLayout?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let interactiveLayout,
              interactiveLayout.acceptsHit(at: point) else {
            return nil
        }
        return super.hitTest(point)
    }
}
