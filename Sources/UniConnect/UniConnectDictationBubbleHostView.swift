import AppKit

/// The floating button's AppKit shell: it takes every mouse event over the SwiftUI drawing.
///
/// A click records or stops (Option-click opens the box; on the pill, a click brings the button
/// back); a drag moves the window with the pointer, the pill only along its edge; right click or
/// Control-click opens the button's menu. Hover is passed to ``UniConnectDictationBubbleState`` for the drawing.
@MainActor
final class UniConnectDictationBubbleHostView: NSView {
    /// A click that was not a drag, with the modifier keys held.
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// The drag ended with the window at this frame.
    var onDragEnded: ((NSRect) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let state: UniConnectDictationBubbleState
    private var dragStart: (mouse: NSPoint, frame: NSRect)?
    private var dragged = false
    private var tracking: NSTrackingArea?

    /// Pointer travel that turns a press into a drag.
    private static let dragThreshold: CGFloat = 3

    init(state: UniConnectDictationBubbleState, content: NSView) {
        self.state = state
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        state.hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        state.hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - start.mouse.x
        let dy = location.y - start.mouse.y
        if !dragged {
            guard hypot(dx, dy) >= Self.dragThreshold else { return }
            dragged = true
            state.dragging = true
        }
        let origin = state.layout.docked
            ? NSPoint(x: start.frame.minX, y: start.frame.minY + dy)
            : NSPoint(x: start.frame.minX + dx, y: start.frame.minY + dy)
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragged = dragged
        dragStart = nil
        dragged = false
        state.dragging = false
        guard let window else { return }
        if wasDragged {
            onDragEnded?(window.frame)
        } else {
            onClick?(event.modifierFlags)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
