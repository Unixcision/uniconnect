import AppKit
import Testing

@testable import cmux_DEV

@Suite("Notifications popover placement")
@MainActor
struct NotificationsPopoverPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 950)

    @Test("A rail anchor near the bottom yields a popover short enough to stay centred on it")
    func sideEdgeAnchorNearBottomShrinksToFit() {
        // The compact rail's bell sits ~120pt above the bottom of the screen. A
        // side popover is centred on its anchor, so it may only be twice the
        // smaller gap — anything taller gets slid against the edge by AppKit.
        let bell = CGRect(x: 20, y: 110, width: 36, height: 36)
        let height = NotificationsPopoverPlacement.availableHeight(
            anchorFrameOnScreen: bell,
            visibleFrame: screen,
            preferredEdge: .maxX,
            margin: 24
        )
        #expect(height == CGFloat(208))
        let centre = bell.midY
        #expect(centre - (height / 2) >= screen.minY)
        #expect(centre + (height / 2) <= screen.maxY)
    }

    @Test("A centred anchor is limited by the shorter side, not the taller one")
    func sideEdgeUsesSmallerGap() {
        let anchor = CGRect(x: 20, y: 700, width: 36, height: 36)
        let height = NotificationsPopoverPlacement.availableHeight(
            anchorFrameOnScreen: anchor,
            visibleFrame: screen,
            preferredEdge: .maxX,
            margin: 24
        )
        // 232 above the anchor's centre, 718 below it: the smaller one governs.
        #expect(height == CGFloat(416))
    }

    @Test("A header anchor gets the larger of the two vertical gaps")
    func verticalEdgeUsesLargerGap() {
        // The expanded header's bell sits at the top, so nearly the whole screen
        // is available below it.
        let bell = CGRect(x: 400, y: 900, width: 26, height: 22)
        let height = NotificationsPopoverPlacement.availableHeight(
            anchorFrameOnScreen: bell,
            visibleFrame: screen,
            preferredEdge: .maxY,
            margin: 24
        )
        #expect(height == CGFloat(876))
    }

    @Test("An anchor flush against an edge never yields a negative height")
    func degenerateAnchorClampsToZero() {
        let flush = CGRect(x: 20, y: 0, width: 36, height: 4)
        let height = NotificationsPopoverPlacement.availableHeight(
            anchorFrameOnScreen: flush,
            visibleFrame: screen,
            preferredEdge: .maxX,
            margin: 24
        )
        #expect(height == CGFloat(0))
    }

    @Test("Anchor space is a hard cap even when it is below the normal minimum")
    func anchorSpaceOverridesPreferredMinimum() {
        let height = NotificationsPopoverPlacement.clampedHeight(
            requested: 460,
            minimum: 320,
            maximum: 900,
            anchorAvailableHeight: 208
        )

        #expect(height == CGFloat(208))
    }

    @Test("The normal minimum remains in force when the anchor has enough room")
    func preferredMinimumAppliesWithoutTightAnchor() {
        let height = NotificationsPopoverPlacement.clampedHeight(
            requested: 100,
            minimum: 320,
            maximum: 900,
            anchorAvailableHeight: nil
        )

        #expect(height == CGFloat(320))
    }

    @Test("Resize clamping respects both the general maximum and the anchor cap")
    func resizeClampingUsesHardestUpperBound() {
        #expect(NotificationsPopoverPlacement.clampedHeight(
            requested: 800,
            minimum: 320,
            maximum: 640,
            anchorAvailableHeight: 700
        ) == CGFloat(640))
        #expect(NotificationsPopoverPlacement.clampedHeight(
            requested: 800,
            minimum: 320,
            maximum: 640,
            anchorAvailableHeight: 208
        ) == CGFloat(208))
    }

    @Test("Anchor views preserve explicit compact and expanded popover edges")
    func anchorCarriesDeclaredPresentationEdge() {
        let anchor = AnchorNSView()
        #expect(NotificationsAnchorRegistry.shared.preferredEdge(for: anchor) == .maxY)

        anchor.notificationsPopoverPreferredEdge = .maxX
        #expect(NotificationsAnchorRegistry.shared.preferredEdge(for: anchor) == .maxX)

        let legacyAnchor = NSView()
        #expect(NotificationsAnchorRegistry.shared.preferredEdge(for: legacyAnchor) == .maxY)
    }
}
