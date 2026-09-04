import Foundation

/// Failures that can occur while binding the app's loopback-only bridge listener.
public enum ClaudeBridgeListenerError: Error, Sendable, Equatable {
    /// The operating system could not create a TCP socket.
    case socketCreation(Int32)

    /// The socket could not be restricted and bound to IPv4 loopback.
    case bind(Int32)

    /// The bound socket could not begin listening.
    case listen(Int32)

    /// The operating system did not report the ephemeral bound port.
    case address(Int32)
}
