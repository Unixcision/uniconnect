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

    /// Whether executing this action sends a foreground command to an existing shell.
    var requiresIdleShellPrompt: Bool {
        switch self {
        case .resumeConversation:
            return true
        case .startAgent(let target):
            return target != .terminal
        case .reassignBoxRoot, .reopenTerminal, .forgetConversation:
            return false
        }
    }

    /// Rejects foreground input unless a live terminal is known to be waiting at its prompt.
    func canDispatchForegroundCommand(
        runtimeState: UniConnectLocalWindowRuntimeState,
        shellIsAtPrompt: Bool
    ) -> Bool {
        guard runtimeState != .agent else { return false }
        guard runtimeState != .stopped else { return true }
        return !requiresIdleShellPrompt || shellIsAtPrompt
    }

    /// Resolves the exact durable snapshot that a manual resume command will launch.
    func resolvedResumeSnapshot(
        record: UniConnectLocalWindowRecord,
        registry: CmuxVaultAgentRegistry,
        fallbackWorkingDirectory: String? = nil
    ) -> SessionRestorableAgentSnapshot? {
        guard case .resumeConversation(let conversationID) = self,
              var snapshot = record.restorableSnapshot(
                  for: conversationID,
                  registry: registry
              ) else {
            return nil
        }
        guard snapshot.workingDirectory.map({
            UniConnectLocalBoxRootPolicy.isAvailableDirectory($0)
        }) != true else {
            return snapshot
        }

        // Codex/Agy-like stores address a conversation by id and record cwd in the
        // session itself, so a missing historical directory can safely use the live
        // window cwd. Claude/Grok-like stores are keyed by launch directory and must
        // never be redirected to another project.
        let isRegisteredCustomAgent = snapshot.kind.customAgentID != nil
            && snapshot.registration != nil
        guard isRegisteredCustomAgent
                || snapshot.kind.cwdNamespacing == .cwdInFile,
              let workingDirectory = fallbackWorkingDirectory
                  ?? UniConnectLocalBoxRootPolicy.terminalWorkingDirectory(
                      savedWorkingDirectory: record.workingDirectory,
                      boxRoot: record.boxRoot
                  ),
              let fallbackSnapshot = record.restorableSnapshot(
                  for: conversationID,
                  registry: registry,
                  workingDirectory: workingDirectory
              ) else {
            return nil
        }
        snapshot = fallbackSnapshot
        return snapshot
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
        case .resumeConversation:
            guard let snapshot = resolvedResumeSnapshot(
                record: record,
                registry: registry,
                fallbackWorkingDirectory: terminalWorkingDirectory
            ) else { return nil }
            let resumeWorkingDirectory = snapshot.workingDirectory ?? terminalWorkingDirectory
            guard let resumeCommand = snapshot.resumeCommand,
               let command = UniConnectLocalBoxRootPolicy.commandRequiringWorkingDirectory(
                   resumeCommand,
                   workingDirectory: resumeWorkingDirectory,
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
