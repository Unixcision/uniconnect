import Foundation

/// Projects durable local-window state into the shared set of safe user actions.
enum UniConnectLocalWindowActionPolicy {
    static func menuSnapshot(
        record: UniConnectLocalWindowRecord,
        customTargets: [UniConnectLocalWindowLaunchTarget] = [],
        boxRootIsAvailable: Bool = true
    ) -> UniConnectLocalWindowActionMenuSnapshot {
        let canLaunch = record.runtimeState != .agent && boxRootIsAvailable
        let latestID = record.latestConversationID
        var recoveryActions: [UniConnectLocalWindowActionDescriptor] = []

        if !boxRootIsAvailable {
            recoveryActions.append(
                descriptor(
                    action: .reassignBoxRoot,
                    title: String(
                        localized: "uniconnect.localWindow.action.reassignRoot",
                        defaultValue: "Choose New Box Folder…"
                    ),
                    subtitle: String(
                        localized: "uniconnect.localWindow.action.reassignRoot.detail",
                        defaultValue: "The saved folder is unavailable. Nothing will run until you choose its new location."
                    ),
                    systemImageName: "folder.badge.questionmark"
                )
            )
        }

        if record.runtimeState == .stopped, boxRootIsAvailable {
            recoveryActions.append(
                descriptor(
                    action: .reopenTerminal,
                    title: String(
                        localized: "uniconnect.localWindow.action.reopenTerminal",
                        defaultValue: "Reopen Terminal"
                    ),
                    subtitle: String(
                        localized: "uniconnect.localWindow.action.reopenTerminal.detail",
                        defaultValue: "Start a new shell in the saved box folder."
                    ),
                    systemImageName: "terminal.fill"
                )
            )
        }

        if let latest = record.latestConversation,
           record.runtimeState != .agent {
            recoveryActions.append(
                resumeDescriptor(
                    latest,
                    isLatest: true,
                    isEnabled: canLaunch
                )
            )
        }

        let historyActions: [UniConnectLocalWindowActionDescriptor] = record.conversations
            .reversed()
            .compactMap { conversation -> UniConnectLocalWindowActionDescriptor? in
            guard conversation.id != latestID else { return nil }
            return resumeDescriptor(
                conversation,
                isLatest: false,
                isEnabled: canLaunch
            )
            }

        var seenTargets = Set<String>()
        let targets = (UniConnectLocalWindowLaunchTarget.builtInAgents + customTargets).filter {
            seenTargets.insert($0.id).inserted
        }
        let agentActions = targets.map { target in
            descriptor(
                action: .startAgent(target),
                title: String(
                    localized: "uniconnect.localWindow.action.startAgent",
                    defaultValue: "Start \(target.displayName)"
                ),
                subtitle: canLaunch
                    ? target.localizedSummary
                    : String(
                        localized: "uniconnect.localWindow.action.exitCurrentAgentFirst",
                        defaultValue: "Exit the current agent first."
                    ),
                systemImageName: target.systemImageName,
                isEnabled: canLaunch
            )
        }

        let forgetActions = record.conversations.reversed().map { conversation in
            let title = String(
                localized: "uniconnect.localWindow.action.forgetConversation",
                defaultValue: "Forget \(conversation.displayName) Conversation…"
            )
            return descriptor(
                action: .forgetConversation(conversation.id),
                title: title + " · " + sessionIdentifierPreview(conversation),
                subtitle: sessionSubtitle(conversation),
                systemImageName: "trash",
                role: .destructive,
                isEnabled: canLaunch
            )
        }

        let runtimeText = runtimePresentation(record, boxRootIsAvailable: boxRootIsAvailable)
        return UniConnectLocalWindowActionMenuSnapshot(
            windowID: record.id,
            runtimeTitle: runtimeText.title,
            runtimeDetail: runtimeText.detail,
            recoveryActions: recoveryActions,
            historyActions: historyActions,
            agentActions: agentActions,
            forgetActions: forgetActions
        )
    }

