import AppKit
import Combine
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWorkspaceSnapshotRefreshPolicyTests: XCTestCase {
    func testExpandedSidebarRowKeepsLazyListSnapshotBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentViewURL = repositoryRoot.appendingPathComponent("Sources/ContentView.swift")
        let source = try String(contentsOf: contentViewURL, encoding: .utf8)

        guard let rowStart = source.range(of: "struct TabItemView: View, Equatable {")?.lowerBound,
              let rowEnd = source.range(
                of: "private struct SidebarWorkspaceDescriptionText: View",
                range: rowStart..<source.endIndex
              )?.lowerBound else {
            return XCTFail("Could not locate the expanded-sidebar row source boundary")
        }
        let rowSource = String(source[rowStart..<rowEnd])

        XCTAssertTrue(
            rowSource.contains("let snapshot: SidebarTabItemSnapshot"),
            "Rows below LazyVStack must receive one immutable value snapshot"
        )
        XCTAssertTrue(
            rowSource.contains("let actions: SidebarTabItemActions"),
            "Rows below LazyVStack must receive behavior only through a closure action bundle"
        )

        let forbiddenRowDependencies = [
            "TabManager",
            "TerminalNotificationStore",
            "let tab: Tab",
            "let tab: Workspace",
            "@ObservedObject",
            "@EnvironmentObject",
            "@StateObject",
            "@Binding",
            ".onReceive(",
        ]
        for dependency in forbiddenRowDependencies {
            XCTAssertFalse(
                rowSource.contains(dependency),
                "TabItemView crosses the LazyVStack snapshot boundary with forbidden dependency: \(dependency)"
            )
        }

        guard let equalityStart = rowSource.range(of: "nonisolated static func ==")?.lowerBound,
              let equalityEnd = rowSource.range(
                of: "let snapshot: SidebarTabItemSnapshot",
                range: equalityStart..<rowSource.endIndex
              )?.lowerBound else {
            return XCTFail("Could not locate TabItemView equality implementation")
        }
        let equalitySource = String(rowSource[equalityStart..<equalityEnd])
        XCTAssertTrue(
            equalitySource.contains("lhs.snapshot == rhs.snapshot"),
            "Equatable rows must compare their immutable snapshot"
        )
        XCTAssertFalse(
            equalitySource.contains("lhs.actions") || equalitySource.contains("rhs.actions"),
            "Closure identity must not invalidate otherwise identical lazy rows"
        )
    }

    func testContextMenuPinChangeUpdatesDisplayedFieldsAndDefersNoisyFields() {
        let current = Self.snapshot(
            title: "lmao",
            isPinned: false,
            customColorHex: nil,
            remoteConnectionStatusText: "Connected",
            latestConversationMessage: "old message",
            listeningPorts: [3000]
        )
        let next = Self.snapshot(
            title: "lmao",
            isPinned: true,
            customColorHex: nil,
            remoteConnectionStatusText: "Disconnected",
            latestConversationMessage: "new message",
            listeningPorts: [3000, 4000]
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        var expectedDisplayed = current
        expectedDisplayed = expectedDisplayed.applyingContextMenuImmediateFields(from: next)
        XCTAssertEqual(decision.workspaceSnapshotStorage, expectedDisplayed)
        XCTAssertTrue(decision.workspaceSnapshotStorage?.isPinned == true)
        XCTAssertEqual(decision.workspaceSnapshotStorage?.remoteConnectionStatusText, "Connected")
        XCTAssertEqual(decision.workspaceSnapshotStorage?.latestConversationMessage, "old message")
        XCTAssertEqual(decision.workspaceSnapshotStorage?.listeningPorts, [3000])
        XCTAssertEqual(decision.pendingWorkspaceSnapshot, next)
        XCTAssertTrue(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    func testContextMenuImmediateOnlyChangeDoesNotCreateDeferredFlush() {
        let current = Self.snapshot(
            title: "old",
            customDescription: nil,
            isPinned: false,
            customColorHex: nil
        )
        let next = Self.snapshot(
            title: "new",
            customDescription: "description",
            isPinned: true,
            customColorHex: "#C0392B"
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        XCTAssertEqual(decision.workspaceSnapshotStorage, next)
        XCTAssertNil(decision.pendingWorkspaceSnapshot)
        XCTAssertFalse(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    func testClosedContextMenuStoresNextAndClearsPending() {
        let current = Self.snapshot(title: "old", isPinned: false)
        let next = Self.snapshot(title: "new", isPinned: true)

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: false
        )

        XCTAssertEqual(decision.workspaceSnapshotStorage, next)
        XCTAssertNil(decision.pendingWorkspaceSnapshot)
        XCTAssertFalse(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    private static func snapshot(
        presentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey? = nil,
        title: String = "workspace",
        customDescription: String? = nil,
        isPinned: Bool = false,
        customColorHex: String? = nil,
        remoteConnectionStatusText: String = "Disconnected",
        latestConversationMessage: String? = nil,
        listeningPorts: [Int] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: presentationKey ?? Self.presentationKey(),
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            customColorHex: customColorHex,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: "",
            copyableSidebarSSHError: nil,
            latestConversationMessage: latestConversationMessage,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: listeningPorts,
            uniConnectIsSSH: nil,
            uniConnectWindowCount: 0
        )
    }

    private static func presentationKey(
        showsWorkspaceDescription: Bool = true,
        usesVerticalBranchLayout: Bool = true,
        showsGitBranch: Bool = true,
        usesViewportAwarePath: Bool = false,
        visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility = SidebarWorkspaceAuxiliaryDetailVisibility(
            showsMetadata: true,
            showsLog: true,
            showsProgress: true,
            showsBranchDirectory: true,
            showsPullRequests: true,
            showsPorts: true
        )
    ) -> SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: showsWorkspaceDescription,
            usesVerticalBranchLayout: usesVerticalBranchLayout,
            showsGitBranch: showsGitBranch,
            usesViewportAwarePath: usesViewportAwarePath,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails
        )
    }
}

final class SidebarTabItemSnapshotContextMenuFreezeStateTests: XCTestCase {
    func testFreezeKeepsEntireRowAndWorkspaceSnapshotStableUntilDismissal() {
        let workspaceId = UUID()
        let captured = Self.tabSnapshot(
            workspaceId: workspaceId,
            title: "Captured",
            remoteConnectionStatusText: "Connected",
            unreadCount: 1,
            latestNotificationText: "old notification",
            canMarkRead: true
        )
        let latest = Self.tabSnapshot(
            workspaceId: workspaceId,
            title: "Latest",
            remoteConnectionStatusText: "Disconnected",
            unreadCount: 9,
            latestNotificationText: "new notification",
            canMarkRead: false
        )
        var state = SidebarTabItemSnapshot.ContextMenuFreezeState()

        state.contextMenuDidAppear(with: captured)

        XCTAssertEqual(state.resolving(latest), captured)
        XCTAssertEqual(state.resolving(latest).workspace.title, "Captured")
        XCTAssertEqual(state.resolving(latest).unreadCount, 1)
        XCTAssertTrue(state.resolving(latest).contextMenu.canMarkRead)

        state.contextMenuDidDisappear(for: workspaceId)

        XCTAssertNil(state.frozenSnapshot)
        XCTAssertEqual(state.resolving(latest), latest, "Dismissal must immediately expose the latest parent projection")
    }

    func testFreezeOnlyAffectsWorkspaceWhoseMenuIsOpen() {
        let frozenWorkspaceId = UUID()
        let otherWorkspaceId = UUID()
        let captured = Self.tabSnapshot(workspaceId: frozenWorkspaceId, title: "Frozen")
        let otherLatest = Self.tabSnapshot(workspaceId: otherWorkspaceId, title: "Other latest")
        var state = SidebarTabItemSnapshot.ContextMenuFreezeState()

        state.contextMenuDidAppear(with: captured)

        XCTAssertEqual(state.resolving(otherLatest), otherLatest)
    }

    func testRepeatedAppearanceForSameMenuDoesNotMoveFrozenBaseline() {
        let workspaceId = UUID()
        let captured = Self.tabSnapshot(workspaceId: workspaceId, title: "Captured")
        let laterAppearance = Self.tabSnapshot(workspaceId: workspaceId, title: "Later")
        var state = SidebarTabItemSnapshot.ContextMenuFreezeState()

        state.contextMenuDidAppear(with: captured)
        state.contextMenuDidAppear(with: laterAppearance)

        XCTAssertEqual(state.frozenSnapshot, captured)
    }

    func testUnrelatedDismissalDoesNotReleaseOpenMenuSnapshot() {
        let workspaceId = UUID()
        let captured = Self.tabSnapshot(workspaceId: workspaceId, title: "Captured")
        var state = SidebarTabItemSnapshot.ContextMenuFreezeState()

        state.contextMenuDidAppear(with: captured)
        state.contextMenuDidDisappear(for: UUID())

        XCTAssertEqual(state.frozenSnapshot, captured)
    }

    func testRemovingFrozenWorkspaceReleasesSnapshot() {
        let workspaceId = UUID()
        var state = SidebarTabItemSnapshot.ContextMenuFreezeState()
        state.contextMenuDidAppear(with: Self.tabSnapshot(workspaceId: workspaceId, title: "Removed"))

        state.retainAvailableWorkspaces([])

        XCTAssertNil(state.frozenSnapshot)
    }

    func testParentResolvesFrozenSnapshotBeforeLazyListBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentViewURL = repositoryRoot.appendingPathComponent("Sources/ContentView.swift")
        let source = try String(contentsOf: contentViewURL, encoding: .utf8)

        guard let parentStart = source.range(of: "private func workspaceRows(")?.lowerBound,
              let lazyBoundary = source.range(
                of: "let rows = LazyVStack",
                range: parentStart..<source.endIndex
              )?.lowerBound else {
            return XCTFail("Could not locate expanded-sidebar parent projection and lazy-list boundary")
        }
        let parentProjection = String(source[parentStart..<lazyBoundary])

        XCTAssertTrue(
            parentProjection.contains("contextMenuSnapshotFreezeState.resolving(liveSnapshot)"),
            "The parent must freeze the complete row snapshot before it crosses the LazyVStack boundary"
        )
    }

    private static func tabSnapshot(
        workspaceId: UUID,
        title: String,
        remoteConnectionStatusText: String = "Connected",
        unreadCount: Int = 0,
        latestNotificationText: String? = nil,
        canMarkRead: Bool = false
    ) -> SidebarTabItemSnapshot {
        let workspace = SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey(
                showsWorkspaceDescription: true,
                usesVerticalBranchLayout: true,
                showsGitBranch: true,
                usesViewportAwarePath: false,
                visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility(
                    showsMetadata: true,
                    showsLog: true,
                    showsProgress: true,
                    showsBranchDirectory: true,
                    showsPullRequests: true,
                    showsPorts: true
                )
            ),
            title: title,
            customDescription: nil,
            isPinned: false,
            customColorHex: nil,
            remoteWorkspaceSidebarText: "ssh host",
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: "",
            copyableSidebarSSHError: nil,
            latestConversationMessage: nil,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: [],
            uniConnectIsSSH: true,
            uniConnectWindowCount: 1
        )
        return SidebarTabItemSnapshot(
            workspaceId: workspaceId,
            workspace: workspace,
            customTitle: nil,
            isGroupMember: false,
            index: 0,
            isActive: true,
            workspaceShortcutDigit: 1,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: true,
            accessibilityWorkspaceCount: 1,
            unreadCount: unreadCount,
            latestNotificationText: latestNotificationText,
            rowSpacing: 4,
            isMultiSelected: false,
            showsModifierShortcutHints: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            finderDirectoryPath: "/tmp",
            contextMenu: SidebarTabItemSnapshot.ContextMenu(
                targetWorkspaceIds: [workspaceId],
                shouldPin: true,
                canTogglePin: true,
                isSSHWorkspace: true,
                hasCustomColor: false,
                customColorSeed: nil,
                canReconnectSSH: true,
                canMarkRead: canMarkRead,
                canMarkUnread: !canMarkRead,
                canMoveUp: false,
                canMoveDown: false,
                canMoveToTop: true,
                canCloseTargets: true,
                canCloseOtherWorkspaces: false,
                canCloseBelow: false,
                canCloseAbove: false,
                eligibleForGrouping: true,
                allEligibleTargetsGroupId: nil,
                hasAnyGroupedEligibleTarget: false,
                groupMenu: WorkspaceGroupMenuSnapshot(items: [])
            ),
            settings: SidebarTabItemSettingsSnapshot(
                defaults: .standard,
                sidebarFontSize: GhosttyConfig.defaultSidebarFontSize
            )
        )
    }
}

@MainActor
final class SidebarWorkspaceSnapshotCoordinatorTests: XCTestCase {
    func testSnapshotMapProjectsEachWorkspaceIdentifierOnlyOnce() {
        let first = UUID()
        let second = UUID()
        var projectionCounts: [UUID: Int] = [:]

        let snapshots = SidebarWorkspaceSnapshotCoordinator.makeSnapshotMap(
            elements: [first, second, first],
            cachedSnapshots: [:],
            id: { $0 },
            project: { id in
                projectionCounts[id, default: 0] += 1
                return id.uuidString
            }
        )

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(projectionCounts[first], 1)
        XCTAssertEqual(projectionCounts[second], 1)

        _ = [first, second, first, second].compactMap { snapshots[$0] }
        XCTAssertEqual(projectionCounts[first], 1, "Reusing a projected target must not re-project it")
        XCTAssertEqual(projectionCounts[second], 1, "Reusing a projected target must not re-project it")
    }

    func testSnapshotMapUsesSeedAndProjectsOnlyMissingWorkspace() {
        let seeded = UUID()
        let missing = UUID()
        var projectedIds: [UUID] = []

        let snapshots = SidebarWorkspaceSnapshotCoordinator.makeSnapshotMap(
            elements: [seeded, missing],
            cachedSnapshots: [seeded: "seeded"],
            id: { $0 },
            project: { id in
                projectedIds.append(id)
                return "projected"
            }
        )

        XCTAssertEqual(snapshots[seeded], "seeded")
        XCTAssertEqual(snapshots[missing], "projected")
        XCTAssertEqual(projectedIds, [missing])
    }

    func testSidebarProjectionPublisherInvalidatesForOrderedPanelAndPlaceholderInputs() {
        let workspace = Workspace(title: "Tests")
        var invalidationCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            invalidationCount += 1
        }

        workspace.paneLayoutVersion &+= 1
        XCTAssertEqual(invalidationCount, 1, "A pure panel reorder must invalidate ordered sidebar projections")

        workspace.uniConnectPlaceholderPanelIds.insert(UUID())
        XCTAssertEqual(invalidationCount, 2, "Placeholder membership changes the projected UniConnect window count")

        withExtendedLifetime(cancellable) {}
    }
}

