import SwiftUI

extension TabItemView {
    @ViewBuilder
    func workspaceGroupContextMenuSection(
        targetIds: [UUID],
        isMulti: Bool
    ) -> some View {
        let targetWorkspaces = targetIds.compactMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let eligibleTargets = targetWorkspaces.filter { !$0.isPinned }
        let eligibleTargetIds = eligibleTargets.map(\.id)
        if !eligibleTargetIds.isEmpty {
            let groups = workspaceGroupMenuSnapshot.items
            let allTargetsInSameGroup: UUID? = {
                let groupIds = eligibleTargets.map(\.groupId)
                guard let first = groupIds.first, groupIds.allSatisfy({ $0 == first }) else {
                    return nil
                }
                return first
            }()
            let hasAnyGroupedTarget = eligibleTargets.contains { $0.groupId != nil }

            let groupSelectedShortcut = KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
            let groupSelectedLabel = isMulti
                ? String(
                    localized: "contextMenu.workspaceGroup.newFromSelection",
                    defaultValue: "New Group from Selection"
                )
                : String(
                    localized: "contextMenu.workspaceGroup.newFromWorkspace",
                    defaultValue: "New Group from Workspace"
                )
            if let key = groupSelectedShortcut.keyEquivalent {
                Button {
                    promptNewWorkspaceGroup(workspaceIds: eligibleTargetIds)
                } label: {
                    Label(groupSelectedLabel, systemImage: "rectangle.3.group")
                }
                .keyboardShortcut(key, modifiers: groupSelectedShortcut.eventModifiers)
            } else {
                Button {
                    promptNewWorkspaceGroup(workspaceIds: eligibleTargetIds)
                } label: {
                    Label(groupSelectedLabel, systemImage: "rectangle.3.group")
                }
            }

            Menu {
                ForEach(groups) { group in
                    Button(group.name) {
                        for id in eligibleTargetIds {
                            tabManager.addWorkspaceToGroup(workspaceId: id, groupId: group.id)
                        }
                    }
                    .disabled(allTargetsInSameGroup == group.id)
                }
            } label: {
                Label(
                    String(localized: "contextMenu.workspaceGroup.moveTo", defaultValue: "Move to Group"),
                    systemImage: "folder"
                )
            }
            .disabled(groups.isEmpty)

            if hasAnyGroupedTarget {
                Button {
                    for id in eligibleTargetIds {
                        tabManager.removeWorkspaceFromGroup(workspaceId: id)
                    }
                } label: {
                    Label(
                        String(localized: "contextMenu.workspaceGroup.remove", defaultValue: "Remove from Group"),
                        systemImage: "folder.badge.minus"
                    )
                }
            }
        }
    }

    func promptNewWorkspaceGroup(workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: workspaceIds)
    }
}