    private static func resumeDescriptor(
        _ conversation: UniConnectLocalAgentConversation,
        isLatest: Bool,
        isEnabled: Bool
    ) -> UniConnectLocalWindowActionDescriptor {
        let title = isLatest
            ? String(
                localized: "uniconnect.localWindow.action.resumeLatest",
                defaultValue: "Resume \(conversation.displayName)"
            )
            : String(
                localized: "uniconnect.localWindow.action.resumeConversation",
                defaultValue: "Resume \(conversation.displayName) Conversation"
            )
        return descriptor(
            action: .resumeConversation(conversation.id),
            title: title + " · " + sessionIdentifierPreview(conversation),
            subtitle: sessionSubtitle(conversation),
            systemImageName: isLatest ? "arrow.clockwise.circle.fill" : "clock.arrow.circlepath",
            isEnabled: isEnabled
        )
    }

    private static func sessionSubtitle(
        _ conversation: UniConnectLocalAgentConversation
    ) -> String {
        let abbreviated = sessionIdentifierPreview(conversation)
        return String(
            localized: "uniconnect.localWindow.sessionIdentifier",
            defaultValue: "Session \(abbreviated)"
        )
    }

    private static func sessionIdentifierPreview(
        _ conversation: UniConnectLocalAgentConversation
    ) -> String {
        let maximumLength = 14
        let prefix = String(conversation.sessionID.prefix(maximumLength))
        return conversation.sessionID.count > maximumLength ? prefix + "…" : prefix
    }

    private static func runtimePresentation(
        _ record: UniConnectLocalWindowRecord,
        boxRootIsAvailable: Bool
    ) -> (title: String, detail: String) {
        if !boxRootIsAvailable {
            return (
                String(
                    localized: "uniconnect.localWindow.runtime.missingRoot",
                    defaultValue: "Box Folder Missing"
                ),
                String(
                    localized: "uniconnect.localWindow.runtime.missingRoot.detail",
                    defaultValue: "Choose the folder's new location to resume this window safely."
                )
            )
        }
        switch record.runtimeState {
        case .stopped:
            return (
                String(
                    localized: "uniconnect.localWindow.runtime.stopped",
                    defaultValue: "Window Stopped"
                ),
                record.latestConversation == nil
                    ? String(
                        localized: "uniconnect.localWindow.runtime.stopped.detail",
                        defaultValue: "The shell exited. Reopen it in the saved box folder."
                    )
                    : String(
                        localized: "uniconnect.localWindow.runtime.stoppedWithHistory.detail",
                        defaultValue: "The shell exited. Your saved conversations are still available."
                    )
            )
        case .shell:
            if let latest = record.latestConversation {
                return (
                    String(
                        localized: "uniconnect.localWindow.runtime.savedConversation",
                        defaultValue: "Saved Conversation Available"
                    ),
                    String(
                        localized: "uniconnect.localWindow.runtime.savedConversation.detail",
                        defaultValue: "Resume \(latest.displayName), or start another agent without losing history."
                    )
                )
            }
            return (
                String(
                    localized: "uniconnect.localWindow.runtime.shell",
                    defaultValue: "Terminal Ready"
                ),
                String(
                    localized: "uniconnect.localWindow.runtime.shell.detail",
                    defaultValue: "Start an agent whenever you need one."
                )
            )
        case .agent:
            let agentName = record.activeConversation?.displayName
                ?? record.latestConversation?.displayName
                ?? String(
                    localized: "uniconnect.localWindow.runtime.agent.fallback",
                    defaultValue: "Agent"
                )
            return (
                String(
                    localized: "uniconnect.localWindow.runtime.agent",
                    defaultValue: "\(agentName) Is Running"
                ),
                String(
                    localized: "uniconnect.localWindow.runtime.agent.detail",
                    defaultValue: "Use /exit first to return to the shell and switch agents."
                )
            )
        }
    }

    private static func descriptor(
        action: UniConnectLocalWindowAction,
        title: String,
        subtitle: String?,
        systemImageName: String,
        role: UniConnectLocalWindowActionDescriptor.Role = .standard,
        isEnabled: Bool = true
    ) -> UniConnectLocalWindowActionDescriptor {
        UniConnectLocalWindowActionDescriptor(
            action: action,
            title: title,
            subtitle: subtitle,
            systemImageName: systemImageName,
            role: role,
            isEnabled: isEnabled
        )
    }
}