final class SidebarSelectedWorkspaceScrollPolicyTests: XCTestCase {
    func testSkipsScrollWhenSelectedWorkspaceIdIsNil() {
        XCTAssertFalse(
            SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
                selectedWorkspaceId: nil as String?,
                oldWorkspaceIds: ["a"],
                newWorkspaceIds: ["a"]
            )
        )
    }

    func testRequestsScrollWhenSelectedWorkspaceFirstAppears() {
        XCTAssertTrue(
            SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
                selectedWorkspaceId: "b",
                oldWorkspaceIds: ["a"],
                newWorkspaceIds: ["a", "b"]
            )
        )
    }

    func testRequestsScrollWhenSelectedWorkspaceMovesToTop() {
        XCTAssertTrue(
            SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
                selectedWorkspaceId: "c",
                oldWorkspaceIds: ["a", "b", "c"],
                newWorkspaceIds: ["c", "a", "b"]
            )
        )
    }

    func testRequestsScrollWhenAnotherReorderShiftsSelectedWorkspaceIndex() {
        XCTAssertTrue(
            SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
                selectedWorkspaceId: "b",
                oldWorkspaceIds: ["a", "b", "c"],
                newWorkspaceIds: ["c", "a", "b"]
            )
        )
    }

    func testSkipsScrollWhenReorderLeavesSelectedWorkspaceIndexUnchanged() {
        XCTAssertFalse(
            SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
                selectedWorkspaceId: "a",
                oldWorkspaceIds: ["a", "b", "c"],
                newWorkspaceIds: ["a", "c", "b"]
            )
        )
    }

    func testSkipsScrollWhenSelectedWorkspaceIsMissing() {
        XCTAssertFalse(
            SidebarSelectedWorkspaceScrollPolicy.shouldScrollSelectedWorkspace(
                selectedWorkspaceId: "b",
                oldWorkspaceIds: ["a", "b"],
                newWorkspaceIds: ["a", "c"]
            )
        )
    }
}

