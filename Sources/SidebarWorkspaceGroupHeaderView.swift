import AppKit
import SwiftUI

/// Collapsible group header that doubles as the anchor workspace row.
struct SidebarWorkspaceGroupHeaderView: View, Equatable {
    // Closure action bundles are excluded because they are recreated
    // by the parent on each evaluation. The scalar snapshots below are the
    // header's render and behavior inputs under the LazyVStack.
    nonisolated static func == (lhs: SidebarWorkspaceGroupHeaderView, rhs: SidebarWorkspaceGroupHeaderView) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    let snapshot: SidebarWorkspaceGroupHeaderSnapshot
    let actions: SidebarWorkspaceGroupHeaderActions

    @State private var isHovered = false
    @State private var rowHeight: CGFloat = 1

    private var groupId: UUID { snapshot.groupId }
    private var anchorWorkspaceId: UUID { snapshot.anchorWorkspaceId }
    private var name: String { snapshot.name }
    private var iconSymbol: String { snapshot.iconSymbol }
    private var tintHex: String? { snapshot.tintHex }
    private var isCollapsed: Bool { snapshot.isCollapsed }
    private var isPinned: Bool { snapshot.isPinned }
    private var isAnchorActive: Bool { snapshot.isAnchorActive }
    private var memberCount: Int { snapshot.memberCount }
    private var anchorUnreadCount: Int { snapshot.anchorUnreadCount }
    private var shortcutDigit: Int? { snapshot.shortcutDigit }
    private var shortcutModifierSymbol: String? { snapshot.shortcutModifierSymbol }
    private var showsShortcutHint: Bool { snapshot.showsShortcutHint }
    private var shortcutHintXOffset: Double { snapshot.shortcutHintXOffset }
    private var shortcutHintYOffset: Double { snapshot.shortcutHintYOffset }
    private var fontScale: CGFloat { snapshot.fontScale }
    private var cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem] { snapshot.cwdContextMenuItems }
    private var newWorkspacePlacement: WorkspaceGroupNewPlacement? { snapshot.newWorkspacePlacement }
    private var rowSpacing: CGFloat { snapshot.rowSpacing }
    private var isFirstRow: Bool { snapshot.isFirstRow }
    private var isBeingDragged: Bool { snapshot.isBeingDragged }
    private var topDropIndicatorVisible: Bool { snapshot.topDropIndicatorVisible }
    private var onDragStart: () -> NSItemProvider { actions.beginDrag }
    private var dropActions: SidebarTabItemDropActions { actions.drop }
    private var onToggleCollapsed: () -> Void { actions.toggleCollapsed }
    private var onFocusAnchor: () -> Void { actions.focusAnchor }
    private var onTapPlus: () -> Void { actions.createWorkspace }
    private var onRunResolvedItem: (CmuxResolvedConfigMenuAction) -> Void { actions.runResolvedItem }
    private var onRename: () -> Void { actions.rename }
    private var onTogglePinned: () -> Void { actions.togglePinned }
    private var onUngroup: () -> Void { actions.ungroup }
    private var onDelete: () -> Void { actions.delete }
    private var onEditConfig: () -> Void { actions.editConfig }
    private var onOpenDocs: () -> Void { actions.openDocs }

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
    }

    private var iconColor: Color {
        if let tintHex, let nsColor = NSColor(hex: tintHex) {
            return Color(nsColor: nsColor)
        }
        return .secondary
    }

    private var displayedIconSymbol: String {
        RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: iconSymbol, configured: nil)
    }

    private var shortcutHintPillText: String? {
        guard showsShortcutHint,
              let shortcutDigit,
              let shortcutModifierSymbol else { return nil }
        return "\(shortcutModifierSymbol)\(shortcutDigit)"
    }

    private var rowHeightProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    rowHeight = max(proxy.size.height, 1)
                }
                .onChange(of: proxy.size.height) { _, newHeight in
                    rowHeight = max(newHeight, 1)
                }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: metrics.chevronFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
                .contentShape(Rectangle())
                .onTapGesture { onToggleCollapsed() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(
                    Text(
                        isCollapsed
                            ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                            : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
                    )
                )

            HStack(spacing: 6) {
                Image(systemName: displayedIconSymbol)
                    .font(.system(size: metrics.iconFontSize, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: metrics.nameFontSize, weight: .semibold))
                    .foregroundStyle(isAnchorActive ? Color.primary : Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if anchorUnreadCount > 0 {
                    Text("\(anchorUnreadCount)")
                        .font(.system(size: metrics.unreadFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, metrics.unreadHorizontalPadding)
                        .padding(.vertical, metrics.unreadVerticalPadding)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel(Text(String.localizedStringWithFormat(
                            String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                            anchorUnreadCount
                        )))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onFocusAnchor() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(name))
            .accessibilityHint(Text(String(
                localized: "workspaceGroup.focusAnchor.a11y",
                defaultValue: "Focus the group's anchor workspace"
            )))

            let plusVisible = isHovered && !showsShortcutHint
            Button(action: onTapPlus) {
                Image(systemName: "plus")
                    .font(.system(size: metrics.plusFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.plusFrame, height: metrics.plusFrame)
                    .contentShape(Rectangle())
                    .opacity(plusVisible ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: metrics.plusFrame, height: metrics.plusFrame)
            .allowsHitTesting(plusVisible)
            .accessibilityHidden(!plusVisible)
            .accessibilityLabel(Text(String(
                localized: "workspaceGroup.newWorkspaceInGroup.a11y",
                defaultValue: "New box in group"
            )))
            .contextMenu {
                Button(action: onTapPlus) {
                    Label(
                        String(
                            localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                            defaultValue: "New Box in Group"
                        ),
                        systemImage: "shippingbox"
                    )
                }
                Divider()
                Button(action: onEditConfig) {
                    Label(
                        String(
                            localized: "workspaceGroup.plus.contextMenu.editConfig",
                            defaultValue: "Edit Group Configuration…"
                        ),
                        systemImage: "gearshape"
                    )
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            isAnchorActive
                ? Color.primary.opacity(0.08)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .sidebarShortcutHintOverlay(
            text: shortcutHintPillText,
            emphasis: isAnchorActive ? 1.0 : 0.9,
            offsetX: shortcutHintXOffset,
            offsetY: shortcutHintYOffset
        )
        .padding(.horizontal, 6)
        .background { rowHeightProbe }
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: isFirstRow,
                rowSpacing: rowSpacing
            )
        }
        .onDrag(onDragStart)
        .internalOnlyTabDrag()
        .onDrop(
            of: SidebarTabDragPayload.dropContentTypes,
            delegate: SidebarTabItemDropDelegate(
                actions: dropActions,
                rowHeight: rowHeight
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(action: onRename) {
                Label(
                    String(localized: "workspaceGroup.contextMenu.rename", defaultValue: "Rename Group…"),
                    systemImage: "pencil"
                )
            }
            Button(action: onToggleCollapsed) {
                Label(
                    isCollapsed
                        ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand Group")
                        : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse Group"),
                    systemImage: isCollapsed ? "chevron.down" : "chevron.right"
                )
            }
            Button(action: onTogglePinned) {
                Label(
                    isPinned
                        ? String(localized: "workspaceGroup.contextMenu.unpin", defaultValue: "Unpin Group")
                        : String(localized: "workspaceGroup.contextMenu.pin", defaultValue: "Pin Group"),
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            Divider()
            Button(action: onEditConfig) {
                Label(
                    String(
                        localized: "workspaceGroup.contextMenu.editConfig",
                        defaultValue: "Edit Group Configuration…"
                    ),
                    systemImage: "gearshape"
                )
            }
            Divider()
            Button(action: onUngroup) {
                Label(
                    String(
                        localized: "workspaceGroup.contextMenu.ungroup",
                        defaultValue: "Ungroup (Keep Boxes)"
                    ),
                    systemImage: "rectangle.3.group"
                )
            }
            Button(
                role: .destructive,
                action: onDelete
            ) {
                Label(
                    String(
                        localized: "workspaceGroup.contextMenu.delete",
                        defaultValue: "Delete Group (Close Boxes)"
                    ),
                    systemImage: "trash"
                )
            }
        }
    }
}

enum SidebarWorkspaceGroupHeaderDropZone {
    static func isCenterDrop(locationY: CGFloat, rowHeight: CGFloat) -> Bool {
        let height = max(rowHeight, 1)
        let edgeBand = min(max(height * 0.25, 4), height * 0.4)
        let y = min(max(locationY, 0), height)
        return y > edgeBand && y < height - edgeBand
    }
}

enum SidebarWorkspaceGroupHeaderDropAction: Equatable {
    case addWorkspaceToGroup(UUID)
    case noOp
}

enum SidebarWorkspaceGroupHeaderDropPolicy {
    static func action(
        hasSidebarPayload: Bool,
        draggedWorkspaceId: UUID?,
        draggedWorkspaceIsPinned: Bool,
        draggedWorkspaceGroupId: UUID?,
        draggedWorkspaceIsGroupAnchor: Bool,
        targetGroupId: UUID,
        targetAnchorWorkspaceId: UUID,
        targetAnchorMatchesGroup: Bool,
        locationY: CGFloat,
        rowHeight: CGFloat
    ) -> SidebarWorkspaceGroupHeaderDropAction? {
        guard hasSidebarPayload,
              let draggedWorkspaceId,
              targetAnchorMatchesGroup,
              SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(
                  locationY: locationY,
                  rowHeight: rowHeight
              ) else {
            return nil
        }
        if draggedWorkspaceId == targetAnchorWorkspaceId || draggedWorkspaceGroupId == targetGroupId {
            return .noOp
        }
        guard !draggedWorkspaceIsPinned,
              !draggedWorkspaceIsGroupAnchor else {
            return nil
        }
        return .addWorkspaceToGroup(draggedWorkspaceId)
    }

    static func shouldConsumeNoOpEdgeDrop(
        hasSidebarPayload: Bool,
        draggedWorkspaceId: UUID?,
        draggedWorkspaceGroupId: UUID?,
        targetGroupId: UUID,
        targetAnchorWorkspaceId: UUID,
        tabIds: [UUID],
        pinnedTabIds: Set<UUID>,
        locationY: CGFloat,
        rowHeight: CGFloat
    ) -> Bool {
        guard hasSidebarPayload,
              let draggedWorkspaceId,
              tabIds.count > 1,
              tabIds.contains(draggedWorkspaceId),
              tabIds.contains(targetAnchorWorkspaceId),
              !SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(
                  locationY: locationY,
                  rowHeight: rowHeight
              ) else {
            return false
        }
        if draggedWorkspaceId == targetAnchorWorkspaceId || draggedWorkspaceGroupId == targetGroupId {
            return true
        }
        return SidebarDropPlanner.indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: targetAnchorWorkspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            pointerY: locationY,
            targetHeight: rowHeight
        ) == nil
    }
}

@MainActor
struct SidebarWorkspaceGroupHeaderDropDelegate: DropDelegate {
    let targetGroupId: UUID
    let targetAnchorWorkspaceId: UUID
    let tabManager: TabManager
    let dragState: SidebarDragState
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    let reorderDelegate: SidebarTabDropDelegate

    func validateDrop(info: DropInfo) -> Bool {
        reorderDelegate.validateDrop(info: info) || groupHeaderCenterDropAction(info) != nil
    }

    func dropEntered(info: DropInfo) {
        if updateGroupHeaderCenterDrop(info) { return }
        reorderDelegate.dropEntered(info: info)
    }

    func dropExited(info: DropInfo) {
        reorderDelegate.dropExited(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if updateGroupHeaderCenterDrop(info) {
            return DropProposal(operation: .move)
        }
        return reorderDelegate.dropUpdated(info: info)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let action = groupHeaderCenterDropAction(info) else {
            if shouldConsumeGroupHeaderNoOpEdgeDrop(info) {
                clearDropState()
                return true
            }
            return reorderDelegate.performDrop(info: info)
        }
        defer { clearDropState() }
        switch action {
        case .addWorkspaceToGroup(let draggedTabId):
            tabManager.addWorkspaceToGroup(workspaceId: draggedTabId, groupId: targetGroupId)
        case .noOp:
            break
        }
        return true
    }

    private func updateGroupHeaderCenterDrop(_ info: DropInfo) -> Bool {
        guard groupHeaderCenterDropAction(info) != nil else { return false }
        dragAutoScrollController.updateFromDragLocation()
        dragState.clearDropIndicator()
        return true
    }

    private func groupHeaderCenterDropAction(_ info: DropInfo) -> SidebarWorkspaceGroupHeaderDropAction? {
        guard let draggedTabId = dragState.draggedTabId,
              let draggedTab = tabManager.tabs.first(where: { $0.id == draggedTabId }),
              let group = tabManager.workspaceGroups.first(where: { $0.id == targetGroupId }) else {
            return nil
        }
        return SidebarWorkspaceGroupHeaderDropPolicy.action(
            hasSidebarPayload: info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]),
            draggedWorkspaceId: draggedTabId,
            draggedWorkspaceIsPinned: draggedTab.isPinned,
            draggedWorkspaceGroupId: draggedTab.groupId,
            draggedWorkspaceIsGroupAnchor: tabManager.workspaceGroups.contains {
                $0.anchorWorkspaceId == draggedTabId
            },
            targetGroupId: targetGroupId,
            targetAnchorWorkspaceId: targetAnchorWorkspaceId,
            targetAnchorMatchesGroup: group.anchorWorkspaceId == targetAnchorWorkspaceId,
            locationY: info.location.y,
            rowHeight: targetRowHeight ?? 1
        )
    }

    private func shouldConsumeGroupHeaderNoOpEdgeDrop(_ info: DropInfo) -> Bool {
        let height = targetRowHeight ?? 1
        guard let draggedTabId = dragState.draggedTabId,
              let draggedTab = tabManager.tabs.first(where: { $0.id == draggedTabId }) else { return false }
        return SidebarWorkspaceGroupHeaderDropPolicy.shouldConsumeNoOpEdgeDrop(
            hasSidebarPayload: info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]),
            draggedWorkspaceId: draggedTabId,
            draggedWorkspaceGroupId: draggedTab.groupId,
            targetGroupId: targetGroupId,
            targetAnchorWorkspaceId: targetAnchorWorkspaceId,
            tabIds: tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetAnchorWorkspaceId
            ),
            pinnedTabIds: tabManager.sidebarReorderPinnedWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetAnchorWorkspaceId
            ),
            locationY: info.location.y,
            rowHeight: height
        )
    }

    private func clearDropState() {
        dragState.clearDrag()
        dragAutoScrollController.stop()
    }
}
