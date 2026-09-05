import AppKit
import SwiftUI

extension VerticalTabsSidebar {
    func sidebarWorkspaceGroupHeaderSnapshot(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceGroupHeaderSnapshot {
        let settings = renderContext.tabItemSettings
        let anchorCwd = renderContext.workspaceById[group.anchorWorkspaceId]?.currentDirectory
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let anchorUnreadCount: Int = {
            if group.isCollapsed {
                return memberWorkspaceIds.reduce(0) { partial, workspaceId in
                    partial + notificationStore.unreadCount(forTabId: workspaceId)
                }
            }
            return notificationStore.unreadCount(forTabId: group.anchorWorkspaceId)
        }()
        let anchorIndex = renderContext.tabIndexById[group.anchorWorkspaceId] ?? 0

        return SidebarWorkspaceGroupHeaderSnapshot(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
                explicit: group.iconSymbol,
                configured: resolvedConfig?.iconSymbol
            ),
            tintHex: group.customColor ?? resolvedConfig?.color,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: tabManager.selectedTabId == group.anchorWorkspaceId,
            memberCount: memberWorkspaceIds.count,
            anchorUnreadCount: anchorUnreadCount,
            shortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                at: anchorIndex,
                workspaceCount: renderContext.workspaceCount
            ),
            shortcutModifierSymbol: renderContext.workspaceNumberShortcut.numberedDigitHintPrefix,
            showsShortcutHint: modifierKeyMonitor.isModifierPressed,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            cwdContextMenuItems: resolvedConfig?.contextMenuItems ?? [],
            newWorkspacePlacement: resolvedConfig?.newWorkspacePlacement,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.sidebarReorderIds.first == group.anchorWorkspaceId,
            isBeingDragged: dragState.draggedTabId == group.anchorWorkspaceId,
            topDropIndicatorVisible: SidebarTabDropIndicatorPredicate.topVisible(
                forTabId: group.anchorWorkspaceId,
                draggedTabId: dragState.draggedTabId,
                dropIndicator: dragState.dropIndicator,
                tabIds: renderContext.sidebarReorderIds
            )
        )
    }

    func sidebarWorkspaceGroupHeaderActions(
        snapshot: SidebarWorkspaceGroupHeaderSnapshot
    ) -> SidebarWorkspaceGroupHeaderActions {
        let groupId = snapshot.groupId
        let anchorId = snapshot.anchorWorkspaceId
        let selectedTabIds = $selectedTabIds
        let lastSidebarSelectionIndex = $lastSidebarSelectionIndex
        let makeDropDelegate: (CGFloat) -> SidebarWorkspaceGroupHeaderDropDelegate = { rowHeight in
            let reorderDelegate = SidebarTabDropDelegate(
                targetTabId: anchorId,
                tabManager: tabManager,
                dragState: dragState,
                selectedTabIds: selectedTabIds,
                lastSidebarSelectionIndex: lastSidebarSelectionIndex,
                targetRowHeight: rowHeight,
                dragAutoScrollController: dragAutoScrollController
            )
            return SidebarWorkspaceGroupHeaderDropDelegate(
                targetGroupId: groupId,
                targetAnchorWorkspaceId: anchorId,
                tabManager: tabManager,
                dragState: dragState,
                targetRowHeight: rowHeight,
                dragAutoScrollController: dragAutoScrollController,
                reorderDelegate: reorderDelegate
            )
        }

        return SidebarWorkspaceGroupHeaderActions(
            beginDrag: {
#if DEBUG
                cmuxDebugLog("sidebar.onDrag groupAnchor=\(anchorId.uuidString.prefix(5))")
#endif
                dragState.beginDragging(tabId: anchorId)
                return SidebarTabDragPayload.provider(for: anchorId)
            },
            drop: .forwarding(to: makeDropDelegate),
            toggleCollapsed: { [weak tabManager] in
                tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
            },
            focusAnchor: { [weak tabManager] in
                guard let tabManager,
                      let anchorTab = tabManager.tabs.first(where: { $0.id == anchorId }) else {
                    return
                }
                tabManager.selectWorkspace(anchorTab)
                if selectedTabIds.wrappedValue != [anchorId] {
                    selectedTabIds.wrappedValue = [anchorId]
                }
                if let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == anchorId }) {
                    lastSidebarSelectionIndex.wrappedValue = anchorIndex
                }
            },
            createWorkspace: { [weak tabManager, placement = snapshot.newWorkspacePlacement] in
                guard let tabManager else { return }
                let resolved = placement ?? WorkspaceGroupNewWorkspacePlacementSettings.resolved()
                _ = tabManager.createWorkspaceInGroup(groupId: groupId, placement: resolved)
            },
            runResolvedItem: { [weak tabManager] item in
                guard let tabManager else { return }
                SidebarWorkspaceGroupContextMenuRunner.run(
                    item: item,
                    tabManager: tabManager,
                    groupId: groupId
                )
            },
            rename: { [weak tabManager, currentName = snapshot.name] in
                guard let tabManager else { return }
                presentSidebarWorkspaceGroupRenamePrompt(
                    tabManager: tabManager,
                    groupId: groupId,
                    currentName: currentName
                )
            },
            togglePinned: { [weak tabManager] in
                tabManager?.toggleWorkspaceGroupPinned(groupId: groupId)
            },
            ungroup: { [weak tabManager] in
                tabManager?.ungroupWorkspaceGroup(groupId: groupId)
            },
            delete: { [weak tabManager, groupName = snapshot.name, memberCount = snapshot.memberCount] in
                guard let tabManager else { return }
                let otherMemberCount = max(memberCount - 1, 0)
                guard confirmDeleteWorkspaceGroup(
                    groupName: groupName,
                    otherMemberCount: otherMemberCount
                ) else {
                    return
                }
                tabManager.deleteWorkspaceGroup(groupId: groupId)
            },
            editConfig: {
                SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor()
            },
            openDocs: {
                SidebarWorkspaceGroupConfigOpener.openWorkspaceGroupsDocs()
            }
        )
    }

    @ViewBuilder
    func sidebarWorkspaceGroupHeader(
        snapshot: SidebarWorkspaceGroupHeaderSnapshot,
        actions: SidebarWorkspaceGroupHeaderActions,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> some View {
        let header = SidebarWorkspaceGroupHeaderView(
            snapshot: snapshot,
            actions: actions
        )
        .equatable()
        .id(snapshot.anchorWorkspaceId)
        .accessibilityIdentifier("sidebarWorkspaceGroup.\(snapshot.groupId.uuidString)")
        .preference(
            key: SidebarWorkspaceRowIdsPreferenceKey.self,
            value: Set([snapshot.anchorWorkspaceId])
        )

        header
            .sidebarWorkspaceFrameAnchor(
                id: snapshot.anchorWorkspaceId,
                isEnabled: shouldCollectWorkspaceDropTargets
            )
    }
}
