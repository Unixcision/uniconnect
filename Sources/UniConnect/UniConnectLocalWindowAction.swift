import Foundation

/// A shared user intent for local-window controls in menus, flyouts, and recovery UI.
enum UniConnectLocalWindowAction: Equatable, Hashable, Identifiable, Sendable {
    case reassignBoxRoot
    case reopenTerminal
    case resumeConversation(UUID)
    case startAgent(UniConnectLocalWindowLaunchTarget)
    case forgetConversation(UUID)

    var id: String {
        switch self {
        case .reassignBoxRoot:
            return "reassign-box-root"
        case .reopenTerminal:
            return "reopen-terminal"
        case .resumeConversation(let conversationID):
            return "resume:\(conversationID.uuidString)"
        case .startAgent(let target):
            return "start:\(target.id)"
        case .forgetConversation(let conversationID):
            return "forget:\(conversationID.uuidString)"
        }
    }

    /// Resolves terminal work without mutating history; mutation stays in the shared dispatcher.
    func terminalLaunchPlan(
        record: UniConnectLocalWindowRecord,
        registry: CmuxVaultAgentRegistry
    ) -> UniConnectLocalWindowTerminalLaunchPlan? {
        guard record.runtimeState != .agent else { return nil }
        guard let terminalWorkingDirectory = UniConnectLocalBoxRootPolicy.terminalWorkingDirectory(
            savedWorkingDirectory: record.workingDirectory,
            boxRoot: record.boxRoot
        ) else {
            return nil
        }
        switch self {
        case .reassignBoxRoot:
            return nil
        case .reopenTerminal:
            return UniConnectLocalWindowTerminalLaunchPlan(
                boxRoot: record.boxRoot,
                workingDirectory: terminalWorkingDirectory,
                operation: .openShell
            )
        case .resumeConversation(let conversationID):
            guard let snapshot = record.restorableSnapshot(
                for: conversationID,
                registry: registry,
                workingDirectory: terminalWorkingDirectory
            ), let resumeCommand = snapshot.resumeCommand,
               let command = UniConnectLocalBoxRootPolicy.commandRequiringWorkingDirectory(
                   resumeCommand,
                   workingDirectory: terminalWorkingDirectory,
                   boxRoot: record.boxRoot
               ) else {
                return nil
            }
            return UniConnectLocalWindowTerminalLaunchPlan(
                boxRoot: record.boxRoot,
                workingDirectory: terminalWorkingDirectory,
                operation: .runCommand(command)
            )
        case .startAgent(let target):
            if target == .terminal {
                return UniConnectLocalWindowTerminalLaunchPlan(
                    boxRoot: record.boxRoot,
                    workingDirectory: terminalWorkingDirectory,
                    operation: .openShell
                )
            }
            guard let command = target.startupCommand(
                boxRoot: record.boxRoot,
                workingDirectory: terminalWorkingDirectory
            ) else {
                return nil
            }
            return UniConnectLocalWindowTerminalLaunchPlan(
                boxRoot: record.boxRoot,
                workingDirectory: terminalWorkingDirectory,
                operation: .runCommand(command)
            )
        case .forgetConversation:
            return nil
        }
    }
}
