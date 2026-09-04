import AppKit

/// Native tracking surface that publishes one rail tile to its window controller.
@MainActor
final class UniConnectSidebarFlyoutAnchorView: NSView {
    var snapshot: UniConnectChipSnapshot?
    var actions: UniConnectChipActions?
    var reduceMotion = false
    var reduceTransparency = false

    private var trackedSourceID: UUID?
    private weak var trackedWindow: NSWindow?
    private var lastFocused = false
    private var reportedFocused = false
    private var trackingAreaReference: NSTrackingArea?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishContextIfPossible()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        publishContextIfPossible()
    }

    override func layout() {
        super.layout()
        publishContextIfPossible()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window, let snapshot else { return }
        publishContextIfPossible()
        uniConnectSidebarFlyoutController(for: window)
            .pointerChanged(id: snapshot.id, isInside: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard let window, let snapshot else { return }
        uniConnectSidebarFlyoutController(for: window)
            .pointerChanged(id: snapshot.id, isInside: false)
    }

    func setFocused(_ isFocused: Bool) {
        guard lastFocused != isFocused else { return }
        lastFocused = isFocused
        guard let window, let snapshot else {
            reportedFocused = false
            return
        }
        publishContextIfPossible()
        uniConnectSidebarFlyoutController(for: window)
            .focusChanged(id: snapshot.id, isFocused: isFocused)
        reportedFocused = isFocused
    }

    func publishContextIfPossible() {
        guard let window, let snapshot, let actions else { return }
        if let trackedSourceID,
           trackedSourceID != snapshot.id || trackedWindow !== window {
            if let trackedWindow {
                uniConnectSidebarFlyoutController(for: trackedWindow).removeSource(id: trackedSourceID)
            }
            reportedFocused = false
        }
        trackedSourceID = snapshot.id
        trackedWindow = window
        let frameInWindow = convert(bounds, to: nil)
        uniConnectSidebarFlyoutController(for: window).updateSource(
            id: snapshot.id,
            context: .init(
                snapshot: snapshot,
                actions: actions,
                anchorFrameInWindow: frameInWindow,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency
            )
        )
        if lastFocused && !reportedFocused {
            uniConnectSidebarFlyoutController(for: window)
                .focusChanged(id: snapshot.id, isFocused: true)
            reportedFocused = true
        }
    }

    func unregisterCurrentSource() {
        guard let trackedWindow, let trackedSourceID else { return }
        uniConnectSidebarFlyoutController(for: trackedWindow).removeSource(id: trackedSourceID)
        self.trackedSourceID = nil
        self.trackedWindow = nil
        reportedFocused = false
    }
}
