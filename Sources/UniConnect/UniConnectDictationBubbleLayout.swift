import CoreGraphics

/// Where «Dictado»'s floating button sits.
///
/// The button lives against the left or right edge of the screen's visible area, at a height, either
/// as the round button or tucked into that edge as a pill, the way Android's edge handles do. All
/// frames are in screen coordinates (origin at the bottom left), clamped inside the visible area.
struct UniConnectDictationBubbleLayout: Equatable, Sendable {
    /// Which side of the screen the button is against.
    enum Edge: String, Sendable {
        case left
        case right
    }

    var edge: Edge = .right
    /// From the bottom of the visible area to the bottom of the round button.
    var bottomOffset: CGFloat = 96
    /// Tucked into the edge as a pill.
    var docked = false

    /// Size of the round button.
    static let bubbleDiameter: CGFloat = 52
    /// Transparent room around the round button inside its window, so the hover growth and the
    /// shadow are drawn whole instead of being cut flat by the window's edges.
    static let bubblePadding: CGFloat = 10
    /// Gap between the button (or the box) and the screen's edges.
    static let margin: CGFloat = 16
    /// The pill's window: a strip against the edge, wider and taller than the pill it draws so it
    /// is easy to hit.
    static let pillWindowSize = CGSize(width: 18, height: 72)
    /// The box's size when the screen has room for it.
    static let boxSize = CGSize(width: 420, height: 640)
    /// Gap between the button and the box.
    static let boxGap: CGFloat = 12
    /// How much of the button has to be past the edge, when it is dropped, to tuck itself in.
    static let dockOverhangFraction: CGFloat = 0.35

    /// The round button.
    func bubbleFrame(in visible: CGRect) -> CGRect {
        let diameter = Self.bubbleDiameter
        let x = edge == .right ? visible.maxX - Self.margin - diameter : visible.minX + Self.margin
        let y = Self.clampedY(visible.minY + bottomOffset, height: diameter, in: visible)
        return CGRect(x: x, y: y, width: diameter, height: diameter)
    }

    /// The pill's window, flush with the edge and centred on where the button was.
    func pillFrame(in visible: CGRect) -> CGRect {
        let size = Self.pillWindowSize
        let x = edge == .right ? visible.maxX - size.width : visible.minX
        let centerY = visible.minY + bottomOffset + Self.bubbleDiameter / 2
        let y = Self.clampedY(centerY - size.height / 2, height: size.height, in: visible)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The round button's window: the button with its transparent padding around it.
    func bubbleWindowFrame(in visible: CGRect) -> CGRect {
        bubbleFrame(in: visible).insetBy(dx: -Self.bubblePadding, dy: -Self.bubblePadding)
    }

    /// The floating window's frame for the current state.
    func frame(in visible: CGRect) -> CGRect {
        docked ? pillFrame(in: visible) : bubbleWindowFrame(in: visible)
    }

    /// The round button inside a window frame of the round button (the inverse of
    /// ``bubbleWindowFrame(in:)``), for a window the user just dropped.
    static func bubble(inWindow frame: CGRect) -> CGRect {
        frame.insetBy(dx: bubblePadding, dy: bubblePadding)
    }

    /// The box: beside the button, on the side away from the edge, bottom-aligned with it, and
    /// inside the visible area.
    func boxFrame(in visible: CGRect) -> CGRect {
        let bubble = bubbleFrame(in: visible)
        let width = min(Self.boxSize.width, max(0, visible.width - 2 * Self.margin))
        let height = min(Self.boxSize.height, max(0, visible.height - 2 * Self.margin))
        var x = edge == .right ? bubble.minX - Self.boxGap - width : bubble.maxX + Self.boxGap
        x = min(max(x, visible.minX + Self.margin), visible.maxX - Self.margin - width)
        let y = Self.clampedY(bubble.minY, height: height, in: visible)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Where a round button dropped at `frame` settles: against the nearer edge, at that height,
    /// and tucked into that edge when it was dropped partly past it.
    static func settled(droppedAt frame: CGRect, in visible: CGRect) -> UniConnectDictationBubbleLayout {
        let edge: Edge = frame.midX >= visible.midX ? .right : .left
        let overhang = edge == .right ? frame.maxX - visible.maxX : visible.minX - frame.minX
        return UniConnectDictationBubbleLayout(
            edge: edge,
            bottomOffset: clampedOffset(frame.minY - visible.minY, in: visible),
            docked: overhang >= bubbleDiameter * dockOverhangFraction
        )
    }

    /// A pill dragged along its edge: same edge, new height, still tucked in.
    static func slid(pillAt frame: CGRect, edge: Edge, in visible: CGRect) -> UniConnectDictationBubbleLayout {
        UniConnectDictationBubbleLayout(
            edge: edge,
            bottomOffset: clampedOffset(frame.midY - bubbleDiameter / 2 - visible.minY, in: visible),
            docked: true
        )
    }

    private static func clampedOffset(_ offset: CGFloat, in visible: CGRect) -> CGFloat {
        let highest = max(margin, visible.height - margin - bubbleDiameter)
        return min(max(offset, margin), highest)
    }

    private static func clampedY(_ y: CGFloat, height: CGFloat, in visible: CGRect) -> CGFloat {
        let lowest = visible.minY + margin
        let highest = max(lowest, visible.maxY - margin - height)
        return min(max(y, lowest), highest)
    }
}
