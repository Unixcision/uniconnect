import SwiftUI

/// Reusable SwiftUI menu content for local-window context menus and rail flyouts.
struct UniConnectLocalWindowActionMenu: View {
    let snapshot: UniConnectLocalWindowActionMenuSnapshot
    let onPerform: (UniConnectLocalWindowAction) -> Void

    var body: some View {
        Group {
            if !snapshot.enabledRecoveryActions.isEmpty {
                ForEach(snapshot.enabledRecoveryActions) { descriptor in
                    actionButton(descriptor)
                }
            }

            if !snapshot.enabledRecoveryActions.isEmpty, hasLaunchActions {
                Divider()
            }

            if !snapshot.enabledHistoryActions.isEmpty {
                Menu {
                    ForEach(snapshot.enabledHistoryActions) { descriptor in
                        actionButton(descriptor)
                    }
                } label: {
                    Label(
                        String(
                            localized: "uniconnect.localWindow.menu.history",
                            defaultValue: "Previous Conversations"
                        ),
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }

            if !snapshot.enabledAgentActions.isEmpty {
                Menu {
                    ForEach(snapshot.enabledAgentActions) { descriptor in
                        actionButton(descriptor)
                    }
                } label: {
                    Label(
                        String(
                            localized: "uniconnect.localWindow.menu.agents",
                            defaultValue: "Start or Switch Agent"
                        ),
                        systemImage: "sparkles.rectangle.stack"
                    )
                }
            }

            if !snapshot.enabledForgetActions.isEmpty {
                if !snapshot.enabledRecoveryActions.isEmpty || hasLaunchActions {
                    Divider()
                }
                Menu {
                    ForEach(snapshot.enabledForgetActions) { descriptor in
                        actionButton(descriptor)
                    }
                } label: {
                    Label(
                        String(
                            localized: "uniconnect.localWindow.menu.forget",
                            defaultValue: "Forget Saved Conversation"
                        ),
                        systemImage: "trash"
                    )
                }
            }
        }
    }

    private func actionButton(
        _ descriptor: UniConnectLocalWindowActionDescriptor
    ) -> some View {
        Button(
            role: descriptor.role == .destructive ? .destructive : nil,
            action: { onPerform(descriptor.action) }
        ) {
            Label(descriptor.title, systemImage: descriptor.systemImageName)
        }
        .help(descriptor.subtitle ?? descriptor.title)
    }

    private var hasLaunchActions: Bool {
        !snapshot.enabledHistoryActions.isEmpty || !snapshot.enabledAgentActions.isEmpty
    }
}
