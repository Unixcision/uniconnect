import SwiftUI

/// Reusable SwiftUI menu content for local-window context menus and rail flyouts.
struct UniConnectLocalWindowActionMenu: View {
    let snapshot: UniConnectLocalWindowActionMenuSnapshot
    let onPerform: (UniConnectLocalWindowAction) -> Void

    var body: some View {
        Group {
            if !snapshot.recoveryActions.isEmpty {
                ForEach(snapshot.recoveryActions) { descriptor in
                    actionButton(descriptor)
                }
                Divider()
            }

            if !snapshot.historyActions.isEmpty {
                Menu {
                    ForEach(snapshot.historyActions) { descriptor in
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

            if !snapshot.agentActions.isEmpty {
                Menu {
                    ForEach(snapshot.agentActions) { descriptor in
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

            if !snapshot.forgetActions.isEmpty {
                Divider()
                Menu {
                    ForEach(snapshot.forgetActions) { descriptor in
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
        .disabled(!descriptor.isEnabled)
        .help(descriptor.subtitle ?? descriptor.title)
    }
}
