import AppKit
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class UniConnectRailTests: XCTestCase {
    func testNotificationBadgeTextCapsAtNinetyNine() {
        XCTAssertNil(UniConnectRailSidebar.notificationBadgeText(unreadCount: 0))
        XCTAssertNil(UniConnectRailSidebar.notificationBadgeText(unreadCount: -1))
        XCTAssertEqual(UniConnectRailSidebar.notificationBadgeText(unreadCount: 1), "1")
        XCTAssertEqual(UniConnectRailSidebar.notificationBadgeText(unreadCount: 99), "99")
        XCTAssertEqual(UniConnectRailSidebar.notificationBadgeText(unreadCount: 100), "99+")
    }

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

    func testRailIdentityContrastAcrossCompositedColourMatrix() throws {
        let palette = [
            "#3769B4", "#B3366A", "#C54A3C", "#A8B747",
            "#C53A68", "#55A84E", "#4899AA", "#852FB1",
            "#4857B8", "#83AB48", "#D15B31", "#2DA08F",
        ]
        let appearances: [(scheme: ColorScheme, surface: NSColor)] = [
            (
                .dark,
                NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            ),
            (
                .light,
                NSColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1)
            ),
        ]
        let layerOpacities: [CGFloat] = [1, 0.84, 0.72, 0.64, 0.52]
        let gradientOpacities = [
            UniConnectRailPalette.railGradientMidpointOpacity,
            UniConnectRailPalette.flyoutGradientMidpointOpacity,
        ]

        for hex in palette {
            for appearance in appearances {
                let baseColor = try XCTUnwrap(
                    WorkspaceTabColorSettings.displayNSColor(
                        hex: hex,
                        colorScheme: appearance.scheme
                    )
                )
                for layerOpacity in layerOpacities {
                    for gradientOpacity in gradientOpacities {
                        let background = UniConnectRailPalette.identityBackgroundNSColor(
                            baseColor: baseColor,
                            layerOpacity: layerOpacity,
                            gradientOpacity: gradientOpacity,
                            surfaceColor: appearance.surface
                        )
                        let foreground = UniConnectRailPalette.identityForegroundNSColor(
                            baseColor: baseColor,
                            layerOpacity: layerOpacity,
                            gradientOpacity: gradientOpacity,
                            surfaceColor: appearance.surface
                        )
                        XCTAssertGreaterThanOrEqual(
                            cmuxContrastRatio(foreground: foreground, background: background),
                            4.5,
                            "\(hex), \(appearance.scheme), layer \(layerOpacity), gradient \(gradientOpacity)"
                        )
                    }
                }
            }
        }

        XCTAssertGreaterThanOrEqual(
            cmuxContrastRatio(
                foreground: .white,
                background: UniConnectRailPalette.unreadNSColor
            ),
            4.5
        )
    }

    func testRailIdentityBackgroundCombinesLayerAndGradientOpacity() {
        let background = UniConnectRailPalette.identityBackgroundNSColor(
            baseColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            layerOpacity: 0.5,
            gradientOpacity: 0.8,
            surfaceColor: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        )
        let srgb = background.usingColorSpace(.sRGB) ?? background
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        XCTAssertEqual(red, 0.4, accuracy: 0.0001)
        XCTAssertEqual(green, 0, accuracy: 0.0001)
        XCTAssertEqual(blue, 0.6, accuracy: 0.0001)
        XCTAssertEqual(alpha, 1, accuracy: 0.0001)
    }

    func testRailSurfaceColoursResolveFromExplicitScheme() {
        let darkAppearance = UniConnectRailPalette.appKitAppearance(for: .dark)
        let lightAppearance = UniConnectRailPalette.appKitAppearance(for: .light)
        XCTAssertEqual(
            darkAppearance?.bestMatch(from: [.darkAqua, .aqua]),
            .darkAqua
        )
        XCTAssertEqual(
            lightAppearance?.bestMatch(from: [.darkAqua, .aqua]),
            .aqua
        )

        let dark = UniConnectRailPalette.windowBackgroundNSColor(for: .dark)
        let light = UniConnectRailPalette.windowBackgroundNSColor(for: .light)

        XCTAssertGreaterThan(
            cmuxContrastRatio(foreground: .white, background: dark),
            cmuxContrastRatio(foreground: .white, background: light)
        )
    }

    func testFlyoutConnectionBadgesAreSemanticAndReadableInBothSchemes() throws {
        let appearances: [(scheme: ColorScheme, surface: NSColor)] = [
            (.dark, NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)),
            (.light, NSColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1)),
        ]
        let kinds: [UniConnectChipSnapshot.ConnectionKind] = [.local, .ssh, .mixed]

        for appearance in appearances {
            for kind in kinds {
                let foreground = UniConnectRailPalette.connectionBadgeNSColor(
                    for: kind,
                    colorScheme: appearance.scheme
                )
                for increasedContrast in [false, true] {
                    let fillOpacity = UniConnectRailPalette.badgeFillOpacity(
                        increasedContrast: increasedContrast
                    )
                    let background = cmuxCompositedNSColor(
                        foreground.withAlphaComponent(CGFloat(fillOpacity)),
                        over: appearance.surface
                    )
                    XCTAssertGreaterThanOrEqual(
                        cmuxContrastRatio(foreground: foreground, background: background),
                        4.5,
                        "\(kind.rawValue), \(appearance.scheme), increasedContrast=\(increasedContrast)"
                    )
                }
            }

            let local = try XCTUnwrap(
                UniConnectRailPalette.connectionBadgeNSColor(
                    for: .local,
                    colorScheme: appearance.scheme
                ).usingColorSpace(.sRGB)
            )
            let ssh = try XCTUnwrap(
                UniConnectRailPalette.connectionBadgeNSColor(
                    for: .ssh,
                    colorScheme: appearance.scheme
                ).usingColorSpace(.sRGB)
            )
            XCTAssertGreaterThan(local.greenComponent, local.redComponent)
            XCTAssertGreaterThan(local.greenComponent, local.blueComponent)
            XCTAssertGreaterThan(ssh.blueComponent, ssh.redComponent)
            XCTAssertGreaterThan(ssh.blueComponent, ssh.greenComponent)

            let disconnected = UniConnectRailPalette.disconnectedBadgeNSColor(
                for: appearance.scheme
            )
            let disconnectedBackground = cmuxCompositedNSColor(
                disconnected.withAlphaComponent(
                    CGFloat(
                        UniConnectRailPalette.badgeFillOpacity(increasedContrast: true)
                    )
                ),
                over: appearance.surface
            )
            XCTAssertGreaterThanOrEqual(
                cmuxContrastRatio(
                    foreground: disconnected,
                    background: disconnectedBackground
                ),
                4.5
            )
        }
    }

    func testCompactDisconnectedBadgeStaysReadableOverLightAndDarkTiles() {
        let foreground = UniConnectRailPalette.compactDisconnectedForegroundNSColor

        for surface in [NSColor.black, NSColor.white] {
            for increasedContrast in [false, true] {
                let background = cmuxCompositedNSColor(
                    NSColor.black.withAlphaComponent(
                        CGFloat(
                            UniConnectRailPalette.compactBadgeBackgroundOpacity(
                                increasedContrast: increasedContrast
                            )
                        )
                    ),
                    over: surface
                )
                XCTAssertGreaterThanOrEqual(
                    cmuxContrastRatio(foreground: foreground, background: background),
                    4.5,
                    "surface=\(surface), increasedContrast=\(increasedContrast)"
                )
            }
        }
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

    func testExplicitPresentationSurvivesHoverExitUntilOutsideClick() {
        let id = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()

        XCTAssertEqual(policy.reduce(.presentPersistently(id)), .showNow(id))
        XCTAssertEqual(policy.persistentSourceID, id)
        XCTAssertEqual(policy.reduce(.pointerExited(id)), .none)
        XCTAssertEqual(policy.reduce(.closeDelayElapsed), .none)
        XCTAssertEqual(policy.visibleSourceID, id)

        XCTAssertEqual(policy.reduce(.outsideClick), .hideNow)
        XCTAssertNil(policy.visibleSourceID)
        XCTAssertNil(policy.persistentSourceID)
    }

    func testPromotingVisibleHoverCardToPersistentDoesNotRemountIt() {
        let id = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()

        _ = policy.reduce(.pointerEntered(id))
        XCTAssertEqual(policy.reduce(.showDelayElapsed(id)), .showNow(id))
        XCTAssertEqual(policy.reduce(.presentPersistently(id)), .cancelScheduledHide)
        XCTAssertEqual(policy.visibleSourceID, id)
        XCTAssertEqual(policy.persistentSourceID, id)
    }

    func testExplicitPresentationIsNotReplacedByIncidentalHover() {
        let selected = UUID()
        let hovered = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()

        _ = policy.reduce(.presentPersistently(selected))

        XCTAssertEqual(policy.reduce(.pointerEntered(hovered)), .none)
        XCTAssertEqual(policy.visibleSourceID, selected)
        XCTAssertEqual(policy.persistentSourceID, selected)
        XCTAssertEqual(policy.reduce(.presentPersistently(hovered)), .showNow(hovered))
        XCTAssertEqual(policy.visibleSourceID, hovered)
        XCTAssertEqual(policy.persistentSourceID, hovered)
    }

    func testKeyboardFocusMovesPersistentPresentationToFocusedChip() {
        let first = UUID()
        let second = UUID()
        var policy = UniConnectSidebarFlyoutPolicy()

        _ = policy.reduce(.presentPersistently(first))

        XCTAssertEqual(policy.reduce(.focusChanged(second, isFocused: true)), .showNow(second))
        XCTAssertEqual(policy.visibleSourceID, second)
        XCTAssertEqual(policy.persistentSourceID, second)
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

    func testLayoutAddsHeightForAWorkspaceNameThatWrapsPastTwoLines() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 700)
        let anchor = CGRect(x: 18, y: 320, width: 36, height: 36)
        let shortNameLayout = UniConnectSidebarFlyoutLayout.resolve(
            containerBounds: bounds,
            anchorFrame: anchor,
            windowCount: 3,
            displayName: "Build"
        )
        let fullNameLayout = UniConnectSidebarFlyoutLayout.resolve(
            containerBounds: bounds,
            anchorFrame: anchor,
            windowCount: 3,
            displayName: "Build and validate the complete international university connection workspace",
            hasShortcut: true
        )

        XCTAssertGreaterThan(fullNameLayout.cardFrame.height, shortNameLayout.cardFrame.height)
        XCTAssertGreaterThanOrEqual(fullNameLayout.cardFrame.minY, bounds.minY + 12)
        XCTAssertLessThanOrEqual(fullNameLayout.cardFrame.maxY, bounds.maxY - 12)
    }

    func testLongWorkspaceNameHeightStillClampsToTheWindow() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 220)
        let anchor = CGRect(x: 18, y: 92, width: 36, height: 36)
        let layout = UniConnectSidebarFlyoutLayout.resolve(
            containerBounds: bounds,
            anchorFrame: anchor,
            windowCount: 12,
            displayName: String(repeating: "International workspace ", count: 12),
            hasShortcut: true
        )

        XCTAssertEqual(layout.cardFrame.height, bounds.height - 24, accuracy: 1)
        XCTAssertGreaterThanOrEqual(layout.cardFrame.minY, bounds.minY + 12)
        XCTAssertLessThanOrEqual(layout.cardFrame.maxY, bounds.maxY - 12)
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
            presentWindowList: {},
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
            editGroupConfiguration: nil,
            ungroup: nil,
            closeBox: {},
            toggleGroup: nil
        )
    }
}

private final class UniConnectFirstResponderProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
