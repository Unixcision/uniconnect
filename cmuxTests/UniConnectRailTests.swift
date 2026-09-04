import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class UniConnectRailTests: XCTestCase {
    func testMonogramUsesWordsCamelCaseAndStableFallbacks() {
        XCTAssertEqual(UniConnectChipSnapshot.monogram(for: "notbetting-prepro"), "NP")
        XCTAssertEqual(UniConnectChipSnapshot.monogram(for: "mcpProjekt"), "MP")
        XCTAssertEqual(UniConnectChipSnapshot.monogram(for: "cmux"), "CM")
        XCTAssertEqual(UniConnectChipSnapshot.monogram(for: ""), "•")
    }

    func testFallbackColourIsDeterministicAndComesFromCuratedPalette() {
        let id = UUID(uuidString: "01A0677F-AE4E-7FB3-8BAF-744B2D3DE0E5")!
        let first = UniConnectChipSnapshot.fallbackColorHex(for: id)
        let second = UniConnectChipSnapshot.fallbackColorHex(for: id)

        XCTAssertEqual(first, second)
        XCTAssertTrue([
            "#3769B4", "#B3366A", "#C54A3C", "#A8B747",
            "#C53A68", "#55A84E", "#4899AA", "#852FB1",
            "#4857B8", "#83AB48", "#D15B31", "#2DA08F",
        ].contains(first))
    }

    func testSnapshotEqualityTracksOnlyImmutableRenderingValues() {
        let workspaceID = UUID()
        let panelID = UUID()
        let window = UniConnectWindowSnapshot(
            id: panelID,
            workspaceID: workspaceID,
            title: "Shell",
            isFocused: true,
            isDisconnected: false,
            isUnread: false
        )
        let first = Self.snapshot(workspaceID: workspaceID, windows: [window])
        let equalCopy = Self.snapshot(workspaceID: workspaceID, windows: [window])
        let changed = Self.snapshot(workspaceID: workspaceID, windows: [])

        XCTAssertEqual(first, equalCopy)
        XCTAssertNotEqual(first, changed)
    }

    func testInitialHoverDelayImmediateSwitchAndCloseDelay() {
        let first = UUID()
        let second = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()

        XCTAssertEqual(
            policy.reduce(.pointerEntered(first)),
            .scheduleShow(first, milliseconds: 260)
        )
        XCTAssertEqual(policy.reduce(.showDelayElapsed(first)), .showNow(first))
        XCTAssertEqual(policy.visibleSourceID, first)
        XCTAssertEqual(policy.reduce(.pointerEntered(second)), .showNow(second))
        XCTAssertEqual(policy.visibleSourceID, second)
        XCTAssertEqual(
            policy.reduce(.pointerExited(second)),
            .scheduleHide(milliseconds: 140)
        )
        XCTAssertEqual(policy.reduce(.closeDelayElapsed), .hideNow)
        XCTAssertNil(policy.visibleSourceID)
    }

    func testFocusOpensImmediatelyAndHoverReturnsToFocusedChip() {
        let focused = UUID()
        let hovered = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()

        XCTAssertEqual(policy.reduce(.focusChanged(focused, isFocused: true)), .showNow(focused))
        XCTAssertEqual(policy.reduce(.pointerEntered(hovered)), .showNow(hovered))
        XCTAssertEqual(policy.reduce(.pointerExited(hovered)), .showNow(focused))
        XCTAssertEqual(policy.visibleSourceID, focused)
        XCTAssertEqual(policy.reduce(.escape), .hideNow)
    }

    func testPointerCorridorCancelsThenRestartsDeferredClose() {
        let id = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()
        _ = policy.reduce(.pointerEntered(id))
        _ = policy.reduce(.showDelayElapsed(id))

        XCTAssertEqual(
            policy.reduce(.pointerExited(id)),
            .scheduleHide(milliseconds: 140)
        )
        XCTAssertEqual(
            policy.reduce(.corridorChanged(isInside: true)),
            .cancelScheduledHide
        )
        XCTAssertEqual(
            policy.reduce(.corridorChanged(isInside: false)),
            .scheduleHide(milliseconds: 140)
        )
    }

    func testFlyoutKeyboardFocusKeepsCardOpenAfterRailTileLosesFocus() {
        let id = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()
        _ = policy.reduce(.focusChanged(id, isFocused: true))

        XCTAssertEqual(
            policy.reduce(.corridorChanged(isInside: true)),
            .cancelScheduledHide
        )
        XCTAssertEqual(
            policy.reduce(.focusChanged(id, isFocused: false)),
            .none
        )
        XCTAssertEqual(policy.visibleSourceID, id)
        XCTAssertEqual(
            policy.reduce(.corridorChanged(isInside: false)),
            .scheduleHide(milliseconds: 140)
        )
        XCTAssertEqual(policy.reduce(.closeDelayElapsed), .hideNow)
    }

    func testRemovingVisibleSourceClearsCorridorAndHidesImmediately() {
        let id = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()
        _ = policy.reduce(.focusChanged(id, isFocused: true))
        _ = policy.reduce(.corridorChanged(isInside: true))

        XCTAssertEqual(policy.reduce(.sourceRemoved(id)), .hideNow)
        XCTAssertNil(policy.visibleSourceID)
        XCTAssertFalse(policy.isInsideCorridor)
    }

    func testLayoutClampsCardAndOnlyAcceptsCardOrCorridorHits() {
        let bounds = CGRect(x: 0, y: 0, width: 520, height: 300)
        let anchor = CGRect(x: 18, y: 252, width: 36, height: 36)
        let layout = UniConnectSidebarFlyoutLayout.resolve(
            containerBounds: bounds,
            anchorFrame: anchor,
            windowCount: 12
        )

        XCTAssertGreaterThanOrEqual(layout.cardFrame.minX, 12)
        XCTAssertGreaterThanOrEqual(layout.cardFrame.minY, 12)
        XCTAssertLessThanOrEqual(layout.cardFrame.maxX, bounds.maxX - 12)
        XCTAssertLessThanOrEqual(layout.cardFrame.maxY, bounds.maxY - 12)
        XCTAssertTrue(layout.acceptsHit(at: CGPoint(x: layout.cardFrame.midX, y: layout.cardFrame.midY)))
        XCTAssertTrue(layout.acceptsHit(at: CGPoint(x: layout.corridorFrame.midX, y: anchor.midY)))
        XCTAssertFalse(layout.acceptsHit(at: CGPoint(x: bounds.maxX - 1, y: bounds.minY + 1)))
    }

    func testLayoutFlipsToLeadingSideWhenTrailingSpaceIsUnavailable() {
        let bounds = CGRect(x: 0, y: 0, width: 520, height: 360)
        let anchor = CGRect(x: 470, y: 170, width: 36, height: 36)
        let layout = UniConnectSidebarFlyoutLayout.resolve(
            containerBounds: bounds,
            anchorFrame: anchor,
            windowCount: 2
        )

        XCTAssertLessThan(layout.cardFrame.maxX, anchor.minX)
        XCTAssertEqual(layout.corridorFrame.minX, layout.cardFrame.maxX, accuracy: 1)
        XCTAssertEqual(layout.corridorFrame.maxX, anchor.minX, accuracy: 1)
    }

    func testOverlayContainerPassesThroughOutsideCardAndCorridor() {
        let container = UniConnectSidebarFlyoutContainerView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )
        let layout = UniConnectSidebarFlyoutLayout(
            cardFrame: CGRect(x: 90, y: 80, width: 306, height: 160),
            corridorFrame: CGRect(x: 54, y: 80, width: 36, height: 160)
        )
        let card = NSView(frame: layout.cardFrame)
        container.addSubview(card)
        container.interactiveLayout = layout

        XCTAssertNil(container.hitTest(CGPoint(x: 499, y: 1)))
        XCTAssertTrue(container.hitTest(CGPoint(x: 120, y: 100)) === card)
        XCTAssertNotNil(container.hitTest(CGPoint(x: 70, y: 100)))
    }

    func testWindowActionPreservesExactWorkspaceAndPanelIdentifiers() {
        let workspaceID = UUID()
        let panelID = UUID()
        var selection: (UUID, UUID)?
        let actions = Self.actions { selectedWorkspaceID, selectedPanelID in
            selection = (selectedWorkspaceID, selectedPanelID)
        }

        actions.selectWindow(workspaceID, panelID)

        XCTAssertEqual(selection?.0, workspaceID)
        XCTAssertEqual(selection?.1, panelID)
    }

    func testOverlayInstallationDoesNotBecomeFirstResponder() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let responder = UniConnectFirstResponderProbeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(responder)
        XCTAssertTrue(window.makeFirstResponder(responder))
        let originalResponder = window.firstResponder

        let controller = UniConnectSidebarFlyoutOverlayController(window: window)

        XCTAssertFalse(controller.debugAcceptsFirstResponder)
        XCTAssertTrue(window.firstResponder === originalResponder)
    }

    private static func snapshot(
        workspaceID: UUID,
        windows: [UniConnectWindowSnapshot]
    ) -> UniConnectChipSnapshot {
        UniConnectChipSnapshot(
            id: workspaceID,
            workspaceID: workspaceID,
            groupID: nil,
            isGroupCollapsed: false,
            displayName: "Example",
            secondaryLabel: nil,
            symbolName: nil,
            monogram: "EX",
            colorHex: "#3769B4",
            connectionKind: .local,
            isDisconnected: false,
            isConnecting: false,
            isSelected: false,
            isPinned: false,
            unreadCount: 0,
            bridgeStatus: nil,
            windows: windows,
            shortcutDigit: nil
        )
    }

    private static func actions(
        selectWindow: @escaping @MainActor (UUID, UUID) -> Void
    ) -> UniConnectChipActions {
        UniConnectChipActions(
            selectBox: {},
            selectWindow: selectWindow,
            performLocalWindowAction: { _, _, _ in },
            reconnectSSHWindowNow: { _, _ in },
            renameBox: {},
            editSSHConnection: nil,
            setPinned: { _ in },
            createWindow: {},
            reconnectSSHWindowsNow: {},
            updateClaude: {},
            markRead: {},
            markUnread: {},
            closeBox: {},
            toggleGroup: nil
        )
    }
}

private final class UniConnectFirstResponderProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
