import Foundation

/// Safe command fragments used to attach a direct SSH/tmux window to the bridge.
public struct ClaudeBridgeConnectionPlan: Sendable, Equatable {
    /// Stable route UUID for status and cleanup.
    public let routeID: UUID

    /// SSH client options that create a loopback-only reverse forward.
    public let sshOptions: [String]

    /// Non-secret remote setup command executed before attaching tmux.
    public let remoteSetupCommand: String

    /// Non-secret command that removes only this namespaced remote route.
    public let remoteCleanupCommand: String

    /// Creates a direct-SSH bridge connection plan.
    ///
    /// - Parameters:
    ///   - routeID: Stable route UUID.
    ///   - sshOptions: Validated SSH option tokens.
    ///   - remoteSetupCommand: Namespaced remote setup command.
    ///   - remoteCleanupCommand: Namespaced remote cleanup command.
    public init(
        routeID: UUID,
        sshOptions: [String],
        remoteSetupCommand: String,
        remoteCleanupCommand: String
    ) {
        self.routeID = routeID
        self.sshOptions = sshOptions
        self.remoteSetupCommand = remoteSetupCommand
        self.remoteCleanupCommand = remoteCleanupCommand
    }
}
