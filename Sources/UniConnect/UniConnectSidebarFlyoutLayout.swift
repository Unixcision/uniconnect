import AppKit

/// Geometry policy for clamping a rail flyout and its pointer corridor to one window.
struct UniConnectSidebarFlyoutLayout: Equatable {
    static let cardWidth: CGFloat = 306
    static let horizontalGap: CGFloat = 10
    static let windowMargin: CGFloat = 12
    static let rowHeight: CGFloat = 30
    static let minimumCardHeight: CGFloat = 122
    static let maximumCardHeight: CGFloat = 342

    let cardFrame: CGRect
    let corridorFrame: CGRect

    static func preferredCardHeight(windowCount: Int) -> CGFloat {
        let rowsHeight = CGFloat(min(max(windowCount, 0), 7)) * rowHeight
        return min(maximumCardHeight, minimumCardHeight + rowsHeight)
    }

    static func resolve(
        containerBounds: CGRect,
        anchorFrame: CGRect,
        windowCount: Int
    ) -> UniConnectSidebarFlyoutLayout {
        let height = min(
            preferredCardHeight(windowCount: windowCount),
            max(1, containerBounds.height - windowMargin * 2)
        )
        let width = min(cardWidth, max(1, containerBounds.width - windowMargin * 2))

        let preferredRightX = anchorFrame.maxX + horizontalGap
        let leftCandidateX = anchorFrame.minX - horizontalGap - width
        let maximumX = containerBounds.maxX - windowMargin - width
        let x: CGFloat
        if preferredRightX <= maximumX {
            x = max(containerBounds.minX + windowMargin, preferredRightX)
        } else {
            x = max(containerBounds.minX + windowMargin, leftCandidateX)
        }

        let centeredY = anchorFrame.midY - height / 2
        let y = min(
            max(centeredY, containerBounds.minY + windowMargin),
            containerBounds.maxY - windowMargin - height
        )
        let cardFrame = CGRect(x: x, y: y, width: width, height: height).integral

        let corridorMinX: CGFloat
        let corridorMaxX: CGFloat
        if cardFrame.minX >= anchorFrame.maxX {
            corridorMinX = anchorFrame.maxX
            corridorMaxX = cardFrame.minX
        } else {
            corridorMinX = cardFrame.maxX
            corridorMaxX = anchorFrame.minX
        }
        let corridorFrame = CGRect(
            x: corridorMinX,
            y: min(anchorFrame.minY, cardFrame.minY) - 4,
            width: max(1, corridorMaxX - corridorMinX),
            height: max(anchorFrame.maxY, cardFrame.maxY) - min(anchorFrame.minY, cardFrame.minY) + 8
        ).intersection(containerBounds)

        return UniConnectSidebarFlyoutLayout(cardFrame: cardFrame, corridorFrame: corridorFrame)
    }

    func acceptsHit(at point: CGPoint) -> Bool {
        cardFrame.contains(point) || corridorFrame.contains(point)
    }
}
