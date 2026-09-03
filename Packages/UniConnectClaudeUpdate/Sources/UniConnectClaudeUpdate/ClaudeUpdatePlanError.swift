import Foundation

/// A deterministic validation failure that prevents an unsafe update plan from starting.
public enum ClaudeUpdatePlanError: Error, Sendable, Hashable {
    /// The selected scope resolved to no visible targets.
    case noTargets

    /// A selected-target scope resolved to a different set of target identifiers.
    case selectedTargetMismatch(expected: ClaudeUpdateTargetID)

    /// A box scope resolved a target owned by another box.
    case boxMismatch(expectedBoxID: String, targetID: ClaudeUpdateTargetID)

    /// Two entries used the same visible-target identifier.
    case duplicateTargetID(ClaudeUpdateTargetID)

    /// Two visible targets attempted to own the same Claude conversation UUID.
    case duplicateSessionID(UUID, first: ClaudeUpdateTargetID, second: ClaudeUpdateTargetID)

    /// Two remote targets attempted to own the same exact tmux pane.
    case duplicatePane(
        hostID: String,
        pane: ClaudeTmuxPaneIdentity,
        first: ClaudeUpdateTargetID,
        second: ClaudeUpdateTargetID
    )

    /// One host group referenced multiple native or npm Claude installations.
    case conflictingInstallations(hostID: String, installationIDs: [String])

    /// One installation identity resolved to more than one executable path on a host.
    case conflictingExecutablePaths(hostID: String, executablePaths: [String])
}
