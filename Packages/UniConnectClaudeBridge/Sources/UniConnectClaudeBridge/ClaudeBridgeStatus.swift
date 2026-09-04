import Foundation

/// The live state of a direct-SSH Claude notification route.
public enum ClaudeBridgeStatus: Sendable, Equatable {
    /// No route is currently registered.
    case inactive

    /// The SSH connection is being established or re-established.
    case reconnecting

    /// The remote integration completed an authenticated handshake.
    case active

    /// The bridge cannot operate in the current environment.
    case unavailable(ClaudeBridgeUnavailableReason)

    /// The bridge encountered a non-secret operational failure.
    case error(ClaudeBridgeFailureCode)
}
