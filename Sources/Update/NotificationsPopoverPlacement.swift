import AppKit

/// Works out how tall the notifications popover may be so that AppKit can place
/// it against its anchor without pushing it off screen.
///
/// Capping the popover against the screen's size is not enough. `NSPopover`
/// positions itself *relative to its anchor* — centred on it for a side edge,
/// extending away from it for a top or bottom edge — so a popover that fits the
/// screen can still overflow when its anchor sits near an edge. AppKit then
/// slides it back inside, which leaves it flush against that edge with its arrow
/// dragged away from the control. Deriving the height from the anchor's own
/// position avoids the slide entirely.
///
/// ```swift
/// let height = NotificationsPopoverPlacement.availableHeight(
///     anchorFrameOnScreen: frame,
///     visibleFrame: screen.visibleFrame,
///     preferredEdge: .maxX,
///     margin: 24
/// )
/// ```
enum NotificationsPopoverPlacement {
    /// Clamps a requested popover height without allowing the preferred minimum
    /// to overrule the hard space limit imposed by its anchor.
    ///
    /// `minimum` is the normal resizable-panel floor. When the anchor leaves
    /// less room than that (for example, a compact rail bell near the bottom of
    /// the screen), the available height wins so AppKit does not slide the
    /// popover against a screen edge.
    static func clampedHeight(
        requested: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        anchorAvailableHeight: CGFloat?
    ) -> CGFloat {
        let hardMaximum = max(0, maximum)
        let upperBound = anchorAvailableHeight.map {
            min(hardMaximum, max(0, $0))
        } ?? hardMaximum
        let effectiveMinimum = min(max(0, minimum), upperBound)
        return min(upperBound, max(effectiveMinimum, requested))
    }

    /// The tallest popover that still fits beside or below its anchor.
    ///
    /// - Parameters:
    ///   - anchorFrameOnScreen: The anchoring control, in screen coordinates.
    ///   - visibleFrame: The screen area available to windows.
    ///   - preferredEdge: The edge the popover is asked to appear on. Side edges
    ///     are centred on the anchor, so the usable height is twice the smaller
    ///     gap above and below it; top and bottom edges extend one way, so it is
    ///     the larger of the two gaps.
    ///   - margin: Clearance to leave between the popover and the screen edge.
    /// - Returns: The available height, never negative.
    static func availableHeight(
        anchorFrameOnScreen: CGRect,
        visibleFrame: CGRect,
        preferredEdge: NSRectEdge,
        margin: CGFloat
    ) -> CGFloat {
        switch preferredEdge {
        case .maxX, .minX:
            let centerY = anchorFrameOnScreen.midY
            let above = visibleFrame.maxY - centerY
            let below = centerY - visibleFrame.minY
            return max(0, (min(above, below) * 2) - (margin * 2))
        default:
            let above = visibleFrame.maxY - anchorFrameOnScreen.maxY
            let below = anchorFrameOnScreen.minY - visibleFrame.minY
            return max(0, max(above, below) - margin)
        }
    }

    /// The available height for a live anchor view, or `nil` when its geometry
    /// cannot be resolved.
    ///
    /// - Parameters:
    ///   - anchor: The anchoring view; must be in a window on a screen.
    ///   - preferredEdge: The edge the popover is asked to appear on.
    ///   - margin: Clearance to leave between the popover and the screen edge.
    /// - Returns: The available height, or `nil` if the anchor is not on screen.
    @MainActor
    static func availableHeight(
        for anchor: NSView,
        preferredEdge: NSRectEdge,
        margin: CGFloat
    ) -> CGFloat? {
        guard let window = anchor.window,
              let screen = window.screen ?? NSScreen.main else {
            return nil
        }
        let frameInWindow = anchor.convert(anchor.bounds, to: nil)
        guard !frameInWindow.isEmpty else { return nil }
        return availableHeight(
            anchorFrameOnScreen: window.convertToScreen(frameInWindow),
            visibleFrame: screen.visibleFrame,
            preferredEdge: preferredEdge,
            margin: margin
        )
    }
}
