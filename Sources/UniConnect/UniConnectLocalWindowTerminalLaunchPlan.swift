import Foundation

/// A shell-safe terminal operation derived from a persistent local-window action.
struct UniConnectLocalWindowTerminalLaunchPlan: Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case openShell
        case runCommand(String)
    }

    let boxRoot: String
    let workingDirectory: String
    let operation: Operation

    var startupInput: String? {
        switch operation {
        case .openShell:
            return nil
        case .runCommand(let command):
            return command + "\n"
        }
    }
}
