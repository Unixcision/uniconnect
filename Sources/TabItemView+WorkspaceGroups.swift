import SwiftUI

extension TabItemView {
    @ViewBuilder
    var workspaceGroupContextMenuSection: some View {
        let menu = snapshot.contextMenu
        if menu.eligibleForGrouping {
            let groups = menu.groupMenu.items
            let groupSelectedShortcut = KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
            let groupSelectedLabel = menu.isMultiSelection
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
                    actions.perform(.createWorkspaceGroup)
                } label: {
                    Label(groupSelectedLabel, systemImage: "rectangle.3.group")
                }
                .keyboardShortcut(key, modifiers: groupSelectedShortcut.eventModifiers)
            } else {
                Button {
                    actions.perform(.createWorkspaceGroup)
                } label: {
                    Label(groupSelectedLabel, systemImage: "rectangle.3.group")
                }
            }

            Menu {
                ForEach(groups) { group in
                    Button(group.name) {
                        actions.perform(.addToWorkspaceGroup(group.id))
                    }
                    .disabled(menu.allEligibleTargetsGroupId == group.id)
                }
            } label: {
                Label(
                    String(localized: "contextMenu.workspaceGroup.moveTo", defaultValue: "Move to Group"),
                    systemImage: "folder"
                )
            }
            .disabled(groups.isEmpty)

            if menu.hasAnyGroupedEligibleTarget {
                Button {
                    actions.perform(.removeFromWorkspaceGroup)
                } label: {
                    Label(
                        String(localized: "contextMenu.workspaceGroup.remove", defaultValue: "Remove from Group"),
                        systemImage: "folder.badge.minus"
                    )
                }
            }
        }
    }
}