final class SidebarWorkspaceRowInteractionStateTests: XCTestCase {
    func testHoverRevealIsIndependentFromStaleContextMenuVisibility() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        state.contextMenuTrackingDidEnd()
        state.setPointerHovering(true)

        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "A stale SwiftUI context-menu lifecycle flag must not permanently suppress hover-only close affordances after AppKit menu tracking has ended."
        )

        state.setPointerHovering(false)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "The stale SwiftUI menu flag must not make the close affordance visible when the pointer is no longer hovering."
        )
    }

    func testContextMenuTrackingBeginHidesExistingCloseButtonBeforeSwiftUIMenuAppears() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            )
        )

        state.contextMenuTrackingDidBegin()

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Right-click menu tracking must hide an already-visible close affordance even before SwiftUI reports the context menu appearance."
        )
    }

    func testHoverDuringContextMenuTrackingStaysHiddenUntilTrackingEnds() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        state.setPointerHovering(true)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Pointer hover updates observed during context-menu tracking must not reveal the close affordance under the menu."
        )

        state.contextMenuTrackingDidEnd()

        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Once AppKit menu tracking ends, the last reconciled pointer position may reveal the close affordance even if SwiftUI menu state is stale."
        )
    }

    func testCoordinatorPreservesHoverExitWhileMenuTrackingSuppressesCloseButton() {
        var state = SidebarWorkspaceRowInteractionState()
        let coordinator = SidebarWorkspaceRowHoverTracker.Coordinator(
            onPointerHoverChanged: { hovering in
                state.setPointerHovering(hovering)
            },
            onMenuTrackingChanged: { tracking in
                if tracking {
                    state.contextMenuTrackingDidBegin()
                } else {
                    state.contextMenuTrackingDidEnd()
                }
            }
        )

        coordinator.menuTrackingChanged(true)
        coordinator.pointerHoverChanged(true)
        coordinator.pointerHoverChanged(false)
        coordinator.menuTrackingChanged(false)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "A pointer exit observed during menu tracking must overwrite any earlier deferred hover enter before the menu dismisses."
        )
    }

    func testMenuTrackingSuppressionOnlyAppliesToPointerMenusInsideRow() {
        XCTAssertTrue(
            SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
                pointerInsideRow: true,
                eventType: .rightMouseDown,
                modifierFlags: []
            )
        )
        XCTAssertTrue(
            SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
                pointerInsideRow: true,
                eventType: .leftMouseDown,
                modifierFlags: .control
            )
        )
        XCTAssertFalse(
            SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
                pointerInsideRow: false,
                eventType: .rightMouseDown,
                modifierFlags: []
            ),
            "A menu opened outside this row must not suppress this row's hover state."
        )
        XCTAssertFalse(
            SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
                pointerInsideRow: true,
                eventType: .keyDown,
                modifierFlags: []
            ),
            "Keyboard-driven or app-level menu tracking must not be treated like this row's pointer context menu."
        )
    }

    func testPointerExitWhileContextMenuIsVisibleStaysHiddenAfterDismissal() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()
        state.setPointerHovering(false)
        state.contextMenuDidDisappear()

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Pointer exit remains authoritative even when it is observed during the context-menu lifecycle."
        )
    }

    func testNoHoverDoesNotRevealCloseButtonWhileContextMenuIsVisible() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        state.setPointerHovering(false)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "A visible context menu must not make the close affordance visible when the pointer is not hovering."
        )
    }

    func testContextMenuAppearanceHidesExistingCloseButtonUntilPointerIsReconciled() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            )
        )

        state.contextMenuDidAppear()

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Opening a context menu must clear the row close affordance until tracking reports the pointer is still inside."
        )
    }

    func testContextMenuDismissalCanRevealAfterPointerReconciliation() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()
        state.contextMenuDidDisappear()
        state.setPointerHovering(true)

        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Closing the context menu may reveal the close affordance again only after pointer tracking reconciles inside the row."
        )
    }

    func testCloseButtonHiddenWhenWorkspaceCannotBeClosed() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: false,
                shortcutHintModeActive: false
            )
        )
    }

    func testCloseButtonHiddenDuringShortcutHintMode() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: true
            )
        )
    }
}
