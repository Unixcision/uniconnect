import Foundation

/// A stable, localizable reason why a Claude bridge route is unavailable.
public enum ClaudeBridgeUnavailableReason: String, Codable, Sendable, Equatable {
    /// UniConnect could not create its loopback-only listener.
    case localListener

    /// The remote machine does not have Python 3, which the privacy-minimized hook requires.
    case remoteRuntime

    /// The remote Claude settings file is invalid or cannot be updated safely.
    case remoteSettings

    /// The SSH reverse-forward did not become available.
    case reverseForward

    /// The remote integration did not authenticate before the bounded setup timeout.
    case enrollmentTimedOut
}
