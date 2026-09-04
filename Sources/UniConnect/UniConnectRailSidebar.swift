import AppKit
import Combine
import Foundation
import SwiftUI
import UniConnectClaudeBridge

/// Compact, snapshot-driven sidebar navigation for UniConnect boxes.
struct UniConnectRailSidebar: View {
    static let compactDefaultsKey = "uniconnect.sidebarCompact"
    static let width: CGFloat = 64
    static let tileSize: CGFloat = 36
    static let tileSpacing: CGFloat = 12

    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedRows: [UniConnectRailRow] = []

    let onNewTab: () -> Void
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: Self.tileSpacing) {
                    ForEach(renderedRows, id: \.id) { row in
                        railRow(row)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, SidebarWorkspaceListMetrics.firstRowTopOffset)
                .padding(.bottom, 12)
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: 14,
                    bottomHeight: 18
                )
            )

            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("UniConnectRailSidebar")
        .onAppear(perform: reloadRows)
        .onReceive(managerObservationPublisher) { _ in reloadRows() }
        .onReceive(workspaceObservationPublisher) { _ in reloadRows() }
        .onReceive(
            notificationStore.objectWillChange
                .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
        ) { _ in
            reloadRows()
        }
        .onChange(of: selectedPanelFocusID) { _ in
            reloadRows()
        }
    }

    @ViewBuilder
    private func railRow(_ row: UniConnectRailRow) -> some View {
        switch row.content {
        case .chip(let snapshot, let actions):
            UniConnectRailTile(snapshot: snapshot, actions: actions)
                .equatable()
                .frame(width: 48)
                .frame(minHeight: 44)
        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.11))
                .frame(width: Self.tileSize - 8, height: 1)
                .padding(.vertical, 2)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        VStack(spacing: 9) {
            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10))
                .frame(width: Self.tileSize, height: 1)
                .allowsHitTesting(false)

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: Self.tileSize, height: Self.tileSize)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.18),
                                style: StrokeStyle(lineWidth: 1.4, dash: [4, 3])
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(UniConnectRailButtonStyle(reduceMotion: reduceMotion))
            .safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(
                String(localized: "menu.file.newBox", defaultValue: "New Box…")
            ))
            .accessibilityLabel(String(localized: "menu.file.newBox", defaultValue: "New Box…"))
            .accessibilityIdentifier("UniConnectRailNewWorkspace")

            Button(action: onExpand) {
                Image(systemName: "sidebar.squares.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(UniConnectRailButtonStyle(reduceMotion: reduceMotion))
            .safeHelp(KeyboardShortcutSettings.Action.toggleSidebar.tooltip(
                String(localized: "menu.view.expandSidebar", defaultValue: "Expand Sidebar")
            ))
            .accessibilityLabel(String(localized: "menu.view.expandSidebar", defaultValue: "Expand Sidebar"))
            .accessibilityIdentifier("UniConnectRailExpand")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var managerObservationPublisher: AnyPublisher<Void, Never> {
        let tabs = tabManager.$tabs
            .map { $0.map(\.id) }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
        let selection = tabManager.$selectedTabId
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
        let groups = tabManager.$workspaceGroups
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
        return Publishers.Merge3(tabs, selection, groups)
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    private var workspaceObservationPublisher: AnyPublisher<Void, Never> {
        let publishers = tabManager.tabs.flatMap { workspace -> [AnyPublisher<Void, Never>] in
            [
                workspace.$title.map { _ in () }.eraseToAnyPublisher(),
                workspace.$customTitle.map { _ in () }.eraseToAnyPublisher(),
                workspace.$customColor.map { _ in () }.eraseToAnyPublisher(),
                workspace.$isPinned.map { _ in () }.eraseToAnyPublisher(),
                workspace.$groupId.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panels.map { _ in () }.eraseToAnyPublisher(),
                workspace.$paneLayoutVersion.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panelTitles.map { _ in () }.eraseToAnyPublisher(),
                workspace.$panelCustomTitles.map { _ in () }.eraseToAnyPublisher(),
                workspace.$manualUnreadPanelIds.map { _ in () }.eraseToAnyPublisher(),
                workspace.$uniConnectProfile.map { _ in () }.eraseToAnyPublisher(),
                workspace.$uniConnectTmuxSessionsByPanelId.map { _ in () }.eraseToAnyPublisher(),
                workspace.$uniConnectDisconnectedPanelIds.map { _ in () }.eraseToAnyPublisher(),
                workspace.$uniConnectClaudeBridgeStatusByPanelId.map { _ in () }.eraseToAnyPublisher(),
                workspace.$uniConnectLocalWindowsByPanelId.map { _ in () }.eraseToAnyPublisher(),
                workspace.$remoteConnectionState.map { _ in () }.eraseToAnyPublisher(),
            ]
        }
        guard !publishers.isEmpty else {
            return Empty<Void, Never>().eraseToAnyPublisher()
        }
        return Publishers.MergeMany(publishers)
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }

    /// Reading the selected Bonsplit controller here lets Observation invalidate only
    /// the rail root when pane focus changes; row descendants still receive values.
    private var selectedPanelFocusID: UUID? {
        guard let selectedTabID = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == selectedTabID }) else {
            return nil
        }
        return workspace.focusedPanelId
    }

    private func reloadRows() {
        let nextRows = makeRows()
        let currentSnapshots = renderedRows.map(\.snapshot)
        let nextSnapshots = nextRows.map(\.snapshot)
        guard renderedRows.map(\.id) != nextRows.map(\.id) || currentSnapshots != nextSnapshots else {
            return
        }
        renderedRows = nextRows
    }

    private func makeRows() -> [UniConnectRailRow] {
        let tabs = tabManager.tabs
        let groupsByID = Dictionary(uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0) })
        let renderItems = SidebarWorkspaceRenderItem.renderItems(tabs: tabs, groupsById: groupsByID)
        var rows: [UniConnectRailRow] = []
        rows.reserveCapacity(renderItems.count + tabManager.workspaceGroups.count)
        var previousGroupID: UUID?

        for item in renderItems {
            switch item {
            case .workspace(let workspace):
                if !rows.isEmpty, previousGroupID != workspace.groupId {
                    rows.append(.init(id: "divider.\(workspace.id.uuidString)", content: .divider))
                }
                let snapshot = makeWorkspaceSnapshot(workspace)
                rows.append(.init(
                    id: "workspace.\(workspace.id.uuidString)",
                    content: .chip(snapshot: snapshot, actions: makeActions(workspaceID: workspace.id, groupID: nil))
                ))
                previousGroupID = workspace.groupId

            case .groupHeader(let group, let memberWorkspaceIDs):
                if !rows.isEmpty, previousGroupID != group.id {
                    rows.append(.init(id: "divider.\(group.id.uuidString)", content: .divider))
                }
                guard let anchor = tabs.first(where: { $0.id == group.anchorWorkspaceId }) else { continue }
                let members = memberWorkspaceIDs.compactMap { memberID in
                    tabs.first(where: { $0.id == memberID })
                }
                let snapshot = makeGroupSnapshot(group: group, anchor: anchor, members: members)
                rows.append(.init(
                    id: "group.\(group.id.uuidString)",
                    content: .chip(
                        snapshot: snapshot,
                        actions: makeActions(workspaceID: anchor.id, groupID: group.id)
                    )
                ))
                previousGroupID = group.id
            }
        }
        return rows
    }

    private func makeWorkspaceSnapshot(_ workspace: Workspace) -> UniConnectChipSnapshot {
        let displayName = effectiveDisplayName(for: workspace)
        let bridgeStatus = projectedBridgeStatus(for: [workspace])
        let windows = windowSnapshots(for: workspace)
        let isSSH = workspace.uniConnectProfile?.isSSH == true
        return UniConnectChipSnapshot(
            id: workspace.id,
            workspaceID: workspace.id,
            groupID: nil,
            isGroupCollapsed: false,
            displayName: displayName,
            secondaryLabel: isSSH ? workspace.uniConnectProfile?.hostLabel : nil,
            symbolName: nil,
            monogram: UniConnectChipSnapshot.monogram(for: displayName),
            colorHex: resolvedColorHex(workspace.customColor, id: workspace.id),
            connectionKind: isSSH ? .ssh : .local,
            isDisconnected: !workspace.uniConnectDisconnectedPanelIds.isEmpty,
            isConnecting: isConnecting(workspace, bridgeStatus: bridgeStatus),
            isSelected: tabManager.selectedTabId == workspace.id,
            isPinned: workspace.isPinned,
            unreadCount: notificationStore.unreadCount(forTabId: workspace.id),
            bridgeStatus: bridgeStatus,
            windows: windows,
            shortcutDigit: shortcutDigit(for: workspace.id)
        )
    }

    private func makeGroupSnapshot(
        group: WorkspaceGroup,
        anchor: Workspace,
        members: [Workspace]
    ) -> UniConnectChipSnapshot {
        let effectiveMembers = members.isEmpty ? [anchor] : members
        let kinds = Set(effectiveMembers.map { $0.uniConnectProfile?.isSSH == true })
        let kind: UniConnectChipSnapshot.ConnectionKind = kinds.count > 1
            ? .mixed
            : (kinds.first == true ? .ssh : .local)
        let bridgeStatus = projectedBridgeStatus(for: effectiveMembers)
        let windows = effectiveMembers.flatMap { windowSnapshots(for: $0) }
        let selectedID = tabManager.selectedTabId

        return UniConnectChipSnapshot(
            id: group.id,
            workspaceID: anchor.id,
            groupID: group.id,
            isGroupCollapsed: group.isCollapsed,
            displayName: group.name,
            secondaryLabel: nil,
            symbolName: group.iconSymbol ?? "folder.fill",
            monogram: UniConnectChipSnapshot.monogram(for: group.name),
            colorHex: resolvedColorHex(group.customColor ?? anchor.customColor, id: group.id),
            connectionKind: kind,
            isDisconnected: effectiveMembers.contains { !$0.uniConnectDisconnectedPanelIds.isEmpty },
            isConnecting: effectiveMembers.contains { isConnecting($0, bridgeStatus: bridgeStatus) },
            isSelected: selectedID.map { memberWorkspaceID in
                effectiveMembers.contains { $0.id == memberWorkspaceID }
            } ?? false,
            isPinned: group.isPinned,
            unreadCount: effectiveMembers.reduce(0) {
                $0 + notificationStore.unreadCount(forTabId: $1.id)
            },
            bridgeStatus: bridgeStatus,
            windows: windows,
            shortcutDigit: shortcutDigit(for: anchor.id)
        )
    }

    private func windowSnapshots(for workspace: Workspace) -> [UniConnectWindowSnapshot] {
        let localCustomTargets: [UniConnectLocalWindowLaunchTarget] = {
            guard workspace.uniConnectProfile?.isSSH == false,
                  let boxRoot = workspace.uniConnectLocalBoxRoot else {
                return []
            }
            let registry = CmuxVaultAgentRegistry.load(workingDirectory: boxRoot)
            return UniConnectLocalWindowLaunchTarget.customTargets(from: registry)
        }()
        return workspace.uniConnectOrderedTerminalPanelIds().compactMap { panelID in
            guard let panel = workspace.panels[panelID] else { return nil }
            let title = (
                workspace.panelCustomTitles[panelID]
                    ?? workspace.panelTitles[panelID]
                    ?? panel.displayTitle
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return UniConnectWindowSnapshot(
                id: panelID,
                workspaceID: workspace.id,
                title: title.isEmpty
                    ? String(localized: "uniconnect.rail.window.untitled", defaultValue: "Untitled window")
                    : title,
                isFocused: workspace.id == tabManager.selectedTabId && workspace.focusedPanelId == panelID,
                isDisconnected: workspace.uniConnectDisconnectedPanelIds.contains(panelID),
                isUnread: workspace.manualUnreadPanelIds.contains(panelID)
                    || workspace.restoredUnreadPanelIds.contains(panelID)
                    || notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelID),
                canReconnectSSHNow: workspace.uniConnectProfile?.isSSH == true
                    && workspace.uniConnectTmuxSessionsByPanelId[panelID] != nil,
                requiresLocalRootReassignment: workspace.uniConnectLocalWindowsByPanelId[panelID].map {
                    !UniConnectLocalBoxRootPolicy.isAvailableDirectory($0.boxRoot)
                } ?? false,
                localActionMenu: workspace.uniConnectLocalWindowsByPanelId[panelID].map { record in
                    UniConnectLocalWindowActionPolicy.menuSnapshot(
                        record: record,
                        customTargets: localCustomTargets,
                        boxRootIsAvailable: UniConnectLocalBoxRootPolicy.isAvailableDirectory(record.boxRoot)
                    )
                }
            )
        }
    }

    private func makeActions(workspaceID: UUID, groupID: UUID?) -> UniConnectChipActions {
        let targetWorkspaceIDs = workspaceIDs(workspaceID: workspaceID, groupID: groupID)
        let editableSSHWorkspaceID = targetWorkspaceIDs.first { targetID in
            tabManager.tabs.first(where: { $0.id == targetID })?.uniConnectProfile?.isSSH == true
        }
        let editSSHConnection: (@MainActor () -> Void)? = editableSSHWorkspaceID.map { targetID in
            {
                guard let workspace = tabManager.tabs.first(where: { $0.id == targetID }),
                      workspace.uniConnectProfile?.isSSH == true else { return }
                UniConnectCoordinator.shared.editConnection(for: workspace)
            }
        }
        return UniConnectChipActions(
            selectBox: {
                tabManager.focusTab(workspaceID)
            },
            selectWindow: { targetWorkspaceID, panelID in
                tabManager.focusTab(targetWorkspaceID, surfaceId: panelID)
            },
            performLocalWindowAction: { targetWorkspaceID, panelID, action in
                guard let workspace = tabManager.tabs.first(where: { $0.id == targetWorkspaceID }),
                      workspace.uniConnectProfile?.isSSH == false else {
                    return
                }
                UniConnectCoordinator.shared.performLocalWindowAction(
                    action,
                    panelID: panelID,
                    workspace: workspace
                )
            },
            reconnectSSHWindowNow: { targetWorkspaceID, panelID in
                guard let workspace = tabManager.tabs.first(where: { $0.id == targetWorkspaceID }),
                      workspace.uniConnectProfile?.isSSH == true,
                      workspace.uniConnectTmuxSessionsByPanelId[panelID] != nil else {
                    return
                }
                UniConnectCoordinator.shared.reconnectNow(
                    panelId: panelID,
                    in: workspace,
                    userInitiated: true
                )
            },
            renameBox: {
                tabManager.focusTab(workspaceID)
                _ = AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette(
                    preferredWindow: tabManager.window
                )
            },
            editSSHConnection: editSSHConnection,
            setPinned: { pinned in
                if let groupID {
                    tabManager.setWorkspaceGroupPinned(groupId: groupID, isPinned: pinned)
                } else if let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) {
                    tabManager.setPinned(workspace, pinned: pinned)
                }
            },
            createWindow: {
                tabManager.focusTab(workspaceID)
                tabManager.newSurface()
            },
            reconnectSSHWindowsNow: {
                reconnectSSHWindowsNow(workspaceID: workspaceID, groupID: groupID)
            },
            updateClaude: {
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else { return }
                UniConnectCoordinator.shared.requestClaudeUpdateInBox(workspace)
            },
            markRead: {
                workspaceIDs(workspaceID: workspaceID, groupID: groupID).forEach {
                    notificationStore.markRead(forTabId: $0)
                }
            },
            markUnread: {
                workspaceIDs(workspaceID: workspaceID, groupID: groupID).forEach {
                    notificationStore.markUnread(forTabId: $0)
                }
            },
            closeBox: {
                _ = tabManager.closeWorkspaceWithConfirmation(tabId: workspaceID)
            },
            toggleGroup: groupID.map { resolvedGroupID in
                { tabManager.toggleWorkspaceGroupCollapsed(groupId: resolvedGroupID) }
            }
        )
    }

    private func reconnectSSHWindowsNow(workspaceID: UUID, groupID: UUID?) {
        let workspaces = workspaceIDs(workspaceID: workspaceID, groupID: groupID).compactMap { targetID in
            tabManager.tabs.first(where: { $0.id == targetID })
        }
        UniConnectCoordinator.shared.reconnectSSHWindowsNow(in: workspaces)
    }

    private func workspaceIDs(workspaceID: UUID, groupID: UUID?) -> [UUID] {
        guard let groupID else { return [workspaceID] }
        let grouped = tabManager.tabs.compactMap { $0.groupId == groupID ? $0.id : nil }
        return grouped.isEmpty ? [workspaceID] : grouped
    }

    private func effectiveDisplayName(for workspace: Workspace) -> String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? String(localized: "uniconnect.rail.box.untitled", defaultValue: "Untitled box")
            : title
    }

    private func shortcutDigit(for workspaceID: UUID) -> Int? {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspaceID }), index < 9 else {
            return nil
        }
        return index + 1
    }

    private func resolvedColorHex(_ customColor: String?, id: UUID) -> String {
        guard let customColor = customColor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !customColor.isEmpty else {
            return UniConnectChipSnapshot.fallbackColorHex(for: id)
        }
        return customColor
    }

    private func isConnecting(_ workspace: Workspace, bridgeStatus: ClaudeBridgeStatus?) -> Bool {
        workspace.remoteConnectionState == .connecting
            || workspace.remoteConnectionState == .reconnecting
            || bridgeStatus == .reconnecting
    }

    private func projectedBridgeStatus(for workspaces: [Workspace]) -> ClaudeBridgeStatus? {
        let values = workspaces.flatMap { $0.uniConnectClaudeBridgeStatusByPanelId.values }
        if let error = values.first(where: {
            if case .error = $0 { return true }
            return false
        }) { return error }
        if let unavailable = values.first(where: {
            if case .unavailable = $0 { return true }
            return false
        }) { return unavailable }
        if values.contains(.reconnecting) { return .reconnecting }
        if values.contains(.active) { return .active }
        if values.contains(.inactive) { return .inactive }
        return nil
    }
}
